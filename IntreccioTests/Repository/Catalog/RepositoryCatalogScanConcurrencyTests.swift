@testable import Intreccio
import XCTest

@MainActor
final class RepositoryCatalogScanConcurrencyTests: XCTestCase {
    func testWatchRootScansAreBoundedToScannerCapacity() async throws {
        let roots = makeWatchRoots(count: 4)
        let indices = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($1.id, $0) })
        let probe = ScanProbe()
        let (operations, _) = makeOperations { source in
            guard let index = indices[source.id] else {
                throw ScanTestError(message: "unknown source")
            }
            await probe.recordStart(source.id)
            await probe.waitUntilReleased(source.id)
            await probe.recordFinish(source.id)
            return successfulResolution(source: source, index: index)
        }

        let task = Task {
            try await operations.prepareRestoreSources(
                state: PersistedState(watchRoots: roots),
                generation: nil,
                refreshUpstream: false
            )
        }

        await probe.waitForStarted(count: 2)
        let initialStats = await probe.stats()
        XCTAssertEqual(initialStats.maximumActive, 2)
        XCTAssertEqual(initialStats.startedCount, 2)

        await probe.releaseAll()
        let transaction = try await task.value
        let finalStats = await probe.stats()
        XCTAssertEqual(finalStats.maximumActive, 2)
        XCTAssertEqual(finalStats.startedCount, roots.count)
        XCTAssertEqual(transaction.change.state.watchRoots.map(\.id), roots.map(\.id))
    }
    func testColdRestoreResolvesLinkedSnapshotMetadataAfterIncompleteScan() async throws {
        let directory = try makeTestDirectory()
        let mainURL = directory.appendingPathComponent("main", isDirectory: true)
        let linkedURL = directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: mainURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkedURL, withIntermediateDirectories: true)
        let commonGitDirectoryURL = mainURL.appendingPathComponent(".git", isDirectory: true)
        let linkedGitDirectoryURL = commonGitDirectoryURL
            .appendingPathComponent("worktrees/linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkedGitDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("../..\n".utf8).write(to: linkedGitDirectoryURL.appendingPathComponent("commondir"))
        try Data("gitdir: \(linkedGitDirectoryURL.path)\n".utf8)
            .write(to: linkedURL.appendingPathComponent(".git"))

        let sourceID = UUID()
        let mainID = UUID()
        let linkedID = UUID()
        let source = WatchRoot(
            id: sourceID,
            displayName: directory.lastPathComponent,
            bookmarkData: Data(),
            lastResolvedPath: directory.path,
            resourceID: nil,
            exclusions: []
        )
        let snapshots = [
            RepositorySnapshot(
                id: mainID,
                sourceID: sourceID,
                relativePath: "main",
                canonicalPath: mainURL.path,
                resourceID: nil,
                availability: .available
            ),
            RepositorySnapshot(
                id: linkedID,
                sourceID: sourceID,
                relativePath: "linked",
                canonicalPath: linkedURL.path,
                resourceID: nil,
                availability: .available
            )
        ]
        let incompleteScan = RepoScanResult(
            repositories: [],
            warnings: [],
            incompleteReason: "Scan stopped at repository limit.",
            visitedDirectoryCount: 50,
            duration: .zero
        )
        let (operations, _) = makeOperations { source in
            .success(source: source, result: incompleteScan)
        }

        let transaction = try await operations.prepareRestoreSources(
            state: PersistedState(watchRoots: [source], repoSnapshots: snapshots),
            generation: nil,
            refreshUpstream: false
        )

        let linked = try XCTUnwrap(transaction.change.repositories.first { $0.id == linkedID })
        XCTAssertEqual(transaction.change.repositories.count, 2)
        XCTAssertEqual(linked.availability, .available)
        XCTAssertTrue(linked.isLinkedWorktree)
        XCTAssertEqual(linked.mainRepositoryURL, mainURL)
    }

    func testNearBudgetRestoreStopsAfterCandidateBudget() async {
        let roots = makeWatchRoots(count: PersistedCatalogBudget.maxEntryCount - 1)
        let probe = ScanProbe()
        let (operations, catalogState) = makeOperations { source in
            await probe.recordStart(source.id)
            await probe.recordFinish(source.id)
            let repositories = (0..<64).map { index in
                let url = URL(
                    fileURLWithPath: "/candidate-\(source.id.uuidString)-\(index)",
                    isDirectory: true
                )
                return ScannedRepository(
                    url: url,
                    canonicalURL: url,
                    relativePath: "candidate-\(index)",
                    resourceID: "candidate-\(source.id.uuidString)-\(index)"
                )
            }
            return .success(source: source, result: RepoScanResult(
                repositories: repositories,
                warnings: [],
                incompleteReason: nil,
                visitedDirectoryCount: 1,
                duration: .zero
            ))
        }

        do {
            _ = try await operations.prepareRestoreSources(
                state: PersistedState(watchRoots: roots),
                generation: nil,
                refreshUpstream: false
            )
            XCTFail("Near-budget restore unexpectedly returned a transaction")
        } catch let error as RepositoryCatalogScanError {
            XCTAssertEqual(error, .candidateBudgetExceeded(limit: 1))
        } catch {
            XCTFail("Unexpected near-budget restore error: \(error)")
        }

        let stats = await probe.stats()
        XCTAssertLessThanOrEqual(stats.maximumActive, RepoScanner.maximumConcurrentScans)
        XCTAssertLessThanOrEqual(stats.startedCount, RepoScanner.maximumConcurrentScans)
        XCTAssertLessThan(stats.startedCount, roots.count)
        XCTAssertTrue(catalogState.sourceScans.isEmpty)
        XCTAssertTrue(catalogState.repositories.isEmpty)
    }

    func testStandaloneResolutionsAreBoundedAndPreserveSourceOrder() async throws {
        let directory = try makeTestDirectory()
        let bookmarkStore = BookmarkStore()
        var sources: [StandaloneRepository] = []
        var roots: [URL] = []
        for index in 0..<4 {
            let root = directory.appendingPathComponent("standalone-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bookmark = try await bookmarkStore.create(for: root)
            roots.append(root)
            sources.append(StandaloneRepository(
                id: UUID(),
                displayName: "source-\(index)",
                bookmarkData: bookmark,
                lastResolvedPath: root.path,
                resourceID: nil
            ))
        }

        let probe = StandaloneGitProbe(failingPaths: [roots[2].path])
        let gitService = GitService(runner: probe)
        let (operations, _) = makeOperations(
            watchRootScan: { _ in throw ScanTestError(message: "unexpected watch root scan") },
            bookmarkStore: bookmarkStore,
            gitService: gitService
        )
        let task = Task {
            try await operations.prepareRestoreSources(
                state: PersistedState(standaloneRepos: sources),
                generation: nil,
                refreshUpstream: false
            )
        }

        await probe.waitForStarted(paths: Set(roots.prefix(2).map(\.path)))
        let initialStats = await probe.stats()
        XCTAssertEqual(initialStats.maximumActive, 2)
        XCTAssertEqual(initialStats.startedCount, 2)

        await probe.release(roots[1].path)
        await probe.waitForStarted(paths: Set([roots[2].path]))
        await probe.release(roots[2].path)
        await probe.waitForStarted(paths: Set([roots[3].path]))
        await probe.release(roots[3].path)
        await probe.release(roots[0].path)

        let transaction = try await task.value
        let change = transaction.change
        XCTAssertEqual(change.state.standaloneRepos.map(\.id), sources.map(\.id))
        XCTAssertEqual(change.state.standaloneRepos.map(\.lastResolvedPath), roots.map(\.path))
        XCTAssertEqual(change.standaloneRepositories[sources[0].id]?.url, roots[0])
        XCTAssertEqual(change.standaloneRepositories[sources[1].id]?.url, roots[1])
        XCTAssertNil(change.standaloneRepositories[sources[2].id])
        XCTAssertEqual(change.standaloneRepositories[sources[3].id]?.url, roots[3])
        XCTAssertEqual(
            change.scanMessages[sources[2].id],
            "Repository unavailable: Process exited with status 128: root failed"
        )
        XCTAssertEqual(
            change.repositories.map(\.canonicalURL.path),
            [roots[0], roots[1], roots[3]].map(\.path)
        )
        XCTAssertEqual(
            transaction.persistenceOrder,
            .afterAcceptance(clearPersistenceErrorOnSuccess: true)
        )
        let finalStats = await probe.stats()
        XCTAssertEqual(finalStats.maximumActive, 2)
        XCTAssertEqual(finalStats.startedCount, roots.count)
    }

    func testWatchRootResultsApplyInSourceOrderAfterOutOfOrderCompletion() async throws {
        let roots = makeWatchRoots(count: 3)
        let indices = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($1.id, $0) })
        let probe = ScanProbe()
        let (operations, _) = makeOperations { source in
            guard let index = indices[source.id] else {
                throw ScanTestError(message: "unknown source")
            }
            await probe.recordStart(source.id)
            await probe.waitUntilReleased(source.id)
            await probe.recordFinish(source.id)
            return successfulResolution(source: source, index: index)
        }

        let task = Task {
            try await operations.prepareRestoreSources(
                state: PersistedState(watchRoots: roots),
                generation: nil,
                refreshUpstream: false
            )
        }

        await probe.waitForStarted(count: 2)
        await probe.release(roots[1].id)
        await probe.waitForCompleted(roots[1].id)
        await probe.waitForStarted(count: 3)
        await probe.releaseAll()

        let change = try await task.value.change
        XCTAssertEqual(
            change.state.watchRoots.map(\.displayName),
            ["resolved-0", "resolved-1", "resolved-2"]
        )
        let pathsBySource = Dictionary(uniqueKeysWithValues: change.repositories.map {
            ($0.source.id, $0.canonicalURL.path)
        })
        for (index, source) in roots.enumerated() {
            XCTAssertEqual(pathsBySource[source.id], "/repository-\(index)")
        }
        XCTAssertEqual(
            change.state.repoSnapshots.map(\.sourceID).sorted { $0.uuidString < $1.uuidString },
            roots.map(\.id).filter { pathsBySource[$0] != nil }.sorted { $0.uuidString < $1.uuidString }
        )
    }

    func testWatchRootFailuresRemainPerSourceAndSuccessfulResultsAreAccepted() async throws {
        let roots = makeWatchRoots(count: 3)
        let indices = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($1.id, $0) })
        let (operations, _) = makeOperations { source in
            guard let index = indices[source.id] else {
                throw ScanTestError(message: "unknown source")
            }
            switch index {
            case 0:
                throw ScanTestError(message: "access failure")
            case 1:
                return failedResolution(source: source, message: "scan failure")
            default:
                return successfulResolution(source: source, index: index)
            }
        }

        let transaction = try await operations.prepareRestoreSources(
            state: PersistedState(watchRoots: roots),
            generation: nil,
            refreshUpstream: false
        )
        let change = transaction.change

        XCTAssertEqual(change.scanMessages[roots[0].id], "Access unavailable: access failure")
        XCTAssertEqual(change.scanMessages[roots[1].id], "Scan failed: scan failure")
        XCTAssertNil(change.scanMessages[roots[2].id])
        XCTAssertNil(change.sourceScans[roots[0].id])
        XCTAssertNil(change.sourceScans[roots[1].id])
        XCTAssertEqual(change.sourceScans[roots[2].id]?.repositories.map(\.canonicalURL.path), ["/repository-2"])
        XCTAssertEqual(change.repositories.map(\.canonicalURL.path), ["/repository-2"])
        XCTAssertEqual(change.state.watchRoots[0].displayName, roots[0].displayName)
        XCTAssertEqual(change.state.watchRoots[1].displayName, "resolved-1")
        XCTAssertEqual(transaction.persistenceOrder, .afterAcceptance(clearPersistenceErrorOnSuccess: true))
    }

    func testCancellationDoesNotAcceptWatchRootResults() async {
        let roots = makeWatchRoots(count: 4)
        let indices = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($1.id, $0) })
        let probe = ScanProbe()
        let (operations, catalogState) = makeOperations { source in
            guard let index = indices[source.id] else {
                throw ScanTestError(message: "unknown source")
            }
            await probe.recordStart(source.id)
            await probe.waitUntilReleased(source.id)
            await probe.recordFinish(source.id)
            return successfulResolution(source: source, index: index)
        }

        let task = Task {
            try await operations.prepareRestoreSources(
                state: PersistedState(watchRoots: roots),
                generation: nil,
                refreshUpstream: false
            )
        }

        await probe.waitForStarted(count: 2)
        task.cancel()
        await probe.releaseAll()

        do {
            _ = try await task.value
            XCTFail("Cancelled restore unexpectedly returned a transaction")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertTrue(catalogState.sourceScans.isEmpty)
        XCTAssertTrue(catalogState.repositories.isEmpty)
    }

    func testStaleGenerationDoesNotAcceptWatchRootResults() async {
        let roots = makeWatchRoots(count: 4)
        let indices = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($1.id, $0) })
        let probe = ScanProbe()
        let (operations, catalogState) = makeOperations { source in
            guard let index = indices[source.id] else {
                throw ScanTestError(message: "unknown source")
            }
            await probe.recordStart(source.id)
            await probe.waitUntilReleased(source.id)
            await probe.recordFinish(source.id)
            return successfulResolution(source: source, index: index)
        }
        let generation = operations.generation.beginFullRescan()

        let task = Task {
            try await operations.prepareRestoreSources(
                state: PersistedState(watchRoots: roots),
                generation: generation,
                refreshUpstream: false
            )
        }

        await probe.waitForStarted(count: 2)
        _ = operations.generation.beginFullRescan()
        await probe.releaseAll()

        do {
            _ = try await task.value
            XCTFail("Stale restore unexpectedly returned a transaction")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected stale-generation error: \(error)")
        }
        XCTAssertTrue(catalogState.sourceScans.isEmpty)
        XCTAssertTrue(catalogState.repositories.isEmpty)
    }

}
