import Foundation
import XCTest
@testable import Intreccio

extension RefreshEngineTests {
    func testRepositorySwitchCancellationDropsCoalescedReplacement() async throws {
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
            url: URL(fileURLWithPath: "/replacement")
        )

        await scheduler.cancel(repositoryID: repositoryID)
        try await waitUntil { await probe.activeValue() == 0 }
        let started = await probe.started
        XCTAssertEqual(started, ["initial"])
        await scheduler.stop()
    }

    func testExplicitAndDestructiveRequestsStillCancelActiveOperation() async throws {
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
            url: URL(fileURLWithPath: "/explicit"),
            requestKind: .explicit
        )

        try await waitUntil { await probe.started.contains("explicit") }
        let cancelledAfterExplicit = await probe.cancelled
        XCTAssertTrue(cancelledAfterExplicit.contains("initial"))
        await probe.complete("explicit")

        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/before-destructive")
        )
        try await waitUntil { await probe.started.contains("before-destructive") }
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/destructive"),
            requestKind: .destructiveOperation
        )

        try await waitUntil { await probe.started.contains("destructive") }
        let cancelledAfterDestructive = await probe.cancelled
        XCTAssertTrue(cancelledAfterDestructive.contains("before-destructive"))
        await probe.complete("destructive")
        await scheduler.stop()
    }

    func testShutdownCancelsActiveOperationAndDropsCoalescedReplacement() async throws {
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
            url: URL(fileURLWithPath: "/replacement")
        )

        await scheduler.stop()
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: URL(fileURLWithPath: "/late")
        )
        try await Task.sleep(for: .milliseconds(30))
        let started = await probe.started
        XCTAssertEqual(started, ["initial"])
        let active = await probe.activeValue()
        XCTAssertEqual(active, 0)
    }

    func testRunningDuplicateKeepsReplacementWhenPendingQueueIsFull() async throws {
        let probe = RefreshOperationProbe()
        let firstID = UUID()
        let scheduler = RefreshScheduler(
            operation: { request in try await probe.run(request.url.lastPathComponent) },
            eventHandler: { _ in }
        )
        await scheduler.enqueue(repositoryID: firstID, url: URL(fileURLWithPath: "/first"))
        await scheduler.enqueue(repositoryID: UUID(), url: URL(fileURLWithPath: "/second"))
        try await waitUntil { await probe.started.count == 2 }
        for index in 0..<RefreshScheduler.maximumPending {
            await scheduler.enqueue(repositoryID: UUID(), url: URL(fileURLWithPath: "/pending-\(index)"))
        }

        await scheduler.enqueue(
            repositoryID: firstID,
            url: URL(fileURLWithPath: "/first-new"),
            requestKind: .explicit
        )

        try await waitUntil { await probe.started.contains("first-new") }
        await scheduler.stop()
        let activeAfterStop = await probe.activeValue()
        XCTAssertEqual(activeAfterStop, 0)
    }

    func testSelectedPendingRequestPrecedesRunningReplacement() async throws {
        let probe = RefreshOperationProbe()
        let firstID = UUID()
        let selectedID = UUID()
        let scheduler = RefreshScheduler(
            operation: { request in try await probe.run(request.url.lastPathComponent) },
            eventHandler: { _ in }
        )
        await scheduler.setSelectedRepository(selectedID)
        await scheduler.enqueue(repositoryID: firstID, url: URL(fileURLWithPath: "/first"))
        await scheduler.enqueue(repositoryID: UUID(), url: URL(fileURLWithPath: "/second"))
        await scheduler.enqueue(repositoryID: selectedID, url: URL(fileURLWithPath: "/selected"))
        try await waitUntil { await probe.started.count == 2 }

        await scheduler.enqueue(
            repositoryID: firstID,
            url: URL(fileURLWithPath: "/first-new"),
            requestKind: .explicit
        )

        try await waitUntil { await probe.started.contains("selected") }
        let started = await probe.started
        XCTAssertFalse(started.contains("first-new"))
        await scheduler.stop()
    }
}