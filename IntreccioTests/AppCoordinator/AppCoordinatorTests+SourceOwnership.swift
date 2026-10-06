import AppKit
import Foundation
import XCTest
@testable import Intreccio

extension AppCoordinatorTests {
    func testOverlappingRootsUseMostSpecificOwnerAndRemovalDoesNotTouchDisk() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Nested", isDirectory: true)
        try initializeRepository(at: repository)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)

        await coordinator.addWatchRoot(directory)
        await coordinator.addWatchRoot(repository)

        XCTAssertEqual(coordinator.repositories.count, 1)
        let specificSourceID = try XCTUnwrap(coordinator.state.watchRoots.last?.id)
        let stableRepositoryID = coordinator.repositories[0].id
        XCTAssertEqual(coordinator.repositories[0].source.id, specificSourceID)
        coordinator.setRepositoryPinned(stableRepositoryID, pinned: true)
        coordinator.selectRepository(stableRepositoryID)

        await coordinator.removeSource(specificSourceID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.path))
        XCTAssertEqual(coordinator.repositories.count, 1)
        XCTAssertEqual(coordinator.repositories[0].source.id, coordinator.state.watchRoots[0].id)
        XCTAssertEqual(coordinator.repositories[0].id, stableRepositoryID)
        XCTAssertTrue(coordinator.state.uiState.pinnedRepositoryIDs.contains(stableRepositoryID))
        XCTAssertEqual(coordinator.state.uiState.selectedRepoID, stableRepositoryID)
        let persisted = await StateStore(fileURL: stateFile).load()
        XCTAssertEqual(persisted.state.repoSnapshots.first?.id, stableRepositoryID)
        XCTAssertEqual(persisted.state.repoSnapshots.first?.sourceID, coordinator.state.watchRoots[0].id)
        XCTAssertTrue(persisted.state.uiState.pinnedRepositoryIDs.contains(stableRepositoryID))
        XCTAssertEqual(persisted.state.uiState.selectedRepoID, stableRepositoryID)
    }

    func testExcludingSpecificOverlappingRootKeepsRepositoryPinAndSelection() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        await coordinator.addWatchRoot(directory)
        let broadSourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)
        await coordinator.addWatchRoot(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        XCTAssertNotEqual(coordinator.repositories.first?.source.id, broadSourceID)
        coordinator.setRepositoryPinned(repositoryID, pinned: true)
        coordinator.selectRepository(repositoryID)

        await coordinator.excludeRepository(repositoryID)

        XCTAssertEqual(coordinator.repositories.first?.id, repositoryID)
        XCTAssertEqual(coordinator.repositories.first?.source.id, broadSourceID)
        XCTAssertTrue(coordinator.state.uiState.pinnedRepositoryIDs.contains(repositoryID))
        XCTAssertEqual(coordinator.state.uiState.selectedRepoID, repositoryID)
        let persisted = await StateStore(fileURL: stateFile).load()
        XCTAssertTrue(persisted.state.uiState.pinnedRepositoryIDs.contains(repositoryID))
        XCTAssertEqual(persisted.state.uiState.selectedRepoID, repositoryID)
    }

    func testExcludingSpecificRootKeepsRepositoryWhenBroaderScanIsIncomplete() async throws {
        let directory = try makeTestDirectory()
        let first = directory.appendingPathComponent("a-first", isDirectory: true)
        let target = directory.appendingPathComponent("z-target", isDirectory: true)
        try initializeRepository(at: first)
        try initializeRepository(at: target)
        var configuration = RepoScanner.Configuration()
        configuration.repositoryLimit = 1
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
            scanner: RepoScanner(configuration: configuration)
        )
        addTeardownBlock { [coordinator] in
            _ = await coordinator.shutdown()
        }

        await coordinator.addWatchRoot(directory)
        let broadSourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)
        await coordinator.addWatchRoot(target)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == target })?.id)
        coordinator.setRepositoryPinned(repositoryID, pinned: true)
        coordinator.selectRepository(repositoryID)

        await coordinator.excludeRepository(repositoryID)

        XCTAssertEqual(coordinator.repositories.first(where: { $0.canonicalURL == target })?.source.id, broadSourceID)
        XCTAssertTrue(coordinator.state.uiState.pinnedRepositoryIDs.contains(repositoryID))
        XCTAssertEqual(coordinator.state.uiState.selectedRepoID, repositoryID)
    }

    func testExclusionIsPersistedAndRestoringItRediscoversRepository() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)

        await coordinator.excludeRepository(repositoryID)

        XCTAssertTrue(coordinator.repositories.isEmpty)
        XCTAssertEqual(coordinator.state.watchRoots[0].exclusions, ["Repo"])

        await coordinator.restoreExclusion(sourceID: sourceID, path: "Repo")
        await coordinator.restoreSources()

        XCTAssertEqual(coordinator.repositories.count, 1)
        XCTAssertTrue(coordinator.state.watchRoots[0].exclusions.isEmpty)
    }

    func testFolderExclusionRemovesNestedRepositoriesAndRestoringItRediscoversThem() async throws {
        let directory = try makeTestDirectory()
        let active = directory.appendingPathComponent("repos/Active", isDirectory: true)
        let inactive = directory.appendingPathComponent("external/not active/repos/Inactive", isDirectory: true)
        try initializeRepository(at: active)
        try initializeRepository(at: inactive)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)

        await coordinator.addWatchRoot(directory)
        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)
        XCTAssertEqual(Set(coordinator.repositories.map(\.canonicalURL)), Set([active, inactive]))

        await coordinator.excludeFolder(sourceID: sourceID, path: "external/not active")

        XCTAssertEqual(coordinator.repositories.map(\.canonicalURL), [active])
        XCTAssertEqual(coordinator.state.watchRoots.first?.exclusions, ["external/not active"])

        await coordinator.restoreExclusion(sourceID: sourceID, path: "external/not active")
        await coordinator.restoreSources()

        XCTAssertEqual(Set(coordinator.repositories.map(\.canonicalURL)), Set([active, inactive]))
        XCTAssertTrue(coordinator.state.watchRoots.first?.exclusions.isEmpty == true)
    }

    func testRestoringExclusionKeepsSnapshotWhenSourceScanCannotRediscoverRepository() async throws {
        let directory = try makeTestDirectory()
        let workspace = directory.appendingPathComponent("Workspace", isDirectory: true)
        let repository = workspace.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(workspace)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)

        await coordinator.excludeRepository(repositoryID)
        try FileManager.default.removeItem(at: workspace)
        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)
        await coordinator.restoreExclusion(sourceID: sourceID, path: "Repo")

        try await waitUntil(description: "unavailable restored snapshot") {
            guard let repository = coordinator.repositories.first(where: { $0.id == repositoryID }) else { return false }
            if case .unavailable = repository.availability { return true }
            return false
        }
        XCTAssertEqual(coordinator.state.repoSnapshots.first(where: { $0.id == repositoryID })?.relativePath, "Repo")
    }

    func testParentFolderExclusionSupersedesExistingChildExclusion() async throws {
        let directory = try makeTestDirectory()
        let childRepository = directory.appendingPathComponent("external/not active/Child", isDirectory: true)
        let siblingRepository = directory.appendingPathComponent("external/active/Sibling", isDirectory: true)
        try initializeRepository(at: childRepository)
        try initializeRepository(at: siblingRepository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)

        await coordinator.excludeFolder(sourceID: sourceID, path: "external/not active")
        XCTAssertEqual(coordinator.repositories.map(\.canonicalURL), [siblingRepository])

        await coordinator.excludeFolder(sourceID: sourceID, path: "external")

        XCTAssertTrue(coordinator.repositories.isEmpty)
        XCTAssertEqual(coordinator.state.watchRoots.first?.exclusions, ["external"])
    }

    func testRemovingMissingChildFromAppPreservesWatchRootAndSibling() async throws {
        let directory = try makeTestDirectory()
        let removed = directory.appendingPathComponent("Removed", isDirectory: true)
        let sibling = directory.appendingPathComponent("Sibling", isDirectory: true)
        try initializeRepository(at: removed)
        try initializeRepository(at: sibling)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)
        let removedID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == removed })?.id)

        try FileManager.default.removeItem(at: removed)
        await coordinator.restoreSources()
        XCTAssertEqual(coordinator.repositories.first(where: { $0.id == removedID })?.availability,
                       .unavailable(reason: "Repository is missing or access is unavailable."))

        await coordinator.excludeRepository(removedID)

        XCTAssertEqual(coordinator.state.watchRoots.map(\.id), [sourceID])
        XCTAssertEqual(coordinator.state.watchRoots[0].exclusions, ["Removed"])
        XCTAssertEqual(coordinator.repositories.map(\.canonicalURL), [sibling])
    }
}