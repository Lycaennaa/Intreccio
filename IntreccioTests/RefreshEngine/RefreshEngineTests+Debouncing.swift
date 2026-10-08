import Foundation
@testable import Intreccio
import XCTest

extension RefreshEngineTests {
    func testDebouncerCoalescesDuplicatesAndHonorsMaximumDelay() async throws {
        let recorder = FileBatchRecorder()
        let debouncer = FileEventDebouncer(delay: .milliseconds(60), maximumDelay: .milliseconds(120)) {
            await recorder.record($0)
        }
        let start = ContinuousClock.now

        await debouncer.submit([FileSystemEvent(path: "/repo/a", requiresFullRescan: false)])
        try await Task.sleep(for: .milliseconds(45))
        await debouncer.submit([
            FileSystemEvent(path: "/repo/a", requiresFullRescan: false),
            FileSystemEvent(path: "/repo/b", requiresFullRescan: true, requiresSourceRescan: true)
        ])
        try await Task.sleep(for: .milliseconds(45))
        await debouncer.submit([FileSystemEvent(path: "/repo/b", requiresFullRescan: false)])

        try await waitUntil { await recorder.count == 1 }
        let elapsed = start.duration(to: .now)
        let recordedBatch = await recorder.first
        let batch = try XCTUnwrap(recordedBatch)
        XCTAssertEqual(batch.paths, ["/repo/a", "/repo/b"])
        XCTAssertEqual(batch.sourceRescanPaths, ["/repo/b"])
        XCTAssertTrue(batch.requiresFullRescan)
        XCTAssertLessThan(elapsed, .milliseconds(220))
        await debouncer.stop()
    }

    func testDebouncerBoundsStructuralPaths() async throws {
        let recorder = FileBatchRecorder()
        let debouncer = FileEventDebouncer(delay: .milliseconds(10), maximumDelay: .milliseconds(20)) {
            await recorder.record($0)
        }
        let events = (0..<(FileEventDebouncer.maximumPaths + 100)).map {
            FileSystemEvent(path: "/repo/\($0)", requiresFullRescan: false, requiresSourceRescan: true)
        }

        await debouncer.submit(events)
        try await waitUntil { await recorder.count == 1 }
        let recordedBatch = await recorder.firstValue()
        let batch = try XCTUnwrap(recordedBatch)
        XCTAssertEqual(batch.paths.count, FileEventDebouncer.maximumPaths)
        XCTAssertEqual(batch.sourceRescanPaths.count, FileEventDebouncer.maximumPaths)
        XCTAssertTrue(batch.requiresFullRescan)
        XCTAssertTrue(batch.hasUnrepresentedChanges)
        await debouncer.stop()
    }

    func testDebouncerPreservesDroppedEventRecoveryFlags() async throws {
        let recorder = FileBatchRecorder()
        let debouncer = FileEventDebouncer(delay: .milliseconds(10), maximumDelay: .milliseconds(20)) {
            await recorder.record($0)
        }

        await debouncer.submit([
            FileSystemEvent(
                path: "/repo/dropped",
                requiresFullRescan: true,
                hasUnrepresentedChanges: true
            )
        ])
        try await waitUntil { await recorder.count == 1 }

        let recordedBatch = await recorder.firstValue()
        let batch = try XCTUnwrap(recordedBatch)
        XCTAssertEqual(batch.paths, ["/repo/dropped"])
        XCTAssertTrue(batch.requiresFullRescan)
        XCTAssertTrue(batch.hasUnrepresentedChanges)
        await debouncer.stop()
    }

    func testDebouncerStopCancelsPendingDelivery() async throws {
        let recorder = FileBatchRecorder()
        let debouncer = FileEventDebouncer(delay: .milliseconds(100), maximumDelay: .milliseconds(200)) {
            await recorder.record($0)
        }

        await debouncer.submit([FileSystemEvent(path: "/repo/pending", requiresFullRescan: false)])
        await debouncer.stop()
        try await Task.sleep(for: .milliseconds(150))

        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }
}
