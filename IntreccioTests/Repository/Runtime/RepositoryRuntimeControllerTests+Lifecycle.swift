import AppKit
import Foundation
@testable import Intreccio
import XCTest
private struct BoundedStreamTestEvent: Sendable, Equatable {
    let key: Int
    let version: Int
}

extension RepositoryRuntimeControllerTests {
    func testCancellationAndShutdownDrainRuntimeWorkAndResumeAfterFailure() async throws {
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
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        runtime.updateEventCoverage()
        runtime.enqueueStatusRefreshes(for: [repositoryID])

        await runtime.cancelAndDrain()

        XCTAssertTrue(runtime.isShuttingDown)
        XCTAssertFalse(runtime.statusRefreshSnapshot.hasPendingEnqueueTasks)
        XCTAssertFalse(runtime.githubResolutionSnapshot.hasLookupTask)

        runtime.resumeAfterFailedShutdown()
        runtime.updateEventCoverage()
        XCTAssertEqual(runtime.snapshot.activeRepositoryEventWatcherIDs, [repositoryID])

        await runtime.finishShutdown()
        XCTAssertTrue(runtime.snapshot.activeRepositoryEventWatcherIDs.isEmpty)
        XCTAssertTrue(runtime.eventCoverageSnapshot.sourceWatcherIDs.isEmpty)
        XCTAssertTrue(runtime.eventCoverageSnapshot.repositoryWatcherIDs.isEmpty)
        XCTAssertTrue(runtime.eventCoverageSnapshot.coveredRepositoryIDs.isEmpty)
    }

    func testAppSnapshotSubscriptionPublishesOneImmutableState() throws {
        let repositoryID = UUID()
        let url = URL(fileURLWithPath: "snapshot-test-repository", isDirectory: true)
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: url,
            canonicalURL: url,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        var received: [AppSnapshot] = []
        let subscriptionID = coordinator.addSnapshotHandler { received.append($0) }
        defer { coordinator.removeSnapshotHandler(subscriptionID) }

        coordinator.selectRepository(repositoryID)

        let snapshot = try XCTUnwrap(received.last)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(snapshot.repositories, [repository])
        XCTAssertEqual(snapshot.state.uiState.selectedRepoID, repositoryID)
        XCTAssertEqual(snapshot.selectedSession.diffState, .idle)
        XCTAssertEqual(coordinator.snapshot.repositories, [repository])
    }
    func testBoundedRepositoryEventStreamCoalescesStateAndBackpressuresLosslessEvents() async throws {
        let repositoryID = UUID()
        let sourceID = UUID()
        let stream = BoundedKeyedAsyncStream<
            RepositoryFileEventCoverageEvent,
            RepositoryFileEventCoverageEventKey
        >(
            maximumPendingElements: 2,
            key: { $0.coalescingKey }
        )
        let producer = Task {
            await stream.send(.refreshStatus(repositoryID))
            await stream.send(.invalidateGitHubURL(repositoryID))
            await stream.send(.refreshStatus(repositoryID))
            await stream.send(.rescanSource(sourceID, fromWatchRoot: true))
            await stream.send(.rescanSource(sourceID, fromWatchRoot: true))
            stream.finish()
        }

        try await waitUntil(description: "bounded repository event stream") {
            stream.pendingCount == 2 && stream.waitingProducerCount == 1
        }
        XCTAssertLessThanOrEqual(stream.pendingCount, 2)

        var iterator = stream.asyncStream.makeAsyncIterator()
        var received: [RepositoryFileEventCoverageEvent] = []
        for _ in 0..<4 {
            guard let event = await iterator.next() else {
                XCTFail("Bounded event stream terminated before lossless events were delivered")
                break
            }
            received.append(event)
            XCTAssertLessThanOrEqual(stream.pendingCount, 2)
            try await Task.sleep(for: .milliseconds(10))
        }
        await producer.value

        XCTAssertEqual(
            received,
            [
                .refreshStatus(repositoryID),
                .invalidateGitHubURL(repositoryID),
                .rescanSource(sourceID, fromWatchRoot: true),
                .rescanSource(sourceID, fromWatchRoot: true)
            ]
        )
        XCTAssertEqual(stream.pendingCount, 0)
        let terminal = await iterator.next()
        XCTAssertNil(terminal)
    }

    func testBoundedRepositoryEventStreamRetainsLatestValueAndRecoveryOrder() async throws {
        let stream = BoundedKeyedAsyncStream<BoundedStreamTestEvent, Int>(
            maximumPendingElements: 2,
            key: { $0.key }
        )
        await stream.send(BoundedStreamTestEvent(key: 1, version: 1))
        await stream.send(BoundedStreamTestEvent(key: 2, version: 1))
        let producer = Task {
            await stream.send(BoundedStreamTestEvent(key: 1, version: 2))
            await stream.send(BoundedStreamTestEvent(key: 3, version: 1))
            stream.finish()
        }

        try await waitUntil(description: "latest keyed event backpressure") {
            stream.pendingCount == 2 && stream.waitingProducerCount == 1
        }
        var iterator = stream.asyncStream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        await producer.value

        XCTAssertEqual(
            [first, second, third],
            [
                BoundedStreamTestEvent(key: 1, version: 2),
                BoundedStreamTestEvent(key: 2, version: 1),
                BoundedStreamTestEvent(key: 3, version: 1)
            ]
        )
        let terminal = await iterator.next()
        XCTAssertNil(terminal)
    }

    func testBoundedRepositoryEventStreamCancellationReleasesBackpressureWaiter() async throws {
        let stream = BoundedKeyedAsyncStream<
            RepositoryFileEventCoverageEvent,
            RepositoryFileEventCoverageEventKey
        >(
            maximumPendingElements: 1,
            key: { $0.coalescingKey }
        )
        await stream.send(.refreshStatus(UUID()))
        let blockedProducer = Task {
            await stream.send(.rescanSource(UUID(), fromWatchRoot: true))
        }

        try await waitUntil(description: "backpressure waiter") {
            stream.waitingProducerCount == 1
        }
        blockedProducer.cancel()
        await blockedProducer.value

        XCTAssertEqual(stream.waitingProducerCount, 0)
        stream.finish()
    }
    func testRuntimeSnapshotUsesTargetedImmutableRepositoryUpdates() async {
        let repositoryID = UUID()
        let repository = makeRuntimeRepository(id: repositoryID, path: "persistent-runtime-snapshot")
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate

        let before = runtime.snapshot
        runtime.handleRefreshEvent(.queued(RefreshKey(repositoryID: repositoryID, kind: .status), 1))
        let after = runtime.snapshot

        XCTAssertNil(before.refreshStates[repositoryID])
        XCTAssertEqual(after.refreshStates[repositoryID]?.phase, .queued)
        XCTAssertEqual(after.refreshStates.count, 1)
        await runtime.finishShutdown()
    }

    func testCoverageSnapshotCachesAggregateUntilCoverageChanges() {
        let repository = makeRuntimeRepository(path: "cached-coverage-snapshot")
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        runtime.updateEventCoverage()

        _ = runtime.eventCoverageSnapshot
        let initialBuildCount = runtime.coverageAggregateBuildCountForTesting
        _ = runtime.eventCoverageSnapshot
        XCTAssertEqual(runtime.coverageAggregateBuildCountForTesting, initialBuildCount)

        runtime.updateEventCoverage()
        _ = runtime.eventCoverageSnapshot
        XCTAssertEqual(runtime.coverageAggregateBuildCountForTesting, initialBuildCount + 1)
    }
}
