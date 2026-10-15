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
