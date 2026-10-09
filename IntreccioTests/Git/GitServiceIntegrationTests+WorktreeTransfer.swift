import Foundation
@testable import Intreccio
import XCTest

extension GitServiceIntegrationTests {
    func testBringWorktreeChangesToMainPreservesSourceAndTransfersAllChangesStaged() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.write("remove me\n", to: "deleted.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let worktreeURL = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("\(fixture.url.lastPathComponent)-feature", isDirectory: true)
        defer { _ = try? fixture.git("worktree", "remove", "--force", worktreeURL.path) }
        try fixture.git("worktree", "add", "-b", "feature", worktreeURL.path)

        try "staged\n".write(to: worktreeURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(at: worktreeURL, arguments: ["add", "--", "tracked.txt"])
        try "working tree\n".write(
            to: worktreeURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.removeItem(at: worktreeURL.appendingPathComponent("deleted.txt"))
        let binaryData = Data([0x00, 0x01, 0xFE, 0xFF])
        try binaryData.write(to: worktreeURL.appendingPathComponent("new.bin"))
        let nestedDirectory = worktreeURL.appendingPathComponent("new-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        try "nested untracked\n".write(
            to: nestedDirectory.appendingPathComponent("nested.txt"),
            atomically: true,
            encoding: .utf8
        )

        let service = GitService()
        let originalSourceStatus = try await service.status(repository: worktreeURL)
        try await service.bringWorktreeChangesToMain(from: worktreeURL, to: fixture.url)

        XCTAssertEqual(try fixture.read("tracked.txt"), "working tree\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("deleted.txt").path))
        XCTAssertEqual(try Data(contentsOf: fixture.url.appendingPathComponent("new.bin")), binaryData)
        XCTAssertEqual(
            try String(
                contentsOf: fixture.url.appendingPathComponent("new-dir/nested.txt"),
                encoding: .utf8
            ),
            "nested untracked\n"
        )
        let targetStatus = try await service.status(repository: fixture.url)
        XCTAssertTrue(targetStatus.changes.allSatisfy(\.hasStagedChange))
        let finalSourceStatus = try await service.status(repository: worktreeURL)
        XCTAssertEqual(finalSourceStatus, originalSourceStatus)
    }

    func testBringWorktreeChangesToMainRejectsDirtyMainWithoutChangingEitherTree() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let worktreeURL = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("\(fixture.url.lastPathComponent)-feature", isDirectory: true)
        defer { _ = try? fixture.git("worktree", "remove", "--force", worktreeURL.path) }
        try fixture.git("worktree", "add", "-b", "feature", worktreeURL.path)
        try "feature change\n".write(
            to: worktreeURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.write("main change\n", to: "main-only.txt")
        let service = GitService()
        let originalSourceStatus = try await service.status(repository: worktreeURL)

        do {
            try await service.bringWorktreeChangesToMain(from: worktreeURL, to: fixture.url)
            XCTFail("Expected dirty main worktree to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .dirtyMainWorktreeForTransfer(["main-only.txt"]))
        }

        let finalSourceStatus = try await service.status(repository: worktreeURL)
        XCTAssertEqual(finalSourceStatus, originalSourceStatus)
        XCTAssertEqual(try fixture.read("tracked.txt"), "base\n")
        XCTAssertEqual(try fixture.read("main-only.txt"), "main change\n")
    }

    func testBringWorktreeChangesToMainPreflightsConflictsBeforeWriting() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "shared.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let worktreeURL = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("\(fixture.url.lastPathComponent)-feature", isDirectory: true)
        defer { _ = try? fixture.git("worktree", "remove", "--force", worktreeURL.path) }
        try fixture.git("worktree", "add", "-b", "feature", worktreeURL.path)
        try fixture.write("main version\n", to: "shared.txt")
        try fixture.git("add", "--", "shared.txt")
        try fixture.git("commit", "-m", "main change")
        try "feature version\n".write(
            to: worktreeURL.appendingPathComponent("shared.txt"),
            atomically: true,
            encoding: .utf8
        )
        let service = GitService()

        do {
            try await service.bringWorktreeChangesToMain(from: worktreeURL, to: fixture.url)
            XCTFail("Expected an incompatible patch to be rejected")
        } catch GitServiceError.worktreeTransferApplyFailed(let paths, _) {
            XCTAssertEqual(paths, ["shared.txt"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try fixture.read("shared.txt"), "main version\n")
        XCTAssertEqual(
            try String(
                contentsOf: worktreeURL.appendingPathComponent("shared.txt"),
                encoding: .utf8
            ),
            "feature version\n"
        )
        let mainStatus = try await service.status(repository: fixture.url)
        let sourceStatus = try await service.status(repository: worktreeURL)
        XCTAssertTrue(mainStatus.isClean)
        XCTAssertFalse(sourceStatus.isClean)
    }
    func testTransferRejectsUnaddressableSourcePathAtServiceBoundary() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let worktreeURL = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("\(fixture.url.lastPathComponent)-feature", isDirectory: true)
        defer { _ = try? fixture.git("worktree", "remove", "--force", worktreeURL.path) }
        try fixture.git("worktree", "add", "-b", "feature", worktreeURL.path)
        let unsupportedPath = "bad\nname.txt"
        try Data("unaddressable".utf8).write(to: worktreeURL.appendingPathComponent(unsupportedPath))
        let service = GitService()
        let sourceStatus = try await service.status(repository: worktreeURL)
        XCTAssertFalse(try XCTUnwrap(sourceStatus.changes.first).isAddressable)

        do {
            try await service.bringWorktreeChangesToMain(from: worktreeURL, to: fixture.url)
            XCTFail("Expected an unsupported source path to be rejected")
        } catch GitServiceError.unsupportedWorktreeTransferPath(let path) {
            XCTAssertEqual(path, unsupportedPath)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let finalMainStatus = try await service.status(repository: fixture.url)
        let finalSourceStatus = try await service.status(repository: worktreeURL)
        XCTAssertTrue(finalMainStatus.isClean)
        XCTAssertEqual(finalSourceStatus, sourceStatus)
    }
    func testTransferApplyFailureLeavesMainChangesAndConcurrentEditIntact() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.write("restore me\n", to: "deleted.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let worktreeURL = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("\(fixture.url.lastPathComponent)-feature", isDirectory: true)
        defer { _ = try? fixture.git("worktree", "remove", "--force", worktreeURL.path) }
        try fixture.git("worktree", "add", "-b", "feature", worktreeURL.path)
        try "feature change\n".write(
            to: worktreeURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.removeItem(at: worktreeURL.appendingPathComponent("deleted.txt"))
        try "new file\n".write(
            to: worktreeURL.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )
        let runner = FailAfterApplyGitRunner(base: GitRunner(), concurrentEditPath: "tracked.txt")
        let service = GitService(runner: runner)
        let sourceStatus = try await service.status(repository: worktreeURL)

        do {
            try await service.bringWorktreeChangesToMain(from: worktreeURL, to: fixture.url)
            XCTFail("Expected injected failure after main was updated")
        } catch GitServiceError.worktreeTransferApplyFailed(let paths, let reason) {
            XCTAssertEqual(Set(paths), Set(["deleted.txt", "new.txt", "tracked.txt"]))
            XCTAssertTrue(reason.contains("Injected apply failure after writes"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let mainStatus = try await service.status(repository: fixture.url)
        let finalSourceStatus = try await service.status(repository: worktreeURL)
        XCTAssertEqual(Set(mainStatus.changes.map(\.path)), Set(["deleted.txt", "new.txt", "tracked.txt"]))
        XCTAssertEqual(finalSourceStatus, sourceStatus)
        XCTAssertEqual(try fixture.read("tracked.txt"), "Concurrent edit\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("deleted.txt").path))
        XCTAssertEqual(try fixture.read("new.txt"), "new file\n")
    }
}
