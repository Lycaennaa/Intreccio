import AppKit
import Foundation
import XCTest
@testable import Intreccio

extension AppCoordinatorTests {
    func testRepositoryWatcherEventRefreshesOnlyChangedRepository() async throws {
        let directory = try makeTestDirectory()
        let workspace = directory.appendingPathComponent("Workspace", isDirectory: true)
        let first = workspace.appendingPathComponent("First", isDirectory: true)
        let second = workspace.appendingPathComponent("Second", isDirectory: true)
        try initializeRepository(at: first)
        try initializeRepository(at: second)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        coordinator.start()
        try await waitUntil(description: "coordinator startup") { coordinator.hasLoadedState }
        await coordinator.addWatchRoot(workspace)
        let firstID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == first })?.id)
        let secondID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == second })?.id)
        try await waitUntil(description: "initial repository refreshes") {
            coordinator.repositoryRefreshStates[firstID]?.phase == .idle
                && coordinator.repositoryRefreshStates[firstID]?.status != nil
                && coordinator.repositoryRefreshStates[secondID]?.phase == .idle
                && coordinator.repositoryRefreshStates[secondID]?.status != nil
        }
        XCTAssertTrue(coordinator.activeRepositoryEventWatcherIDs.isEmpty)
        XCTAssertEqual(coordinator.runtime.snapshot.coveredRepositoryIDs, [firstID, secondID])
        let firstGeneration = try XCTUnwrap(coordinator.repositoryRefreshStates[firstID]?.statusGeneration)
        let secondGeneration = try XCTUnwrap(coordinator.repositoryRefreshStates[secondID]?.statusGeneration)

        await coordinator.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [first.appendingPathComponent("changed.txt").path],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            repositoryID: firstID
        )

        try await waitUntil(description: "changed repository refresh") {
            (coordinator.repositoryRefreshStates[firstID]?.statusGeneration ?? 0) > firstGeneration
                && coordinator.repositoryRefreshStates[firstID]?.phase == .idle
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(coordinator.repositoryRefreshStates[secondID]?.statusGeneration, secondGeneration)
        let refreshedFirstGeneration = try XCTUnwrap(
            coordinator.repositoryRefreshStates[firstID]?.statusGeneration
        )
        await coordinator.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [second.appendingPathComponent("stale.txt").path],
                sourceRescanPaths: [],
                requiresFullRescan: true
            ),
            repositoryID: firstID
        )
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(coordinator.repositoryRefreshStates[firstID]?.statusGeneration, refreshedFirstGeneration)
        let saved = await coordinator.shutdown()
        XCTAssertTrue(saved)
    }
}