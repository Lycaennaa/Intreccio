import Foundation
@testable import Intreccio
import XCTest

extension RefreshEngineTests {
    func testSchedulerRunsTwoAndStartsSelectedRepositoryNext() async throws {
        let probe = RefreshOperationProbe()
        let selectedID = UUID()
        let scheduler = RefreshScheduler(
            operation: { request in try await probe.run(request.url.lastPathComponent) },
            eventHandler: { _ in }
        )
        let firstID = UUID()
        let secondID = UUID()
        let normalID = UUID()
        await scheduler.setSelectedRepository(selectedID)

        await scheduler.enqueue(repositoryID: firstID, url: URL(fileURLWithPath: "/first"))
        await scheduler.enqueue(repositoryID: secondID, url: URL(fileURLWithPath: "/second"))
        await scheduler.enqueue(repositoryID: normalID, url: URL(fileURLWithPath: "/normal"))
        await scheduler.enqueue(repositoryID: selectedID, url: URL(fileURLWithPath: "/selected"))

        try await waitUntil { await probe.started.count == 2 }
        let initiallyStarted = await probe.started
        let maximumActive = await probe.maximumActive
        XCTAssertEqual(Set(initiallyStarted), ["first", "second"])
        XCTAssertEqual(maximumActive, 2)

        await probe.complete("first")
        try await waitUntil { await probe.started.contains("selected") }
        let startedAfterRelease = await probe.started
        XCTAssertFalse(startedAfterRelease.contains("normal"))

        await scheduler.stop()
        let activeAfterStop = await probe.activeValue()
        XCTAssertEqual(activeAfterStop, 0)
    }

    func testGitLimiterPrioritizesSelectedWaiter() async throws {
        let limiter = GitProcessLimiter(maximumConcurrent: 2)
        let recorder = StringRecorder()
        let gate = AsyncTestGate()
        try await limiter.acquire(priority: .normal)
        try await limiter.acquire(priority: .normal)

        let normal = Task {
            try await limiter.acquire(priority: .normal)
            await recorder.record("normal")
            await gate.wait("normal")
            await limiter.release()
        }
        let selected = Task {
            try await limiter.acquire(priority: .selectedRepository)
            await recorder.record("selected")
            await gate.wait("selected")
            await limiter.release()
        }
        try await Task.sleep(for: .milliseconds(30))
        await limiter.release()
        try await waitUntil { await recorder.values.count == 1 }
        let acquired = await recorder.values
        XCTAssertEqual(acquired, ["selected"])
        await gate.open("selected")
        try await waitUntil { await recorder.values.count == 2 }
        await gate.open("normal")
        await limiter.release()
        _ = try await (normal.value, selected.value)
    }

    func testSchedulerRejectsEnqueuesOnceStopBegins() async throws {
        let probe = ShutdownOperationProbe()
        let scheduler = RefreshScheduler(
            operation: { request in try await probe.run(request.url.lastPathComponent) },
            eventHandler: { _ in }
        )
        await scheduler.enqueue(repositoryID: UUID(), url: URL(fileURLWithPath: "/first"))
        try await waitUntil { await probe.started.count == 1 }

        let stop = Task { await scheduler.stop() }
        try await Task.sleep(for: .milliseconds(20))
        await scheduler.enqueue(repositoryID: UUID(), url: URL(fileURLWithPath: "/late"))
        await probe.complete()
        await stop.value

        let started = await probe.startedValues()
        XCTAssertEqual(started, ["first"])
    }

    func testSchedulerForwardsUpstreamRefreshIntent() async throws {
        let recorder = StringRecorder()
        let scheduler = RefreshScheduler(
            operation: { request in
                await recorder.record(request.refreshUpstream ? "remote" : "local")
                return RepoStatus()
            },
            eventHandler: { _ in }
        )

        await scheduler.enqueue(
            repositoryID: UUID(),
            url: URL(fileURLWithPath: "/repo"),
            refreshUpstream: true
        )

        try await waitUntil { await scheduler.metrics().completedCount == 1 }
        let values = await recorder.values
        XCTAssertEqual(values, ["remote"])
        await scheduler.stop()
    }

    func testRunningUpstreamRefreshFinishesBeforeLocalReplacement() async throws {
        let probe = RefreshOperationProbe()
        let recorder = StringRecorder()
        let repositoryID = UUID()
        let scheduler = RefreshScheduler(
            operation: { request in
                await recorder.record("\(request.url.lastPathComponent):\(request.refreshUpstream ? "remote" : "local")")
                return try await probe.run(request.url.lastPathComponent)
            },
            eventHandler: { _ in }
        )
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/first"),
            refreshUpstream: true
        )
        await scheduler.enqueue(repositoryID: UUID(), url: URL(fileURLWithPath: "/blocker"))
        try await waitUntil { await probe.started.count == 2 }

        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/replacement"),
            refreshUpstream: false
        )

        try await Task.sleep(for: .milliseconds(30))
        let startedBeforeCompletion = await probe.started
        XCTAssertFalse(startedBeforeCompletion.contains("replacement"))
        await probe.complete("first")
        try await waitUntil { await probe.started.contains("replacement") }
        let values = await recorder.values
        XCTAssertTrue(values.contains("replacement:local"))
        await scheduler.stop()
    }

    func testPendingLocalReplacementPreservesUpstreamRefreshIntent() async throws {
        let probe = RefreshOperationProbe()
        let recorder = StringRecorder()
        let repositoryID = UUID()
        let scheduler = RefreshScheduler(
            operation: { request in
                await recorder.record("\(request.url.lastPathComponent):\(request.refreshUpstream ? "remote" : "local")")
                return try await probe.run(request.url.lastPathComponent)
            },
            eventHandler: { _ in }
        )
        await scheduler.enqueue(repositoryID: UUID(), url: URL(fileURLWithPath: "/blocker-one"))
        await scheduler.enqueue(repositoryID: UUID(), url: URL(fileURLWithPath: "/blocker-two"))
        try await waitUntil { await probe.started.count == 2 }
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/pending-first"),
            refreshUpstream: true
        )
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/pending-replacement"),
            refreshUpstream: false
        )

        await probe.complete("blocker-one")
        try await waitUntil { await probe.started.contains("pending-replacement") }
        let values = await recorder.values
        XCTAssertTrue(values.contains("pending-replacement:remote"))
        await scheduler.stop()
    }

}
