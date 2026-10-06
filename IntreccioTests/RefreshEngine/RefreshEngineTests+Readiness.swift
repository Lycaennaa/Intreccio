import Foundation
import XCTest
@testable import Intreccio

extension RefreshEngineTests {
    func testFileSystemEventMonitorPublishesReadinessTransitions() async throws {
        let directory = try makeTestDirectory()
        let transitions = MonitorReadinessProbe()
        let monitor = FileSystemEventMonitor(
            handler: { _ in },
            readinessHandler: { ready in
                Task { await transitions.record(ready) }
            }
        )
        monitor.updateCoverage([directory])
        try await waitUntil(description: "stream readiness") {
            await transitions.contains(true)
        }

        monitor.stop()
        try await waitUntil(description: "stream shutdown readiness") {
            await transitions.contains(false)
        }
        let recordedTransitions = await transitions.values()
        XCTAssertEqual(recordedTransitions, [true, false])
    }

    @MainActor
    func testCoveragePublishesCachedReadinessTransitions() async throws {
        let directory = try makeTestDirectory()
        let repositoryID = UUID()
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: directory,
            canonicalURL: directory,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let monitor = FileSystemEventMonitor(handler: { _ in })
        let controller = RepositoryFileEventCoverageController(monitorFactory: { monitor })
        let coverageChanges = MonitorReadinessProbe()
        let eventTask = Task { @MainActor in
            for await event in controller.events {
                if case .coverageChanged = event {
                    await coverageChanges.record(true)
                }
            }
        }
        defer {
            controller.finishShutdown()
            eventTask.cancel()
        }

        controller.update(context: RepositoryRuntimeContext(
            state: PersistedState(),
            repositories: [repository],
            isShuttingDown: false
        ))
        controller.updateEventCoverage()
        try await waitUntil(description: "cached repository readiness") {
            controller.snapshot.liveCoveredRepositoryIDs == [repositoryID]
        }
        try await waitUntil(description: "readiness publication") {
            await coverageChanges.values().count >= 1
        }

        monitor.stop()
        try await waitUntil(description: "cached repository readiness invalidation") {
            controller.snapshot.liveCoveredRepositoryIDs.isEmpty
        }
        try await waitUntil(description: "readiness invalidation publication") {
            await coverageChanges.values().count >= 2
        }
    }

    @MainActor
    func testCoverageReportsMissingLiveSourceAfterInjectedStreamFailure() async throws {
        let directory = try makeTestDirectory()
        let sourceID = UUID()
        var state = PersistedState()
        state.watchRoots = [WatchRoot(
            id: sourceID,
            displayName: "Workspace",
            bookmarkData: Data(),
            lastResolvedPath: directory.path,
            resourceID: nil,
            exclusions: []
        )]
        let failures = MonitorFailureProbe()
        let monitor = FileSystemEventMonitor(
            handler: { _ in },
            streamCreator: { _, _, _ in nil },
            retryDelay: 0.05,
            streamFailureHandler: { Task { await failures.recordFailure() } }
        )
        let controller = RepositoryFileEventCoverageController(monitorFactory: { monitor })
        defer { controller.finishShutdown() }
        controller.update(context: RepositoryRuntimeContext(
            state: state,
            repositories: [],
            isShuttingDown: false
        ))
        controller.updateEventCoverage()
        try await waitUntil(description: "injected source stream failure") {
            await failures.failureCount > 0
        }

        XCTAssertEqual(controller.snapshot.sourceWatcherIDs, [sourceID])
        XCTAssertTrue(controller.snapshot.liveSourceWatcherIDs.isEmpty)
    }
}
