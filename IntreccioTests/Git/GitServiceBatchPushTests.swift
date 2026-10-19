import Foundation
@testable import Intreccio
import XCTest

private struct BatchPushRepository {
    let fixture: GitFixture
    let remote: URL
    let descriptor: RepoDescriptor
    let target: GitPushTarget
}

final class GitServiceBatchPushTests: XCTestCase {
    @MainActor
    func testBatchPushContinuesAfterAChangedTargetAndStillPushesLaterTargets() async throws {
        let service = GitService()
        let stale = try await makeRepository(named: "stale", service: service)
        let valid = try await makeRepository(named: "valid", service: service)
        try stale.fixture.write("changed after selection\n", to: "tracked.txt")
        try stale.fixture.git("commit", "-am", "changed after selection")
        let staleRemoteHead = try remoteHead(at: stale.remote)

        let stateDirectory = try makeTestDirectory()
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: stateDirectory.appendingPathComponent("state.json")),
            gitService: service,
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [
                stale.descriptor, valid.descriptor
            ])
        )
        addTeardownBlock { _ = await coordinator.shutdown() }
        coordinator.state.uiState.mode = .history

        coordinator.pushToUpstream([stale.target, valid.target])
        let failure = await coordinator.waitForActiveMutation()

        XCTAssertEqual(failure?.title, "Some repositories could not be pushed")
        XCTAssertTrue(failure?.details.contains(stale.descriptor.displayName) == true)
        XCTAssertEqual(try remoteHead(at: stale.remote), staleRemoteHead)
        XCTAssertEqual(try remoteHead(at: valid.remote), valid.target.headObjectID)
    }

    @MainActor
    private func makeRepository(named name: String, service: GitService) async throws -> BatchPushRepository {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("\(name).git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("push", "--set-upstream", "origin", "main")
        try fixture.write("ahead\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "ahead")
        let status = try await service.status(repository: fixture.url)
        let target = try await service.preparePushTarget(repository: fixture.url, status: status)
        let id = UUID()
        let descriptor = RepoDescriptor(
            id: id,
            source: .standalone(id: id),
            url: fixture.url,
            canonicalURL: fixture.url,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        return BatchPushRepository(
            fixture: fixture,
            remote: remote,
            descriptor: descriptor,
            target: target
        )
    }

    private func remoteHead(at remote: URL) throws -> String {
        try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"])
            .standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class GitServiceInitialPushTests: XCTestCase {
    func testFirstPushToEmptyOriginSetsUpstreamForLaterPushes() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "initial")
        try fixture.git("remote", "add", "origin", remote.path)

        let service = GitService()
        let status = try await service.statusWithoutDiffStats(repository: fixture.url)
        XCTAssertTrue(status.hasOriginPushDestination)
        XCTAssertTrue(PushToOriginPolicy.canPushInitialCommitToOrigin(status: status))

        let target = try await service.preparePushTarget(repository: fixture.url, status: status)
        XCTAssertEqual(target.upstream, "origin/main")
        XCTAssertEqual(target.ahead, 1)
        try await service.pushToUpstream(target: target)

        let firstHead = try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"])
            .standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(firstHead, target.headObjectID)
        XCTAssertEqual(
            try fixture.git("config", "--get", "branch.main.remote").standardOutputText
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "origin"
        )
        XCTAssertEqual(
            try fixture.git("config", "--get", "branch.main.merge").standardOutputText
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "refs/heads/main"
        )
        XCTAssertEqual(
            try fixture.git("config", "--get-all", "remote.origin.fetch").standardOutputText,
            "+refs/heads/*:refs/remotes/origin/*\n"
        )

        let refreshed = try await service.statusWithoutDiffStats(
            repository: fixture.url,
            refreshUpstream: true
        )
        XCTAssertEqual(refreshed.branch.upstream, "origin/main")
        XCTAssertEqual(refreshed.branch.ahead, 0)

        try fixture.write("second\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "second")
        let nextTarget = try await service.preparePushTarget(repository: fixture.url)
        XCTAssertEqual(nextTarget.ahead, 1)
        try await service.pushToUpstream(target: nextTarget)
        let secondHead = try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"])
            .standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(secondHead, nextTarget.headObjectID)
    }
    func testInitialPushReplacesStaleConflictingRemoteTrackingRef() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "initial")
        let head = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("update-ref", "refs/remotes/origin/main/removed", head)

        let service = GitService()
        let target = try await service.preparePushTarget(repository: fixture.url)
        try await service.pushToUpstream(target: target)

        XCTAssertEqual(
            try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"])
                .standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines),
            head
        )
        XCTAssertEqual(
            try fixture.git("for-each-ref", "--format=%(refname)", "refs/remotes/origin")
                .standardOutputText,
            "refs/remotes/origin/main\n"
        )
        let status = try await service.statusWithoutDiffStats(repository: fixture.url)
        XCTAssertEqual(status.branch.upstream, "origin/main")
    }
    func testInitialPushRemovesStaleAncestorRemoteTrackingRef() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "initial")
        let head = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git("switch", "-c", "topic/feature")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("update-ref", "refs/remotes/origin/topic", head)

        let service = GitService()
        let target = try await service.preparePushTarget(repository: fixture.url)
        XCTAssertEqual(target.branch, "topic/feature")
        try await service.pushToUpstream(target: target)

        XCTAssertEqual(
            try fixture.git("for-each-ref", "--format=%(refname)", "refs/remotes/origin")
                .standardOutputText,
            "refs/remotes/origin/topic/feature\n"
        )
        let status = try await service.statusWithoutDiffStats(repository: fixture.url)
        XCTAssertEqual(status.branch.upstream, "origin/topic/feature")
    }


    func testInitialPushReportsNoOutgoingCommitsWhenOriginAlreadyHasHead() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "initial")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("push", remote.path, "HEAD:refs/heads/main")

        let service = GitService()
        let target = try await service.preparePushTarget(repository: fixture.url)
        XCTAssertEqual(target.ahead, 0)
        try await service.pushToUpstream(target: target)

        let status = try await service.statusWithoutDiffStats(repository: fixture.url)
        XCTAssertEqual(status.branch.upstream, "origin/main")
        XCTAssertEqual(status.branch.ahead, 0)
    }
    func testInitialPushAddsTrackingForSingleBranchOriginFetch() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "initial")
        try fixture.git("switch", "-c", "topic")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git(
            "config", "--local", "--replace-all",
            "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main"
        )

        let service = GitService()
        let firstTarget = try await service.preparePushTarget(repository: fixture.url)
        try await service.pushToUpstream(target: firstTarget)
        let initialStatus = try await service.statusWithoutDiffStats(repository: fixture.url)
        XCTAssertEqual(initialStatus.branch.upstream, "origin/topic")

        try fixture.write("second\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "second")
        let nextTarget = try await service.preparePushTarget(repository: fixture.url)
        XCTAssertEqual(nextTarget.upstream, "origin/topic")
        XCTAssertEqual(nextTarget.ahead, 1)
        try await service.pushToUpstream(target: nextTarget)
        XCTAssertEqual(
            try runGit(at: remote, arguments: ["rev-parse", "refs/heads/topic"])
                .standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines),
            nextTarget.headObjectID
        )
    }

    func testInitialPushRejectsOriginFetchExcludedBranchBeforePushing() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "initial")
        try fixture.git("switch", "-c", "topic")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git(
            "config", "--local", "--replace-all",
            "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"
        )
        try fixture.git(
            "config", "--local", "--add", "remote.origin.fetch", "^refs/heads/topic"
        )

        do {
            _ = try await GitService().preparePushTarget(repository: fixture.url)
            XCTFail("Expected the excluded branch to be rejected before pushing")
        } catch {
            XCTAssertEqual(
                error as? GitServiceError,
                .invalidPushDestination("origin fetch refspec excludes refs/heads/topic")
            )
        }
        XCTAssertEqual(
            try runGit(at: remote, arguments: ["for-each-ref", "--format=%(refname)"])
                .standardOutputText,
            ""
        )
    }

    func testInitialPushRejectsNonstandardOriginTrackingNamespaceBeforePushing() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "initial")
        try fixture.git("switch", "-c", "topic")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git(
            "config", "--local", "--replace-all",
            "remote.origin.fetch", "+refs/heads/*:refs/remotes/cache/*"
        )

        do {
            _ = try await GitService().preparePushTarget(repository: fixture.url)
            XCTFail("Expected a nonstandard origin tracking namespace to be rejected")
        } catch {
            XCTAssertEqual(
                error as? GitServiceError,
                .invalidPushDestination(
                    "origin fetch refspec maps refs/heads/topic to refs/remotes/cache/topic, not refs/remotes/origin/topic"
                )
            )
        }
        XCTAssertEqual(
            try runGit(at: remote, arguments: ["for-each-ref", "--format=%(refname)"])
                .standardOutputText,
            ""
        )
    }

    func testInitialPushRejectsRemoteBranchCreatedAfterTargetConfirmation() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        let baseHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("local\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "local")
        try fixture.git("remote", "add", "origin", remote.path)
        let service = GitService()
        let target = try await service.preparePushTarget(repository: fixture.url)
        XCTAssertEqual(
            target.initialPushExpectedRemoteHeads,
            [String(repeating: "0", count: target.headObjectID.count)]
        )

        try fixture.git("push", remote.path, "\(baseHead):refs/heads/main")
        do {
            try await service.pushToUpstream(target: target)
            XCTFail("Expected a branch created after confirmation to invalidate the target")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .pushTargetChanged)
        }
        let remoteHead = try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"])
            .standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteHead, baseHead)
    }
    func testInitialOriginPermissionSurvivesStatusAccessRefresh() async throws {
        let fixture = try GitFixture(testCase: self)
        var status = RepoStatus()
        status.branch.head = "main"
        status.branch.objectID = "0123456789abcdef0123456789abcdef01234567"
        status.hasOriginPushDestination = true
        status.pushAccess = .denied

        let access = try await GitService().pushAccessForStatus(
            status,
            repository: fixture.url,
            priority: .normal
        )

        XCTAssertEqual(access, .denied)
    }

}
final class GitServiceInitialPushConfigurationTests: XCTestCase {
    func testInitialPushRejectsDifferentFetchAndPushURLs() async throws {
        let fixture = try GitFixture(testCase: self)
        let remotes = try makeTestDirectory()
        let fetchRemote = remotes.appendingPathComponent("fetch.git", isDirectory: true)
        let pushRemote = remotes.appendingPathComponent("push.git", isDirectory: true)
        for remote in [fetchRemote, pushRemote] {
            try runGit(at: remotes, arguments: ["init", "--bare", "-b", "main", remote.path])
        }
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "initial")
        try fixture.git("remote", "add", "origin", fetchRemote.path)
        try fixture.git("remote", "set-url", "--push", "origin", pushRemote.path)

        do {
            _ = try await GitService().preparePushTarget(repository: fixture.url)
            XCTFail("Expected a push destination without a matching fetch URL to be rejected")
        } catch {
            XCTAssertEqual(
                error as? GitServiceError,
                .invalidPushDestination("origin fetch URL is not a configured push destination")
            )
        }
        let refs = try runGit(at: pushRemote, arguments: ["for-each-ref", "--format=%(refname)"])
        XCTAssertEqual(refs.standardOutputText, "")
    }
    func testInitialPushRejectsGlobalOriginFetchExclusionBeforePushing() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "initial")
        try fixture.git("switch", "-c", "topic")
        try fixture.git("remote", "add", "origin", remote.path)
        let globalConfig = try makeTestDirectory().appendingPathComponent("global.gitconfig")
        try Data("[remote \"origin\"]\n\tfetch = ^refs/heads/topic\n".utf8).write(to: globalConfig)

        do {
            _ = try await GitService(
                runner: GitConfigScopeRunner(globalConfig: globalConfig)
            ).preparePushTarget(repository: fixture.url)
            XCTFail("Expected the global fetch exclusion to be respected before pushing")
        } catch {
            XCTAssertEqual(
                error as? GitServiceError,
                .invalidPushDestination("origin fetch refspec excludes refs/heads/topic")
            )
        }
        XCTAssertEqual(
            try runGit(at: remote, arguments: ["for-each-ref", "--format=%(refname)"])
                .standardOutputText,
            ""
        )
    }
    func testInitialPushRejectsSymbolicTrackingNamespaceConflictBeforePushing() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "initial")
        try fixture.git("switch", "-c", "HEAD/topic")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git(
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main"
        )

        do {
            let service = GitService()
            let target = try await service.preparePushTarget(repository: fixture.url)
            try await service.pushToUpstream(target: target)
            XCTFail("Expected a symbolic tracking-ref conflict to block the push")
        } catch {
            XCTAssertEqual(
                error as? GitServiceError,
                .invalidPushDestination(
                    "origin tracking ref namespace has symbolic ref refs/remotes/origin/HEAD"
                )
            )
        }
        XCTAssertEqual(
            try runGit(at: remote, arguments: ["for-each-ref", "--format=%(refname)"])
                .standardOutputText,
            ""
        )
    }
}
