import Foundation
import XCTest
@testable import Intreccio

@MainActor
extension GitServiceIntegrationTests {
    func testUnstageSelectedAndUnbornPreserveWorktreeAndUnrelatedIndex() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("a0\n", to: "a.txt")
        try fixture.write("b0\n", to: "b.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.write("a1\n", to: "a.txt")
        try fixture.write("b1\n", to: "b.txt")
        try fixture.git("add", "-A")
        try fixture.write("a2\n", to: "a.txt")
        let service = GitService()

        try await service.unstage(repository: fixture.url, paths: ["a.txt"])

        var status = try await service.status(repository: fixture.url)
        let a = try XCTUnwrap(status.changes.first { $0.path == "a.txt" })
        XCTAssertFalse(a.hasStagedChange)
        XCTAssertTrue(a.hasUnstagedChange)
        XCTAssertTrue(status.changes.first { $0.path == "b.txt" }?.hasStagedChange == true)
        XCTAssertEqual(try fixture.read("a.txt"), "a2\n")

        let unborn = try GitFixture(testCase: self)
        try unborn.write("one\n", to: "one.txt")
        try unborn.write("two\n", to: "two.txt")
        try unborn.git("add", "-A")
        try await service.unstage(repository: unborn.url, paths: ["one.txt"])
        status = try await service.status(repository: unborn.url)
        XCTAssertTrue(status.changes.first { $0.path == "one.txt" }?.kind == .untracked)
        XCTAssertTrue(status.changes.first { $0.path == "two.txt" }?.hasStagedChange == true)
        XCTAssertEqual(try unborn.read("one.txt"), "one\n")
    }

    func testDiscardRestoresTrackedAndDeletesOnlySelectedUntrackedFile() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("a0\n", to: "a.txt")
        try fixture.write("b0\n", to: "b.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.write("a1\n", to: "a.txt")
        try fixture.git("add", "--", "a.txt")
        try fixture.write("a2\n", to: "a.txt")
        try fixture.write("b1\n", to: "b.txt")
        try fixture.git("add", "--", "b.txt")
        try fixture.write("discard\n", to: ":(glob)*")
        try fixture.write("keep\n", to: "keep.txt")
        let service = GitService()

        var status = try await service.status(repository: fixture.url)
        try await service.discard(
            repository: fixture.url,
            changes: status.changes.filter { $0.path == "a.txt" }
        )

        status = try await service.status(repository: fixture.url)
        XCTAssertEqual(try fixture.read("a.txt"), "a0\n")
        XCTAssertFalse(status.changes.contains { $0.path == "a.txt" })
        XCTAssertTrue(status.changes.first { $0.path == "b.txt" }?.hasStagedChange == true)

        try await service.discard(
            repository: fixture.url,
            changes: status.changes.filter { $0.path == ":(glob)*" }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent(":(glob)*").path))
        XCTAssertEqual(try fixture.read("keep.txt"), "keep\n")
    }

    func testDiscardAppliesFullTrackedAndUntrackedMultiSelections() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("a0\n", to: "a.txt")
        try fixture.write("b0\n", to: "b.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.write("a1\n", to: "a.txt")
        try fixture.git("add", "--", "a.txt")
        try fixture.write("a2\n", to: "a.txt")
        try fixture.write("b1\n", to: "b.txt")
        try fixture.write("discard one\n", to: "discard-one.txt")
        try fixture.write("discard two\n", to: "discard-two.txt")
        try fixture.write("keep\n", to: "keep.txt")
        let service = GitService()

        var status = try await service.status(repository: fixture.url)
        let trackedPaths: Set<String> = ["a.txt", "b.txt"]
        try await service.discard(
            repository: fixture.url,
            changes: status.changes.filter { trackedPaths.contains($0.path) }
        )

        XCTAssertEqual(try fixture.read("a.txt"), "a0\n")
        XCTAssertEqual(try fixture.read("b.txt"), "b0\n")
        status = try await service.status(repository: fixture.url)
        let untrackedPaths: Set<String> = ["discard-one.txt", "discard-two.txt"]
        try await service.discard(
            repository: fixture.url,
            changes: status.changes.filter { untrackedPaths.contains($0.path) }
        )

        let updated = try await service.status(repository: fixture.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("discard-one.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("discard-two.txt").path))
        XCTAssertEqual(try fixture.read("keep.txt"), "keep\n")
        XCTAssertEqual(Set(updated.changes.map(\.path)), ["keep.txt"])
    }

    func testDiscardRejectsMixedSelectionWithoutChangingDisk() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.write("changed\n", to: "tracked.txt")
        try fixture.write("untracked\n", to: "untracked.txt")
        let service = GitService()
        let status = try await service.status(repository: fixture.url)

        do {
            try await service.discard(repository: fixture.url, changes: status.changes)
            XCTFail("Expected mixed discard rejection")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .unsupportedMixedDiscard(["tracked.txt", "untracked.txt"]))
        }

        XCTAssertEqual(try fixture.read("tracked.txt"), "changed\n")
        XCTAssertEqual(try fixture.read("untracked.txt"), "untracked\n")
        let updated = try await service.status(repository: fixture.url)
        XCTAssertTrue(updated.changes.first { $0.path == "tracked.txt" }?.hasUnstagedChange == true)
        XCTAssertTrue(updated.changes.first { $0.path == "untracked.txt" }?.kind == .untracked)
    }

    func testDiscardHandlesAddedFilesWithExistingAndUnbornHead() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "base.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.write("added\n", to: "added.txt")
        try fixture.git("add", "--", "added.txt")
        let service = GitService()
        var status = try await service.status(repository: fixture.url)

        try await service.discard(
            repository: fixture.url,
            changes: status.changes.filter { $0.path == "added.txt" }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("added.txt").path))
        status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.isClean)

        let unborn = try GitFixture(testCase: self)
        try unborn.write("one\n", to: "one.txt")
        try unborn.write("two\n", to: "two.txt")
        try unborn.git("add", "-A")
        status = try await service.status(repository: unborn.url)
        try await service.discard(
            repository: unborn.url,
            changes: status.changes.filter { $0.path == "one.txt" }
        )

        status = try await service.status(repository: unborn.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unborn.url.appendingPathComponent("one.txt").path))
        XCTAssertTrue(status.changes.first { $0.path == "two.txt" }?.hasStagedChange == true)
        XCTAssertEqual(try unborn.read("two.txt"), "two\n")
    }

    func testDiscardRejectsStaleSelectionAndCancellationWithoutChangingDisk() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.write("changed\n", to: "file.txt")
        let service = GitService()
        let staleChanges = try await service.status(repository: fixture.url).changes.filter { $0.path == "file.txt" }
        try fixture.git("add", "--", "file.txt")

        do {
            try await service.discard(repository: fixture.url, changes: staleChanges)
            XCTFail("Expected stale selection rejection")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .staleMutationSelection(["file.txt"]))
        }
        XCTAssertEqual(try fixture.read("file.txt"), "changed\n")
        var status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.changes.first?.hasStagedChange == true)

        try fixture.write("untracked\n", to: "untracked.txt")
        status = try await service.status(repository: fixture.url)
        let changes = status.changes.filter { $0.path == "untracked.txt" }
        let limiter = GitProcessLimiter(maximumConcurrent: 1)
        try await limiter.acquire(priority: .normal)
        let blockedService = GitService(runner: GitRunner(limiter: limiter))
        let repositoryURL = fixture.url
        let task = Task { try await blockedService.discard(repository: repositoryURL, changes: changes) }
        await Task.yield()
        task.cancel()
        await XCTAssertThrowsErrorAsync(
            { try await task.value },
            assertError: { (_: CancellationError) in }
        )
        await limiter.release()
        XCTAssertEqual(try fixture.read("untracked.txt"), "untracked\n")
    }

    func testDiscardRenameRejectsSeparateSourceChange() async throws {
        let renameFixture = try GitFixture(testCase: self)
        try renameFixture.write("base\n", to: "old.txt")
        try renameFixture.git("add", "-A")
        try renameFixture.git("commit", "-m", "base")
        try renameFixture.git("mv", "old.txt", "new.txt")
        try renameFixture.write("replacement\n", to: "old.txt")
        let service = GitService()
        let status = try await service.status(repository: renameFixture.url)
        let rename = status.changes.filter { $0.path == "new.txt" }
        XCTAssertEqual(rename.first?.kind, .renamed)

        do {
            try await service.discard(repository: renameFixture.url, changes: rename)
            XCTFail("Expected source overwrite rejection")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .discardWouldOverwritePaths(["old.txt"]))
        }
        XCTAssertEqual(try renameFixture.read("old.txt"), "replacement\n")
        XCTAssertEqual(try renameFixture.read("new.txt"), "base\n")

        let ignoredFixture = try GitFixture(testCase: self)
        try ignoredFixture.write("old.txt\n", to: ".gitignore")
        try ignoredFixture.write("base\n", to: "old.txt")
        try ignoredFixture.git("add", "-f", "--", ".gitignore", "old.txt")
        try ignoredFixture.git("commit", "-m", "base")
        try ignoredFixture.git("mv", "old.txt", "new.txt")
        try ignoredFixture.write("ignored replacement\n", to: "old.txt")
        let ignoredStatus = try await service.status(repository: ignoredFixture.url)
        let ignoredRename = ignoredStatus.changes.filter { $0.path == "new.txt" }
        XCTAssertEqual(ignoredRename.first?.kind, .renamed)
        XCTAssertFalse(ignoredStatus.changes.contains { $0.path == "old.txt" })

        do {
            try await service.discard(repository: ignoredFixture.url, changes: ignoredRename)
            XCTFail("Expected ignored source overwrite rejection")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .discardWouldOverwritePaths(["old.txt"]))
        }
        XCTAssertEqual(try ignoredFixture.read("old.txt"), "ignored replacement\n")
        XCTAssertEqual(try ignoredFixture.read("new.txt"), "base\n")
    }

    func testDiscardResolvesSelectedConflictAndRejectsNestedRepository() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.git("checkout", "-b", "side")
        try fixture.write("side\n", to: "file.txt")
        try fixture.git("commit", "-am", "side")
        try fixture.git("checkout", "main")
        try fixture.write("main\n", to: "file.txt")
        try fixture.git("commit", "-am", "main")
        XCTAssertThrowsError(try fixture.git("merge", "side"))
        let service = GitService()
        var status = try await service.status(repository: fixture.url)
        let conflict = status.changes.filter { $0.path == "file.txt" }
        XCTAssertEqual(conflict.first?.kind, .unmerged)

        try await service.discard(repository: fixture.url, changes: conflict)

        status = try await service.status(repository: fixture.url)
        XCTAssertFalse(status.changes.contains { $0.path == "file.txt" })
        XCTAssertEqual(try fixture.read("file.txt"), "main\n")

        let nestedURL = fixture.url.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: false)
        try fixture.git("-C", "nested", "init", "-q")
        try "nested\n".write(to: nestedURL.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        status = try await service.status(repository: fixture.url)
        let nested = status.changes.filter { $0.path == "nested/" }
        XCTAssertEqual(nested.first?.kind, .untracked)

        do {
            try await service.discard(repository: fixture.url, changes: nested)
            XCTFail("Expected nested repository rejection")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .unsupportedDiscardPath("nested/"))
        }
        XCTAssertEqual(try String(contentsOf: nestedURL.appendingPathComponent("file.txt"), encoding: .utf8), "nested\n")
    }

    func testDiscardRejectsDirtySubmoduleWithoutChangingNestedWorktree() async throws {
        let child = try GitFixture(testCase: self)
        try child.write("base\n", to: "file.txt")
        try child.git("add", "-A")
        try child.git("commit", "-m", "base")
        let fixture = try GitFixture(testCase: self)
        try fixture.git(
            "-c", "protocol.file.allow=always",
            "submodule", "add", "--", child.url.path, "submodule"
        )
        try fixture.git("commit", "-am", "add submodule")
        let nestedFile = fixture.url.appendingPathComponent("submodule/file.txt")
        try "changed\n".write(to: nestedFile, atomically: true, encoding: .utf8)
        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let submodule = status.changes.filter { $0.path == "submodule" }
        XCTAssertTrue(submodule.first?.submoduleState?.hasPrefix("S") == true)

        do {
            try await service.discard(repository: fixture.url, changes: submodule)
            XCTFail("Expected submodule rejection")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .unsupportedDiscardSubmodule("submodule"))
        }
        XCTAssertEqual(try String(contentsOf: nestedFile, encoding: .utf8), "changed\n")
    }

}
