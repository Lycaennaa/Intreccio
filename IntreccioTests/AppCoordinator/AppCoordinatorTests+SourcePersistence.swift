import AppKit
import Foundation
import XCTest
@testable import Intreccio

extension AppCoordinatorTests {
    func testSourceMutationPersistenceFailureDoesNotAcceptCatalogChange() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        await coordinator.addStandaloneRepository(repository)

        XCTAssertTrue(coordinator.state.standaloneRepos.isEmpty)
        XCTAssertTrue(coordinator.repositories.isEmpty)
        XCTAssertNotNil(coordinator.errorMessage)
        let persisted = await StateStore(fileURL: stateFile).load()
        XCTAssertTrue(persisted.state.standaloneRepos.isEmpty)
        XCTAssertTrue(persisted.state.repoSnapshots.isEmpty)
    }

    func testRestoreAndRescanPersistenceFailureKeepAcceptedCatalogState() async throws {
        let directory = try makeTestDirectory()
        let workspace = directory.appendingPathComponent("Workspace", isDirectory: true)
        let first = workspace.appendingPathComponent("First", isDirectory: true)
        let second = workspace.appendingPathComponent("Second", isDirectory: true)
        let third = workspace.appendingPathComponent("Third", isDirectory: true)
        try initializeRepository(at: first)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        await coordinator.addWatchRoot(workspace)
        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)
        try initializeRepository(at: second)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        await coordinator.restoreSources()

        XCTAssertEqual(Set(coordinator.repositories.map(\.canonicalURL)), Set([first, second]))
        XCTAssertNotNil(coordinator.errorMessage)
        coordinator.clearError()
        try initializeRepository(at: third)
        coordinator.rescanSource(sourceID)
        try await waitUntil(description: "accepted source rescan before failed persistence") {
            coordinator.repositories.count == 3 && coordinator.errorMessage != nil
        }
        let persisted = await StateStore(fileURL: stateFile).load()
        XCTAssertEqual(persisted.state.repoSnapshots.count, 1)
    }
    func testAcceptedRestoreRunsRuntimeEffectsAfterPersistenceFailure() async throws {
        let directory = try makeTestDirectory()
        let workspace = directory.appendingPathComponent("Workspace", isDirectory: true)
        let first = workspace.appendingPathComponent("First", isDirectory: true)
        let second = workspace.appendingPathComponent("Second", isDirectory: true)
        try initializeRepository(at: first)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        await coordinator.addWatchRoot(workspace)
        try initializeRepository(at: second)

        try Data(#"{"schemaVersion":999}"#.utf8).write(to: stateFile, options: .atomic)
        _ = await coordinator.catalog.stateStore.load()
        var snapshots: [AppSnapshot] = []
        var acceptedBeforeEffects = false
        let subscriptionID = coordinator.addSnapshotHandler { snapshot in
            if let repository = snapshot.repositories.first(where: { $0.canonicalURL == second }),
               !snapshot.runtime.coveredRepositoryIDs.contains(repository.id) {
                acceptedBeforeEffects = true
            }
            snapshots.append(snapshot)
        }
        defer { coordinator.removeSnapshotHandler(subscriptionID) }

        await coordinator.restoreSources()

        let secondID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == second })?.id)
        XCTAssertNotNil(coordinator.stateSaveErrorMessage)
        XCTAssertTrue(coordinator.repositories.contains { $0.id == secondID })
        XCTAssertTrue(coordinator.runtime.snapshot.coveredRepositoryIDs.contains(secondID))
        XCTAssertTrue(acceptedBeforeEffects)
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.repositories.contains { $0.id == secondID }
                && snapshot.runtime.coveredRepositoryIDs.contains(secondID)
        })

        await coordinator.catalog.shutdown()
        await coordinator.runtime.cancelAndDrain()
        await coordinator.runtime.finishShutdown()
    }
}