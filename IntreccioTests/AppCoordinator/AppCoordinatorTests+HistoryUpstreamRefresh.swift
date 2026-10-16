import Foundation
@testable import Intreccio
import XCTest

private struct HistoryUpstreamMergeFixture {
    let directory: URL
    let repository: URL
    let remote: URL
    let sideObjectID: String
    let mainObjectID: String
    let mergeObjectID: String
}

@MainActor
extension AppCoordinatorTests {
    func testHistoryMarkersRefreshWhenUpstreamMovesBetweenMergeParents() async throws {
        let fixture = try makeHistoryUpstreamMergeFixture()
        let coordinator = makeCoordinator(
            stateFile: fixture.directory.appendingPathComponent("state.json")
        )
        addTeardownBlock { _ = await coordinator.shutdown() }
        await coordinator.addStandaloneRepository(fixture.repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.setMode(.history)
        coordinator.selectRepository(repositoryID)
        try await waitUntil(description: "initial merge history markers") {
            coordinator.selectedHistoryState.phase == .idle
                && coordinator.selectedHistoryState.commits.count == 4
                && coordinator.selectedHistoryState.notOnUpstreamObjectIDs != nil
                && coordinator.repositoryRefreshStates[repositoryID]?.status != nil
        }

        XCTAssertEqual(
            coordinator.selectedHistoryState.tips?.localObjectID,
            fixture.mergeObjectID
        )
        XCTAssertEqual(
            coordinator.selectedHistoryState.tips?.upstreamObjectID,
            fixture.sideObjectID
        )
        XCTAssertEqual(
            coordinator.selectedHistoryState.notOnUpstreamObjectIDs,
            Set([fixture.mergeObjectID, fixture.mainObjectID])
        )
        let statusBefore = try XCTUnwrap(
            coordinator.repositoryRefreshStates[repositoryID]?.status?.branch
        )
        XCTAssertEqual(statusBefore.ahead, 2)
        XCTAssertEqual(statusBefore.behind, 0)

        try runGit(
            at: fixture.remote,
            arguments: ["update-ref", "refs/heads/main", fixture.mainObjectID]
        )
        coordinator.refetchUpstream(for: repositoryID)
        try await waitUntil(description: "updated merge history markers") {
            coordinator.selectedHistoryState.phase == .idle
                && coordinator.selectedHistoryState.tips?.upstreamObjectID == fixture.mainObjectID
                && coordinator.selectedHistoryState.notOnUpstreamObjectIDs
                    == Set([fixture.mergeObjectID, fixture.sideObjectID])
        }

        let statusAfter = try XCTUnwrap(
            coordinator.repositoryRefreshStates[repositoryID]?.status?.branch
        )
        XCTAssertEqual(statusAfter, statusBefore)
        XCTAssertEqual(
            coordinator.selectedHistoryState.notOnUpstreamObjectIDs,
            Set([fixture.mergeObjectID, fixture.sideObjectID])
        )
    }

    func testHistoryMarksCommitsMissingFromConfiguredUpstream() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        let remote = directory.appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: directory, arguments: ["init", "--bare", remote.path])
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        try "upstream\n".write(
            to: repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: repository, arguments: ["add", "-A"])
        try runGit(at: repository, arguments: ["commit", "-m", "upstream commit"])
        let upstreamObjectID = try XCTUnwrap(
            String(
                bytes: try runGit(at: repository, arguments: ["rev-parse", "HEAD"]).standardOutput,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try runGit(at: repository, arguments: ["remote", "add", "origin", remote.path])
        try runGit(at: repository, arguments: ["push", "--set-upstream", "origin", "main"])
        try "local\n".write(
            to: repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: repository, arguments: ["add", "-A"])
        try runGit(at: repository, arguments: ["commit", "-m", "local commit"])
        let localObjectID = try XCTUnwrap(
            String(
                bytes: try runGit(at: repository, arguments: ["rev-parse", "HEAD"]).standardOutput,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.setMode(.history)
        coordinator.selectRepository(repositoryID)
        try await waitUntil(description: "history upstream commit markers") {
            coordinator.selectedHistoryState.phase == .idle
                && coordinator.selectedHistoryState.commits.count == 2
                && coordinator.selectedHistoryState.notOnUpstreamObjectIDs != nil
        }

        XCTAssertEqual(coordinator.selectedHistoryState.tips?.localObjectID, localObjectID)
        XCTAssertEqual(coordinator.selectedHistoryState.tips?.upstreamObjectID, upstreamObjectID)
        XCTAssertEqual(coordinator.selectedHistoryState.notOnUpstreamObjectIDs, Set([localObjectID]))
        XCTAssertFalse(
            coordinator.selectedHistoryState.notOnUpstreamObjectIDs?.contains(upstreamObjectID)
                ?? true
        )
        _ = await coordinator.shutdown()
    }

    private func makeHistoryUpstreamMergeFixture() throws -> HistoryUpstreamMergeFixture {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        let remote = directory.appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: directory, arguments: ["init", "--bare", remote.path])
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        try "base\n".write(
            to: repository.appendingPathComponent("base.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: repository, arguments: ["add", "-A"])
        try runGit(at: repository, arguments: ["commit", "-m", "base"])
        try runGit(at: repository, arguments: ["checkout", "-b", "side"])
        try "side\n".write(
            to: repository.appendingPathComponent("side.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: repository, arguments: ["add", "-A"])
        try runGit(at: repository, arguments: ["commit", "-m", "side"])
        let sideObjectID = try commitObjectID(in: repository)
        try runGit(at: repository, arguments: ["remote", "add", "origin", remote.path])
        try runGit(at: repository, arguments: ["push", "origin", "side:main"])
        try runGit(at: repository, arguments: ["fetch", "origin"])
        try runGit(at: repository, arguments: ["checkout", "main"])
        try "main\n".write(
            to: repository.appendingPathComponent("main.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: repository, arguments: ["add", "-A"])
        try runGit(at: repository, arguments: ["commit", "-m", "main"])
        let mainObjectID = try commitObjectID(in: repository)
        try runGit(at: repository, arguments: ["push", "origin", "main:refs/heads/refresh-target"])
        try runGit(at: repository, arguments: ["branch", "--set-upstream-to=origin/main", "main"])
        try runGit(at: repository, arguments: ["merge", "--no-ff", "side", "-m", "merge"])
        return HistoryUpstreamMergeFixture(
            directory: directory,
            repository: repository,
            remote: remote,
            sideObjectID: sideObjectID,
            mainObjectID: mainObjectID,
            mergeObjectID: try commitObjectID(in: repository)
        )
    }

    private func commitObjectID(in repository: URL) throws -> String {
        try XCTUnwrap(
            String(
                bytes: try runGit(at: repository, arguments: ["rev-parse", "HEAD"]).standardOutput,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
