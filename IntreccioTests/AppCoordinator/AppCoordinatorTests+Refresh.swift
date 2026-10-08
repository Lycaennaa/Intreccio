import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testEventsInsideExcludedFolderDoNotTriggerSourceRescan() async throws {
        let directory = try makeTestDirectory()
        let excludedRepository = directory.appendingPathComponent("external/not active/Repo", isDirectory: true)
        try initializeRepository(at: excludedRepository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        coordinator.start()
        try await waitUntil(description: "coordinator startup") { coordinator.hasLoadedState }
        await coordinator.addWatchRoot(directory)
        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)
        await coordinator.excludeFolder(sourceID: sourceID, path: "external/not active")

        var publishCount = 0
        let subscriptionID = coordinator.addSnapshotHandler { _ in publishCount += 1 }
        defer { coordinator.removeSnapshotHandler(subscriptionID) }
        await coordinator.routeSourceFileEvents(
            FileEventBatch(
                paths: [excludedRepository.appendingPathComponent("changed.txt").path],
                sourceRescanPaths: [excludedRepository.path],
                requiresFullRescan: true
            ),
            sourceID: sourceID
        )

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(publishCount, 0)
        let saved = await coordinator.shutdown()
        XCTAssertTrue(saved)
    }

    func testRestoreSourcesDoesNotRefreshUnchangedRepositories() async throws {
        let directory = try makeTestDirectory()
        let workspace = directory.appendingPathComponent("Workspace", isDirectory: true)
        let first = workspace.appendingPathComponent("First", isDirectory: true)
        let second = workspace.appendingPathComponent("Second", isDirectory: true)
        try initializeRepository(at: first)
        try initializeRepository(at: second)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(workspace)
        let firstID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == first })?.id)
        let secondID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == second })?.id)
        try await waitUntil(description: "initial repository refreshes") {
            coordinator.repositoryRefreshStates[firstID]?.phase == .idle
                && coordinator.repositoryRefreshStates[firstID]?.status != nil
                && coordinator.repositoryRefreshStates[secondID]?.phase == .idle
                && coordinator.repositoryRefreshStates[secondID]?.status != nil
        }
        let firstGeneration = try XCTUnwrap(coordinator.repositoryRefreshStates[firstID]?.statusGeneration)
        let secondGeneration = try XCTUnwrap(coordinator.repositoryRefreshStates[secondID]?.statusGeneration)

        await coordinator.restoreSources()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(coordinator.repositoryRefreshStates[firstID]?.statusGeneration, firstGeneration)
        XCTAssertEqual(coordinator.repositoryRefreshStates[secondID]?.statusGeneration, secondGeneration)
    }

    func testConcurrentAddsAreSerializedWithoutLostSources() async throws {
        let directory = try makeTestDirectory()
        let first = directory.appendingPathComponent("First", isDirectory: true)
        let second = directory.appendingPathComponent("Second", isDirectory: true)
        try initializeRepository(at: first)
        try initializeRepository(at: second)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)

        async let addFirst: Void = coordinator.addWatchRoot(first)
        async let addSecond: Void = coordinator.addWatchRoot(second)
        _ = await (addFirst, addSecond)

        XCTAssertEqual(coordinator.state.watchRoots.count, 2)
        XCTAssertEqual(coordinator.repositories.count, 2)
        let persisted = await StateStore(fileURL: stateFile).load()
        XCTAssertEqual(persisted.state.watchRoots.count, 2)
        XCTAssertEqual(persisted.state.repoSnapshots.count, 2)
    }

    func testAddedWatchRootRestoresInNewCoordinator() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let stateFile = directory.appendingPathComponent("state.json")
        let firstCoordinator = makeCoordinator(stateFile: stateFile)
        await firstCoordinator.addWatchRoot(directory)

        let restoredCoordinator = makeCoordinator(stateFile: stateFile)
        restoredCoordinator.start()
        try await waitUntil(description: "persisted watch root restoration") {
            restoredCoordinator.hasLoadedState && restoredCoordinator.repositories.count == 1
        }

        XCTAssertEqual(restoredCoordinator.state.watchRoots.first?.lastResolvedPath, directory.path)
        XCTAssertEqual(restoredCoordinator.repositories.first?.canonicalURL, repository)
    }

    func testRepeatedActivationRescanIsThrottledUntilStale() async throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        coordinator.start()
        try await waitUntil(description: "coordinator startup") {
            coordinator.hasLoadedState && coordinator.startupTask == nil
        }

        let generationBeforeManual = coordinator.catalog.fullRescanGeneration
        coordinator.rescanAll(refreshUpstream: false)
        XCTAssertEqual(coordinator.catalog.fullRescanGeneration, generationBeforeManual + 1)
        try await waitUntil(description: "manual full rescan") {
            coordinator.catalog.fullRescanTask == nil
        }

        let generationAfterManual = coordinator.catalog.fullRescanGeneration
        let now = ContinuousClock.now
        coordinator.rescanAllIfStale(at: now)
        coordinator.rescanAllIfStale(at: now)
        XCTAssertEqual(coordinator.catalog.fullRescanGeneration, generationAfterManual)

        coordinator.rescanAllIfStale(
            at: now.advanced(by: AppCoordinator.activationRescanStaleness)
        )
        XCTAssertEqual(coordinator.catalog.fullRescanGeneration, generationAfterManual + 1)
        let saved = await coordinator.shutdown()
        XCTAssertTrue(saved)
    }

    func testDroppedCoverageRootChangesAndManualRescansBypassActivationThrottle() async throws {
        let directory = try makeTestDirectory()
        try initializeRepository(at: directory.appendingPathComponent("Repo", isDirectory: true))
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        coordinator.start()
        try await waitUntil(description: "coordinator startup") {
            coordinator.hasLoadedState && coordinator.startupTask == nil
        }
        await coordinator.addWatchRoot(directory)
        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)

        coordinator.rescanAll(refreshUpstream: false)
        let generationAfterManual = coordinator.catalog.fullRescanGeneration
        try await waitUntil(description: "manual full rescan") {
            coordinator.catalog.fullRescanTask == nil
        }
        coordinator.rescanAllIfStale(at: ContinuousClock.now)
        XCTAssertEqual(coordinator.catalog.fullRescanGeneration, generationAfterManual)

        let sourceGenerationBeforeDrop = coordinator.catalog.sourceRefreshGenerations[sourceID] ?? 0
        await coordinator.routeSourceFileEvents(
            FileEventBatch(
                paths: [],
                sourceRescanPaths: [],
                requiresFullRescan: false,
                hasUnrepresentedChanges: true
            ),
            sourceID: sourceID
        )
        XCTAssertEqual(
            coordinator.catalog.sourceRefreshGenerations[sourceID],
            sourceGenerationBeforeDrop + 1
        )

        await coordinator.routeSourceFileEvents(
            FileEventBatch(
                paths: [directory.path],
                sourceRescanPaths: [],
                requiresFullRescan: true
            ),
            sourceID: sourceID
        )
        XCTAssertEqual(
            coordinator.catalog.sourceRefreshGenerations[sourceID],
            sourceGenerationBeforeDrop + 2
        )

        let fullGenerationBeforeManual = coordinator.catalog.fullRescanGeneration
        coordinator.rescanAll(refreshUpstream: false)
        XCTAssertEqual(
            coordinator.catalog.fullRescanGeneration,
            fullGenerationBeforeManual + 1
        )
        try await waitUntil(description: "manual full rescan after invalidation") {
            coordinator.catalog.fullRescanTask == nil
        }
        let saved = await coordinator.shutdown()
        XCTAssertTrue(saved)
    }

    func testActivationRescansWhenFileEventCoverageIsMissing() async throws {
        let directory = try makeTestDirectory()
        try initializeRepository(at: directory.appendingPathComponent("Repo", isDirectory: true))
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        coordinator.start()
        try await waitUntil(description: "coordinator startup") {
            coordinator.hasLoadedState && coordinator.startupTask == nil
        }
        await coordinator.addWatchRoot(directory)
        coordinator.rescanAll(refreshUpstream: false)
        try await waitUntil(description: "fresh full rescan") {
            coordinator.catalog.fullRescanTask == nil
        }

        await coordinator.runtime.finishShutdown()
        coordinator.runtime.resumeAfterFailedShutdown()
        XCTAssertTrue(coordinator.runtime.eventCoverageSnapshot.sourceWatcherIDs.isEmpty)

        let generationBeforeActivation = coordinator.catalog.fullRescanGeneration
        coordinator.rescanAllIfStale(at: ContinuousClock.now)
        XCTAssertEqual(
            coordinator.catalog.fullRescanGeneration,
            generationBeforeActivation + 1
        )
        let saved = await coordinator.shutdown()
        XCTAssertTrue(saved)
    }

}
