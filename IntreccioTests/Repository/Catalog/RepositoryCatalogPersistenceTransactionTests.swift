@testable import Intreccio
import XCTest

@MainActor
final class RepositoryCatalogPersistenceTransactionTests: XCTestCase {
    func testReplacingInFlightRestoreCancelsThePreviousCommand() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let source = makeWatchRoots(count: 1)[0]
        let scanProbe = ScanProbe()
        let delegate = CatalogCommandDelegate()
        delegate.repositoryCatalogState = PersistedState(watchRoots: [source])
        let catalog = RepositoryCatalog(
            stateStore: StateStore(fileURL: stateFile),
            bookmarkStore: BookmarkStore(),
            scanner: RepoScanner(),
            gitService: GitService(),
            watchRootScanOperation: { source in
                await scanProbe.recordStart(source.id)
                await scanProbe.waitUntilReleased(source.id)
                await scanProbe.recordFinish(source.id)
                try Task.checkCancellation()
                return successfulResolution(source: source, index: 0)
            }
        )
        catalog.delegate = delegate

        let firstTask = Task {
            try await catalog.restoreSources()
        }
        await scanProbe.waitForStarted(count: 1)
        firstTask.cancel()

        let replacementTask = Task {
            try await catalog.restoreSources()
        }
        await scanProbe.releaseAll()

        do {
            try await firstTask.value
            XCTFail("Cancelled source operation unexpectedly completed")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected source operation error: \(error)")
        }

        await scanProbe.waitForStarted(count: 2)
        try await replacementTask.value

        XCTAssertEqual(delegate.reconcileCount, 1)
        XCTAssertEqual(catalog.sourceScans.count, 1)
    }

    func testRescanPersistenceFailurePropagatesDiagnosticMessage() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        try Data(#"{"schemaVersion":999}"#.utf8).write(to: stateFile)
        let store = StateStore(fileURL: stateFile)
        _ = await store.load()
        let source = makeWatchRoots(count: 1)[0]
        let delegate = CatalogCommandDelegate()
        delegate.repositoryCatalogState = PersistedState(watchRoots: [source])
        let catalog = RepositoryCatalog(
            stateStore: store,
            bookmarkStore: BookmarkStore(),
            scanner: RepoScanner(),
            gitService: GitService(),
            watchRootScanOperation: { source in
                try Task.checkCancellation()
                return successfulResolution(source: source, index: 0)
            }
        )
        catalog.delegate = delegate

        catalog.rescanAll(refreshUpstream: false)

        try await waitUntil(description: "rescan persistence failure") {
            delegate.failures.count == 1
        }
        if case .sourcesPersistence(let message) = delegate.failures[0] {
            XCTAssertEqual(
                message,
                "State writes are blocked to preserve existing data: Unsupported state schema version: 999"
            )
        } else {
            XCTFail("Expected full rescan persistence failure")
        }
        XCTAssertEqual(delegate.reconcileCount, 1)
        await catalog.shutdown()
    }
}
