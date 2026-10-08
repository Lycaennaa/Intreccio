import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testResourceIdentityPreservesRepositoryIDAcrossRename() async throws {
        let directory = try makeTestDirectory()
        let original = directory.appendingPathComponent("Before", isDirectory: true)
        let renamed = directory.appendingPathComponent("After", isDirectory: true)
        try initializeRepository(at: original)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        try FileManager.default.moveItem(at: original, to: renamed)

        await coordinator.restoreSources()

        XCTAssertEqual(coordinator.repositories.first?.id, repositoryID)
        XCTAssertEqual(coordinator.repositories.first?.canonicalURL, renamed.resolvingSymlinksInPath().standardizedFileURL)
    }

    func testOpenDirectoryURLRejectsPathReplacementBeforeRescan() async throws {
        let directory = try makeTestDirectory()
        let original = directory.appendingPathComponent("Repo", isDirectory: true)
        let replacement = directory.appendingPathComponent("Replacement", isDirectory: true)
        try initializeRepository(at: original)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(original)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        XCTAssertNotNil(coordinator.repositories.first?.resourceID)

        try FileManager.default.moveItem(at: original, to: replacement)
        try initializeRepository(at: original)

        let controller = RepoSidebarViewController(coordinator: coordinator)
         XCTAssertNil(controller.applicationController.openDirectoryURL(for: repositoryID, parentDirectory: false))
         XCTAssertNil(controller.applicationController.openDirectoryURL(for: repositoryID, parentDirectory: true))
    }

    func testRenameAndPathReplacementNeverReuseOneRepositoryIDTwice() async throws {
        let directory = try makeTestDirectory()
        let original = directory.appendingPathComponent("Before", isDirectory: true)
        let renamed = directory.appendingPathComponent("After", isDirectory: true)
        try initializeRepository(at: original)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let originalID = try XCTUnwrap(coordinator.repositories.first?.id)
        try FileManager.default.moveItem(at: original, to: renamed)
        try initializeRepository(at: original)

        await coordinator.restoreSources()

        XCTAssertEqual(Set(coordinator.repositories.map(\.id)).count, 2)
        XCTAssertEqual(coordinator.repositories.first(where: { $0.canonicalURL == renamed })?.id, originalID)
        XCTAssertNotEqual(coordinator.repositories.first(where: { $0.canonicalURL == original })?.id, originalID)
    }

    func testExactPathReplacementSuppressesStaleUnavailableDuplicate() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        await coordinator.addWatchRoot(directory)
        let originalID = try XCTUnwrap(coordinator.repositories.first?.id)
        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)
        coordinator.setRepositoryPinned(originalID, pinned: true)
        coordinator.selectRepository(originalID)
        try FileManager.default.removeItem(at: repository)
        try initializeRepository(at: repository)

        coordinator.rescanSource(sourceID)
        try await waitUntil(description: "replacement source rescan") {
            coordinator.repositories.first?.id != originalID
        }

        XCTAssertEqual(coordinator.repositories.count, 1)
        XCTAssertNotEqual(coordinator.repositories.first?.id, originalID)
        XCTAssertEqual(coordinator.repositories.first?.availability, .available)
        XCTAssertFalse(coordinator.state.uiState.pinnedRepositoryIDs.contains(originalID))
        XCTAssertNil(coordinator.state.uiState.selectedRepoID)
        let persisted = await StateStore(fileURL: stateFile).load()
        XCTAssertFalse(persisted.state.uiState.pinnedRepositoryIDs.contains(originalID))
        XCTAssertNil(persisted.state.uiState.selectedRepoID)
    }
}
