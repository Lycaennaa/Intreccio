import Foundation
import XCTest
@testable import Intreccio

extension RefreshEngineTests {
    func testFiftyRepositoryRefreshIsMeasuredAndNeverExceedsTwoOperations() async throws {
        let probe = ConcurrentRefreshProbe()
        let scheduler = RefreshScheduler(
            operation: { _ in try await probe.run() },
            eventHandler: { _ in }
        )

        for index in 0..<50 {
            await scheduler.enqueue(
                repositoryID: UUID(),
                url: URL(fileURLWithPath: "/repo-\(index)")
            )
        }

        try await waitUntil(timeout: .seconds(5)) { await scheduler.metrics().completedCount == 50 }
        let metrics = await scheduler.metrics()
        let maximumActive = await probe.maximumActive
        XCTAssertEqual(metrics.startedCount, 50)
        XCTAssertEqual(metrics.completedCount, 50)
        XCTAssertEqual(metrics.failedCount, 0)
        XCTAssertEqual(metrics.maximumConcurrentObserved, 2)
        XCTAssertEqual(maximumActive, 2)
        XCTAssertLessThanOrEqual(metrics.maximumPendingObserved, 48)
        XCTAssertGreaterThanOrEqual(metrics.totalRunTime, .zero)
        await scheduler.stop()
    }
}