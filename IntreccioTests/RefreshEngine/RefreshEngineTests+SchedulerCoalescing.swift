import Foundation
import XCTest
@testable import Intreccio

extension RefreshEngineTests {
    func testUpstreamFailureSurvivesLocalReplacementStatusRefresh() async throws {
        let gate = AsyncTestGate()
        let operations = StringRecorder()
        let events = StringRecorder()
        let repositoryID = UUID()
        let scheduler = RefreshScheduler(
            operation: { request in
                await operations.record(request.url.lastPathComponent)
                if request.refreshUpstream {
                    await gate.wait("remote")
                    throw RefreshProbeError.failed
                }
                return RepoStatus()
            },
            eventHandler: { event in
                if case .completedWithFailure = event { await events.record("completedWithFailure") }
            }
        )
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/remote"),
            refreshUpstream: true
        )
        try await waitUntil { await operations.values == ["remote"] }
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/local"),
            refreshUpstream: false
        )

        await gate.open("remote")

        try await waitUntil { await events.values == ["completedWithFailure"] }
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/local-two"),
            refreshUpstream: false
        )
        try await waitUntil {
            await events.values == ["completedWithFailure", "completedWithFailure"]
        }
        let started = await operations.values
        XCTAssertEqual(started, ["remote", "local", "local-two"])
        await scheduler.stop()
    }

    func testCancellationDuringQueuedEventPreventsOperationStart() async throws {
        let repositoryID = UUID()
        let eventGate = AsyncTestGate()
        let events = StringRecorder()
        let operations = StringRecorder()
        let scheduler = RefreshScheduler(
            operation: { request in
                await operations.record(request.url.lastPathComponent)
                return RepoStatus()
            },
            eventHandler: { event in
                if case .queued = event {
                    await events.record("queued")
                    await eventGate.wait("queued")
                }
            }
        )
        let enqueue = Task {
            await scheduler.enqueue(repositoryID: repositoryID, url: URL(fileURLWithPath: "/stale"))
        }
        try await waitUntil { await events.values == ["queued"] }

        await scheduler.cancel(repositoryID: repositoryID)
        await eventGate.open("queued")
        await enqueue.value

        let startedOperations = await operations.values
        XCTAssertEqual(startedOperations, [])
        await scheduler.stop()
    }

    func testSameRepositoryLocalBurstsCoalesceBehindActiveOperation() async throws {
        let probe = RefreshOperationProbe()
        let repositoryID = UUID()
        let scheduler = RefreshScheduler(
            maximumConcurrent: 1,
            operation: { request in try await probe.run(request.url.lastPathComponent) },
            eventHandler: { _ in }
        )

        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/initial")
        )
        try await waitUntil { await probe.started.count == 1 }

        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/second")
        )
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/third")
        )
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/latest")
        )

        try await Task.sleep(for: .milliseconds(30))
        let startedBeforeCompletion = await probe.started
        XCTAssertEqual(startedBeforeCompletion, ["initial"])
        let cancelledBeforeCompletion = await probe.cancelled
        XCTAssertTrue(cancelledBeforeCompletion.isEmpty)

        await probe.complete("initial")
        try await waitUntil { await probe.started.contains("latest") }
        let startedAfterCompletion = await probe.started
        XCTAssertEqual(startedAfterCompletion, ["initial", "latest"])

        await probe.complete("latest")
        try await waitUntil { await scheduler.metrics().completedCount == 1 }
        let metrics = await scheduler.metrics()
        XCTAssertEqual(metrics.startedCount, 2)
        XCTAssertEqual(metrics.completedCount, 1)
        await scheduler.stop()
    }

    func testSchedulerCoalescesQueuedNotificationsForSustainedLocalBurst() async throws {
        let probe = RefreshOperationProbe()
        let queuedEvents = StringRecorder()
        let terminalEvents = StringRecorder()
        let repositoryID = UUID()
        let scheduler = RefreshScheduler(
            maximumConcurrent: 1,
            operation: { request in
                try await probe.run(request.url.lastPathComponent)
            },
            eventHandler: { event in
                switch event {
                case .queued(let key, _) where key.repositoryID == repositoryID:
                    await queuedEvents.record("queued")
                case .completed(let key, _, _) where key.repositoryID == repositoryID:
                    await terminalEvents.record("completed")
                default:
                    break
                }
            }
        )

        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/initial")
        )
        try await waitUntil { await probe.started.count == 1 }

        for index in 0..<256 {
            await scheduler.enqueue(
                repositoryID: repositoryID,
                url: URL(fileURLWithPath: "/replacement-\(index)")
            )
        }

        let queued = await queuedEvents.values
        XCTAssertEqual(queued.count, 2)

        await probe.complete("initial")
        try await waitUntil { await probe.started.contains("replacement-255") }
        await probe.complete("replacement-255")
        try await waitUntil { await scheduler.metrics().completedCount == 1 }

        let terminals = await terminalEvents.values
        XCTAssertEqual(terminals, ["completed"])
        await scheduler.stop()
    }

    func testSchedulerDeliversFailureAfterCoalescedLocalBurst() async throws {
        let probe = RefreshOperationProbe()
        let failureEvents = StringRecorder()
        let repositoryID = UUID()
        let scheduler = RefreshScheduler(
            maximumConcurrent: 1,
            operation: { request in
                if request.url.lastPathComponent == "latest" { throw RefreshProbeError.failed }
                return try await probe.run(request.url.lastPathComponent)
            },
            eventHandler: { event in
                if case .failed(let key, _, _) = event, key.repositoryID == repositoryID {
                    await failureEvents.record("failed")
                }
            }
        )

        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/initial")
        )
        try await waitUntil { await probe.started.count == 1 }
        for name in ["old", "latest"] {
            await scheduler.enqueue(
                repositoryID: repositoryID,
                url: URL(fileURLWithPath: "/\(name)")
            )
        }

        await probe.complete("initial")
        try await waitUntil { await scheduler.metrics().failedCount == 1 }

        let failures = await failureEvents.values
        XCTAssertEqual(failures, ["failed"])
        await scheduler.stop()
    }
}