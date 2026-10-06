import Foundation
@testable import Intreccio
import XCTest

final class GitServicePushTests: XCTestCase {
    func testPushSendsOnlyConfiguredBranchAndLeavesUncommittedChanges() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: ["init", "--bare", "-b", "main", remote.path])
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("push", "--set-upstream", "origin", "main")
        try fixture.write("local\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "local")
        try fixture.write("uncommitted\n", to: "uncommitted.txt")
        let localHead = try fixture.git("rev-parse", "HEAD")
            .standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let service = GitService()
        let target = try await service.preparePushTarget(repository: fixture.url)
        try await service.pushToUpstream(target: target)

        let remoteHead = try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"]).standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteHead, localHead)
        let uncommittedPath = fixture.url.appendingPathComponent("uncommitted.txt").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: uncommittedPath))
    }

    func testPushRefusesDivergedUpstreamWithoutForcePushing() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: ["init", "--bare", "-b", "main", remote.path])
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("push", "--set-upstream", "origin", "main")
        try fixture.write("local\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "local")

        let peer = try makeTestDirectory()
        try runGit(at: peer.deletingLastPathComponent(), arguments: ["clone", remote.path, peer.path])
        try runGit(at: peer, arguments: ["config", "user.name", "Peer"])
        try runGit(at: peer, arguments: ["config", "user.email", "peer@example.com"])
        try "remote\n".write(to: peer.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try runGit(at: peer, arguments: ["add", "--", "remote.txt"])
        try runGit(at: peer, arguments: ["commit", "-m", "remote"])
        try runGit(at: peer, arguments: ["push", "origin", "main"])
        let remoteHead = try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"]).standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let service = GitService()
            let target = try await service.preparePushTarget(repository: fixture.url)
            try await service.pushToUpstream(target: target)
            XCTFail("Expected a diverged branch to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .branchBehindUpstream)
        }

        XCTAssertEqual(
            try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"]).standardOutputText
                .trimmingCharacters(in: .whitespacesAndNewlines),
            remoteHead
        )
    }

    func testPushRefusesHeadChangedAfterConfirmation() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: ["init", "--bare", "-b", "main", remote.path])
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("push", "--set-upstream", "origin", "main")
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "first")
        let service = GitService()
        let target = try await service.preparePushTarget(repository: fixture.url)
        let remoteHead = try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"]).standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("second\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "second")

        do {
            try await service.pushToUpstream(target: target)
            XCTFail("Expected a changed HEAD to invalidate confirmation")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .pushTargetChanged)
        }

        XCTAssertEqual(
            try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"]).standardOutputText
                .trimmingCharacters(in: .whitespacesAndNewlines),
            remoteHead
        )
    }
}
