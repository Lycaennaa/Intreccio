import Foundation
import XCTest
@testable import Intreccio

extension GitServiceIntegrationTests {
    func testStashAndRestorePreserveIndexWorktreeAndUntrackedFiles() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.write("staged\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.write("worktree\n", to: "tracked.txt")
        try fixture.write("untracked\n", to: "untracked.txt")
        let service = GitService()

        try await service.stashChanges(repository: fixture.url)

        var status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.isClean)
        XCTAssertTrue(status.hasStash)
        XCTAssertEqual(
            try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "base\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("untracked.txt").path))

        try await service.restoreLatestStash(repository: fixture.url)

        status = try await service.status(repository: fixture.url)
        XCTAssertFalse(status.hasStash)
        let tracked = try XCTUnwrap(status.changes.first { $0.path == "tracked.txt" })
        XCTAssertEqual(tracked.indexState, .modified)
        XCTAssertEqual(tracked.worktreeState, .modified)
        XCTAssertTrue(status.changes.contains { $0.kind == .untracked && $0.path == "untracked.txt" })
        XCTAssertEqual(
            String(decoding: try fixture.git("show", ":tracked.txt").standardOutput, as: UTF8.self),
            "staged\n"
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "worktree\n"
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.url.appendingPathComponent("untracked.txt"), encoding: .utf8),
            "untracked\n"
        )
        do {
            try await service.restoreLatestStash(repository: fixture.url)
            XCTFail("Expected a missing stash to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .noStash)
        }
    }

    func testRestoreStashRejectsDirtyWorktreeWithoutDroppingStash() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.write("stashed\n", to: "tracked.txt")
        let service = GitService()
        try await service.stashChanges(repository: fixture.url)
        try fixture.write("current\n", to: "current.txt")

        do {
            try await service.restoreLatestStash(repository: fixture.url)
            XCTFail("Expected a dirty working tree to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .dirtyWorktreeForStashRestore(["current.txt"]))
        }

        let status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.hasStash)
        XCTAssertEqual(status.changes.map(\.path), ["current.txt"])
        XCTAssertEqual(
            try String(contentsOf: fixture.url.appendingPathComponent("current.txt"), encoding: .utf8),
            "current\n"
        )
    }

    func testStashRejectsNestedRepositoriesWithoutPartialSuccess() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        let nested = fixture.url.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try runGit(at: nested, arguments: ["init", "-b", "main"])
        try "nested\n".write(
            to: nested.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        let service = GitService()

        do {
            try await service.stashChanges(repository: fixture.url)
            XCTFail("Expected a nested repository to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .unsupportedStashPath("nested/"))
        }

        let status = try await service.status(repository: fixture.url)
        XCTAssertFalse(status.hasStash)
        XCTAssertEqual(status.changes.map(\.path), ["nested/"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("file.txt").path))
    }

    func testRestoreStashRejectsUnbornHeadWithoutPartialRestore() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "--", "file.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.write("stashed\n", to: "file.txt")
        let service = GitService()
        try await service.stashChanges(repository: fixture.url)
        try fixture.git("update-ref", "-d", "refs/heads/main")
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("file.txt"))
        try fixture.git("rm", "--cached", "--", "file.txt")

        let before = try await service.status(repository: fixture.url)
        XCTAssertNil(before.branch.objectID)
        XCTAssertTrue(before.hasStash)
        XCTAssertTrue(before.isClean)
        do {
            try await service.restoreLatestStash(repository: fixture.url)
            XCTFail("Expected an unborn repository to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .stashRequiresCommit)
        }

        let after = try await service.status(repository: fixture.url)
        XCTAssertNil(after.branch.objectID)
        XCTAssertTrue(after.hasStash)
        XCTAssertTrue(after.isClean)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("file.txt").path))
    }

    func testRebaseOnUpstreamRequiresCleanTreeAndReplaysLocalCommits() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "base.txt")
        try fixture.git("add", "--", "base.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("checkout", "-b", "upstream-work")
        try fixture.write("upstream\n", to: "upstream.txt")
        try fixture.git("add", "--", "upstream.txt")
        try fixture.git("commit", "-m", "upstream")
        let upstreamHead = String(decoding: try fixture.git("rev-parse", "HEAD").standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git("checkout", "main")
        try fixture.write("local\n", to: "local.txt")
        try fixture.git("add", "--", "local.txt")
        try fixture.git("commit", "-m", "local")
        let originalLocalHead = try fixture.git("rev-parse", "HEAD").standardOutput
        try fixture.git("remote", "add", "origin", ".")
        try fixture.git("update-ref", "refs/remotes/origin/main", upstreamHead)
        try fixture.git("branch", "--set-upstream-to=origin/main", "main")
        let service = GitService()

        var status = try await service.status(repository: fixture.url)
        XCTAssertEqual(status.branch.ahead, 1)
        XCTAssertEqual(status.branch.behind, 1)
        try fixture.write("dirty\n", to: "dirty.txt")
        do {
            try await service.rebaseOnUpstream(repository: fixture.url)
            XCTFail("Expected a dirty working tree to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .dirtyWorktreeForRebase(["dirty.txt"]))
        }
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD").standardOutput, originalLocalHead)
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("dirty.txt"))

        try await service.rebaseOnUpstream(repository: fixture.url)

        status = try await service.status(repository: fixture.url)
        XCTAssertFalse(status.isRebaseInProgress)
        XCTAssertTrue(status.isClean)
        XCTAssertEqual(status.branch.ahead, 1)
        XCTAssertEqual(status.branch.behind, 0)
        XCTAssertNotEqual(try fixture.git("rev-parse", "HEAD").standardOutput, originalLocalHead)
        let subjects = try await service.history(repository: fixture.url).prefix(3).map(\.subject)
        XCTAssertEqual(subjects, ["local", "upstream", "base"])
        do {
            try await service.rebaseOnUpstream(repository: fixture.url)
            XCTFail("Expected a current branch to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .upstreamHasNoNewCommits)
        }
    }

    func testConflictedRebaseCanContinueAfterExternalResolution() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "conflict.txt")
        try fixture.git("add", "--", "conflict.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("checkout", "-b", "upstream-work")
        try fixture.write("upstream\n", to: "conflict.txt")
        try fixture.git("commit", "-am", "upstream")
        let upstreamHead = String(decoding: try fixture.git("rev-parse", "HEAD").standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git("checkout", "main")
        try fixture.write("local\n", to: "conflict.txt")
        try fixture.git("commit", "-am", "local")
        try fixture.git("remote", "add", "origin", ".")
        try fixture.git("update-ref", "refs/remotes/origin/main", upstreamHead)
        try fixture.git("branch", "--set-upstream-to=origin/main", "main")
        let service = GitService()

        await XCTAssertThrowsErrorAsync(
            {
                try await service.rebaseOnUpstream(repository: fixture.url)
            },
            assertError: { (error: GitRunnerError) in
                guard case .nonZeroExit = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            }
        )
        var status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.isRebaseInProgress)
        XCTAssertTrue(status.hasConflicts)
        do {
            try await service.continueRebase(repository: fixture.url)
            XCTFail("Expected unresolved conflicts to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .unresolvedRebaseConflicts(["conflict.txt"]))
        }

        try fixture.write("resolved\n", to: "conflict.txt")
        try fixture.git("add", "--", "conflict.txt")
        status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.isRebaseInProgress)
        XCTAssertFalse(status.hasConflicts)

        try await service.continueRebase(repository: fixture.url)

        status = try await service.status(repository: fixture.url)
        XCTAssertFalse(status.isRebaseInProgress)
        XCTAssertTrue(status.isClean)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("conflict.txt"), encoding: .utf8), "resolved\n")
    }

    func testAbortRebaseRestoresOriginalBranchAndWorktree() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "conflict.txt")
        try fixture.git("add", "--", "conflict.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("checkout", "-b", "upstream-work")
        try fixture.write("upstream\n", to: "conflict.txt")
        try fixture.git("commit", "-am", "upstream")
        let upstreamHead = String(decoding: try fixture.git("rev-parse", "HEAD").standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git("checkout", "main")
        try fixture.write("local\n", to: "conflict.txt")
        try fixture.git("commit", "-am", "local")
        let originalLocalHead = try fixture.git("rev-parse", "HEAD").standardOutput
        try fixture.git("remote", "add", "origin", ".")
        try fixture.git("update-ref", "refs/remotes/origin/main", upstreamHead)
        try fixture.git("branch", "--set-upstream-to=origin/main", "main")
        let service = GitService()

        await XCTAssertThrowsErrorAsync(
            {
                try await service.rebaseOnUpstream(repository: fixture.url)
            },
            assertError: { (error: GitRunnerError) in
                guard case .nonZeroExit = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            }
        )
        let conflictedStatus = try await service.status(repository: fixture.url)
        XCTAssertTrue(conflictedStatus.isRebaseInProgress)

        try await service.abortRebase(repository: fixture.url)

        let status = try await service.status(repository: fixture.url)
        XCTAssertFalse(status.isRebaseInProgress)
        XCTAssertTrue(status.isClean)
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD").standardOutput, originalLocalHead)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("conflict.txt"), encoding: .utf8), "local\n")
    }

}
