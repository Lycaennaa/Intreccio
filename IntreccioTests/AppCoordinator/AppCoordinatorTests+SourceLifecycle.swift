import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testSelectionChangeRejectsInFlightDiffResult() async throws {
        let directory = try makeTestDirectory()
        let first = directory.appendingPathComponent("First", isDirectory: true)
        let second = directory.appendingPathComponent("Second", isDirectory: true)
        try initializeRepository(at: first)
        try initializeRepository(at: second)
        try Data(repeating: 0x61, count: 2_000_000).write(
            to: first.appendingPathComponent("large.txt"),
            options: .atomic
        )
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(first)
        await coordinator.addStandaloneRepository(second)
        let firstID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == first })?.id)
        let secondID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == second })?.id)
        coordinator.selectRepository(firstID)
        try await waitUntil(description: "first repository status") {
            coordinator.repositoryRefreshStates[firstID]?.status != nil
        }
        let changes = try XCTUnwrap(coordinator.repositoryRefreshStates[firstID]?.status?.changes)

        coordinator.requestSelectedDiff(changes: changes, kind: .unstaged)
        await Task.yield()
        coordinator.selectRepository(secondID)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(coordinator.state.uiState.selectedRepoID, secondID)
        if case .loaded = coordinator.selectedDiffState {
            XCTFail("Stale diff from the previous selection was accepted")
        }
    }

    func testShutdownCancelsAndDrainsPublicCatalogCommand() async throws {
        let directory = try makeTestDirectory()
        let workspace = directory.appendingPathComponent("Workspace", isDirectory: true)
        for index in 0..<300 {
            try FileManager.default.createDirectory(
                at: workspace.appendingPathComponent("Folder-\(index)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        async let add: Void = coordinator.addWatchRoot(workspace)
        await Task.yield()

        let saved = await coordinator.shutdown()
        await add
        let stateAfterShutdown = coordinator.state
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(saved)
        XCTAssertEqual(coordinator.state, stateAfterShutdown)
    }
}
