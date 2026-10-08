import Foundation
@testable import Intreccio
import XCTest

extension RefreshEngineTests {
    func testFileSystemEventMonitorRetriesInjectedStreamCreationFailure() async throws {
        let failures = MonitorFailureProbe()
        let monitor = FileSystemEventMonitor(
            handler: { _ in },
            streamCreator: { _, _, _ in nil },
            retryDelay: 0.05,
            streamFailureHandler: { Task { await failures.recordFailure() } }
        )
        monitor.updateCoverage([URL(fileURLWithPath: "/work/source", isDirectory: true)])
        try await waitUntil(description: "stream creation retries") {
            await failures.failureCount >= 2
        }
        XCTAssertFalse(monitor.isReady)
        monitor.stop()
    }

    func testFileSystemEventMonitorReportsInjectedStreamStartFailure() async throws {
        let directory = try makeTestDirectory()
        let failures = MonitorFailureProbe()
        let starts = LockedCounter()
        let monitor = FileSystemEventMonitor(
            handler: { _ in },
            streamStarter: { _ in
                starts.increment()
                return false
            },
            retryDelay: 0.05,
            streamFailureHandler: { Task { await failures.recordFailure() } }
        )
        monitor.updateCoverage([directory])
        try await waitUntil(description: "stream start retries") {
            await failures.failureCount >= 2
        }
        XCTAssertGreaterThan(starts.value, 0)
        XCTAssertFalse(monitor.isReady)
        monitor.stop()
    }
}
