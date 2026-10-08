import Foundation
@testable import Intreccio
import XCTest

extension GitServiceIntegrationTests {
    func testHistoryPagesEmptyAndDetachedRepositories() async throws {
        let fixture = try GitFixture(testCase: self)
        let service = GitService()
        let emptyHead = try await service.headObjectID(repository: fixture.url)
        let emptyTips = try await service.historyTips(repository: fixture.url)
        let emptyHistory = try await service.history(repository: fixture.url)
        XCTAssertNil(emptyHead)
        XCTAssertNil(emptyTips.localObjectID)
        XCTAssertNil(emptyTips.upstreamObjectID)
        XCTAssertTrue(emptyHistory.isEmpty)

        for number in 1...16 {
            try fixture.write("\(number)\n", to: "history.txt")
            try fixture.git("add", "--", "history.txt")
            try fixture.git("commit", "-m", "commit \(number)")
        }
        let resolvedHead = try await service.headObjectID(repository: fixture.url)
        let head = try XCTUnwrap(resolvedHead)
        let tips = try await service.historyTips(repository: fixture.url)
        XCTAssertEqual(tips.localObjectID, head)
        XCTAssertNil(tips.upstreamObjectID)
        let first = try await service.history(repository: fixture.url, scope: .mixed, tips: tips)
        let second = try await service.history(
            repository: fixture.url,
            scope: .mixed,
            tips: tips,
            skip: 15
        )
        XCTAssertEqual(first.count, 15)
        XCTAssertEqual(first.first?.subject, "commit 16")
        XCTAssertEqual(first.last?.subject, "commit 2")
        XCTAssertEqual(second.map(\.subject), ["commit 1"])

        try fixture.git("checkout", "--detach", "HEAD~5")
        let resolvedDetachedHead = try await service.headObjectID(repository: fixture.url)
        let detachedHead = try XCTUnwrap(resolvedDetachedHead)
        let detachedTips = try await service.historyTips(repository: fixture.url)
        let detached = try await service.history(repository: fixture.url, scope: .mixed, tips: detachedTips)
        XCTAssertEqual(detachedTips.localObjectID, detachedHead)
        XCTAssertNil(detachedTips.upstreamObjectID)
        XCTAssertEqual(detached.first?.objectID, detachedHead)
        XCTAssertEqual(detached.first?.subject, "commit 11")
    }

    func testHistoryScopesSeparateLocalAndUpstreamAncestry() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "base.txt")
        try fixture.git("add", "--", "base.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("checkout", "-b", "upstream-work")
        try fixture.write("upstream\n", to: "upstream.txt")
        try fixture.git("add", "--", "upstream.txt")
        try fixture.git("commit", "-m", "upstream change")
        let upstreamObjectID = String(decoding: try fixture.git("rev-parse", "HEAD").standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git("checkout", "main")
        try fixture.write("local\n", to: "local.txt")
        try fixture.git("add", "--", "local.txt")
        try fixture.git("commit", "-m", "local change")
        try fixture.git("remote", "add", "origin", ".")
        try fixture.git("update-ref", "refs/remotes/origin/main", upstreamObjectID)
        try fixture.git("branch", "--set-upstream-to=origin/main", "main")

        let service = GitService()
        let tips = try await service.historyTips(repository: fixture.url)
        let mixed = try await service.history(repository: fixture.url, scope: .mixed, tips: tips)
        let local = try await service.history(repository: fixture.url, scope: .local, tips: tips)
        let upstream = try await service.history(repository: fixture.url, scope: .upstream, tips: tips)
        let unmergedUpstream = try await service.history(
            repository: fixture.url,
            scope: .unmergedUpstream,
            tips: tips
        )

        XCTAssertNotNil(tips.localObjectID)
        XCTAssertEqual(tips.upstreamObjectID, upstreamObjectID)
        XCTAssertEqual(mixed.map(\.subject), ["local change", "base"])
        XCTAssertEqual(local.map(\.subject), ["local change"])
        XCTAssertEqual(upstream.map(\.subject), ["upstream change", "base"])
        XCTAssertEqual(unmergedUpstream.map(\.subject), ["upstream change"])
    }

    func testCommitPatchLineFallbackRetainsChangedFiles() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write(String(repeating: "line\n", count: 20_001), to: "large.txt")
        try fixture.git("add", "--", "large.txt")
        try fixture.git("commit", "-m", "large root")
        let service = GitService()
        let history = try await service.history(repository: fixture.url)
        let commit = try XCTUnwrap(history.first)

        let details = try await service.show(repository: fixture.url, objectID: commit.objectID)

        XCTAssertEqual(details.diff.fallback?.reason, .lineLimit(DiffLimits.render.maximumLines))
        XCTAssertEqual(details.diff.fallback?.files.map(\.path), ["large.txt"])
        XCTAssertTrue(details.patch.contains(Data("large.txt".utf8)))
        XCTAssertEqual(details.rawPatch.completeness, .complete)
        XCTAssertEqual(details.diff.exactRawPatch, details.patch)
        XCTAssertTrue(details.metadata.changedFiles.completeness.isComplete)
    }

    func testStatusDiffHistoryAndShowAcrossFixtureStates() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "root")
        let service = GitService()

        var status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.isClean)

        try fixture.write("base\nworktree\n", to: "tracked.txt")
        status = try await service.status(repository: fixture.url)
        XCTAssertEqual(status.changes.first?.worktreeState, .modified)

        try fixture.git("add", "--", "tracked.txt")
        try fixture.write("base\nworktree\nafter-index\n", to: "tracked.txt")
        try fixture.write("odd\n", to: "odd\tline\n雪.txt")
        status = try await service.status(repository: fixture.url)
        let tracked = try XCTUnwrap(status.changes.first { $0.path == "tracked.txt" })
        XCTAssertEqual(tracked.indexState, .modified)
        XCTAssertEqual(tracked.worktreeState, .modified)
        XCTAssertTrue(status.changes.contains { $0.kind == .untracked && $0.path == "odd\tline\n雪.txt" })

        let unstaged = try await service.diff(repository: fixture.url, kind: .unstaged, changes: [tracked])
        let staged = try await service.diff(repository: fixture.url, kind: .staged, changes: [tracked])
        XCTAssertTrue(unstaged.text.contains("after-index"))
        XCTAssertTrue(staged.text.contains("worktree"))

        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "second")
        let history = try await service.history(repository: fixture.url)
        XCTAssertEqual(history.map(\.subject), ["second", "root"])

        let root = try XCTUnwrap(history.last)
        let details = try await service.show(repository: fixture.url, objectID: root.objectID)
        XCTAssertTrue(String(decoding: details.patch, as: UTF8.self).contains("tracked.txt"))
        XCTAssertEqual(details.commit.parentIDs, [])
    }

    func testStatusIncludesGitHubURLForExternalRemote() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.git("remote", "add", "origin", "git@github.com:octo/repo.git")

        let githubURL = try await GitService().githubURL(repository: fixture.url)

        XCTAssertEqual(githubURL, URL(string: "https://github.com/octo/repo"))
    }

    func testRefreshingUpstreamFetchesWithoutMergingLocalBranch() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "base.txt")
        try fixture.git("add", "--", "base.txt")
        try fixture.git("commit", "-m", "base")

        let parent = fixture.url.deletingLastPathComponent()
        let remote = parent.appendingPathComponent("remote-\(UUID().uuidString).git", isDirectory: true)
        let peer = parent.appendingPathComponent("peer-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: peer)
        }
        try runGit(at: parent, arguments: ["init", "--bare", "-b", "main", remote.path])
        try fixture.git("remote", "add", "--", "--all", remote.path)
        try fixture.git("push", "-u", "--", "--all", "main")
        try fixture.git("branch", "tracking-local", "HEAD")
        try fixture.git("symbolic-ref", "refs/remotes/--all/main", "refs/heads/tracking-local")
        let localTrackingBefore = try fixture.git("rev-parse", "refs/heads/tracking-local").standardOutput
        try runGit(at: parent, arguments: ["clone", remote.path, peer.path])
        try runGit(at: peer, arguments: ["config", "user.name", "Peer User"])
        try runGit(at: peer, arguments: ["config", "user.email", "peer@example.com"])
        try "remote\n".write(
            to: peer.appendingPathComponent("remote.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: peer, arguments: ["add", "--", "remote.txt"])
        try runGit(at: peer, arguments: ["commit", "-m", "remote change"])
        try runGit(at: peer, arguments: ["push", "origin", "main"])

        let headBefore = try fixture.git("rev-parse", "HEAD").standardOutput
        let service = GitService()
        let stale = try await service.status(repository: fixture.url)
        XCTAssertEqual(stale.branch.behind, 0)

        let refreshed = try await service.status(repository: fixture.url, refreshUpstream: true)

        XCTAssertEqual(refreshed.branch.upstream, "--all/main")
        XCTAssertEqual(refreshed.branch.behind, 1)
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD").standardOutput, headBefore)
        XCTAssertEqual(
            try fixture.git("rev-parse", "refs/heads/tracking-local").standardOutput,
            localTrackingBefore
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("remote.txt").path))

        try fixture.git("update-ref", "-d", "refs/remotes/--all/main")
        try fixture.git("symbolic-ref", "refs/remotes/--all/main", "refs/heads/missing")
        try "second\n".write(
            to: peer.appendingPathComponent("second.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: peer, arguments: ["add", "--", "second.txt"])
        try runGit(at: peer, arguments: ["commit", "-m", "second remote change"])
        try runGit(at: peer, arguments: ["push", "origin", "main"])

        let refreshedDangling = try await service.status(repository: fixture.url, refreshUpstream: true)

        XCTAssertEqual(refreshedDangling.branch.behind, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url.appendingPathComponent(".git/refs/heads/missing").path
        ))
    }

    func testRefreshingUpstreamSurfacesFetchFailureWithoutChangingLocalState() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "base.txt")
        try fixture.git("add", "--", "base.txt")
        try fixture.git("commit", "-m", "base")

        let remote = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString).git", isDirectory: true)
        try runGit(at: fixture.url.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("push", "-u", "origin", "main")
        let headBefore = try fixture.git("rev-parse", "HEAD").standardOutput
        try FileManager.default.removeItem(at: remote)
        let service = GitService()

        await XCTAssertThrowsErrorAsync(
            {
                _ = try await service.status(repository: fixture.url, refreshUpstream: true)
            },
            assertError: { (error: GitRunnerError) in
                guard case .nonZeroExit(let result) = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
                XCTAssertNotEqual(result.exitCode, 0)
            }
        )

        let localStatus = try await service.status(repository: fixture.url)
        XCTAssertEqual(localStatus.branch.upstream, "origin/main")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD").standardOutput, headBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("remote.txt").path))
    }

    func testRefreshingUpstreamRejectsFetchMappingsIntoLocalBranches() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "base.txt")
        try fixture.git("add", "--", "base.txt")
        try fixture.git("commit", "-m", "base")

        let remote = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("remote-\(UUID().uuidString).git", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: remote) }
        try runGit(at: fixture.url.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("config", "remote.origin.fetch", "+refs/heads/main:refs/heads/tracking")
        try fixture.git("push", "origin", "main")
        try fixture.git("fetch", "origin")
        try fixture.git("config", "branch.main.remote", "origin")
        try fixture.git("config", "branch.main.merge", "refs/heads/main")
        let trackingBefore = try fixture.git("rev-parse", "refs/heads/tracking").standardOutput
        let service = GitService()

        do {
            _ = try await service.status(repository: fixture.url, refreshUpstream: true)
            XCTFail("Expected unsafe upstream mapping to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .unsupportedUpstreamRef("refs/heads/tracking"))
        }

        XCTAssertEqual(try fixture.git("rev-parse", "refs/heads/tracking").standardOutput, trackingBefore)
    }

}
