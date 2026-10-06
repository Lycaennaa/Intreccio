import Foundation
import XCTest
@testable import Intreccio

extension RepositoryCatalogRefactorTests {
    func testBeforeAcceptanceCommitPersistsBeforeReconciliation() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: stateFile)
        let lifecycle = RepositoryCatalogLifecycle()
        let catalogState = RepositoryCatalogState(fixture: nil)
        let probe = CatalogCommitProbe(stateFile: stateFile)
        let committer = RepositoryCatalogCommitter(stateStore: store, lifecycle: lifecycle)
        committer.delegate = probe
        let change = makeChange(message: "before", effect: .sourceAdded())

        try await committer.commit(
            CatalogTransaction(change: change, persistenceOrder: .beforeAcceptance),
            state: catalogState
        )

        XCTAssertEqual(catalogState.scanMessages.values.first, "before")
        XCTAssertTrue(probe.fileExistedWhenReconciled)
        XCTAssertEqual(probe.commitStatuses, [.succeeded])
    }
    func testBeforeAcceptanceCommitFinishesAcceptanceAfterCancellation() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: stateFile)
        let lifecycle = RepositoryCatalogLifecycle()
        let catalogState = RepositoryCatalogState(fixture: nil)
        let probe = CatalogCommitProbe(stateFile: stateFile)
        let committer = RepositoryCatalogCommitter(stateStore: store, lifecycle: lifecycle)
        committer.delegate = probe
        committer.persistenceDidCompleteForTesting = {
            withUnsafeCurrentTask { $0?.cancel() }
        }

        let task = Task {
            try await committer.commit(
                CatalogTransaction(
                    change: makeChange(message: "cancelled", effect: .sourceAdded()),
                    persistenceOrder: .beforeAcceptance
                ),
                state: catalogState
            )
        }
        try await task.value

        XCTAssertEqual(catalogState.scanMessages.values.first, "cancelled")
        XCTAssertTrue(probe.fileExistedWhenReconciled)
        XCTAssertEqual(probe.commitStatuses, [.succeeded])
    }

    func testAfterAcceptanceCommitKeepsAcceptedStateWhenPersistenceFails() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        try Data(#"{"schemaVersion":999}"#.utf8).write(to: stateFile)
        let store = StateStore(fileURL: stateFile)
        _ = await store.load()
        let lifecycle = RepositoryCatalogLifecycle()
        let catalogState = RepositoryCatalogState(fixture: nil)
        let probe = CatalogCommitProbe(stateFile: stateFile)
        let committer = RepositoryCatalogCommitter(stateStore: store, lifecycle: lifecycle)
        committer.delegate = probe
        let change = makeChange(message: "after", effect: .sourceRescanned(changedRepositoryIDs: []))

        do {
            try await committer.commit(
                CatalogTransaction(
                    change: change,
                    persistenceOrder: .afterAcceptance(clearPersistenceErrorOnSuccess: true)
                ),
                state: catalogState
            )
            XCTFail("Expected persistence failure")
        } catch {
        }

        XCTAssertEqual(catalogState.scanMessages.values.first, "after")
        XCTAssertTrue(probe.fileExistedWhenReconciled)
        XCTAssertEqual(probe.commitStatuses, [.failed])
    }

    func testAfterAcceptanceCommitSavesAfterReconciliation() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: stateFile)
        let lifecycle = RepositoryCatalogLifecycle()
        let catalogState = RepositoryCatalogState(fixture: nil)
        let probe = CatalogCommitProbe(stateFile: stateFile)
        let committer = RepositoryCatalogCommitter(stateStore: store, lifecycle: lifecycle)
        committer.delegate = probe

        try await committer.commit(
            CatalogTransaction(
                change: makeChange(message: "after-success", effect: .sourceRescanned(changedRepositoryIDs: [])),
                persistenceOrder: .afterAcceptance(clearPersistenceErrorOnSuccess: true)
            ),
            state: catalogState
        )

        XCTAssertFalse(probe.fileExistedWhenReconciled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path))
        XCTAssertEqual(probe.commitStatuses, [.succeeded])
    }

    func testBeforeAcceptancePersistenceFailureDoesNotAcceptChange() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        try Data(#"{"schemaVersion":999}"#.utf8).write(to: stateFile)
        let store = StateStore(fileURL: stateFile)
        _ = await store.load()
        let lifecycle = RepositoryCatalogLifecycle()
        let catalogState = RepositoryCatalogState(fixture: nil)
        let probe = CatalogCommitProbe(stateFile: stateFile)
        let committer = RepositoryCatalogCommitter(stateStore: store, lifecycle: lifecycle)
        committer.delegate = probe

        do {
            try await committer.commit(
                CatalogTransaction(
                    change: makeChange(message: "rejected", effect: .sourceAdded()),
                    persistenceOrder: .beforeAcceptance
                ),
                state: catalogState
            )
            XCTFail("Expected persistence failure")
        } catch {
        }

        XCTAssertTrue(catalogState.scanMessages.isEmpty)
        XCTAssertEqual(probe.reconcileCount, 0)
        XCTAssertTrue(probe.commitStatuses.isEmpty)
    }

    func testAcceptanceOnlyCommitAcceptsWithoutPersistence() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: stateFile)
        let lifecycle = RepositoryCatalogLifecycle()
        let catalogState = RepositoryCatalogState(fixture: nil)
        let probe = CatalogCommitProbe(stateFile: stateFile)
        let committer = RepositoryCatalogCommitter(stateStore: store, lifecycle: lifecycle)
        committer.delegate = probe

        try await committer.commit(
            CatalogTransaction(
                change: makeChange(message: "accepted", effect: .scanFailed),
                persistenceOrder: .acceptanceOnly
            ),
            state: catalogState
        )

        XCTAssertEqual(catalogState.scanMessages.values.first, "accepted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path))
        XCTAssertEqual(probe.commitStatuses, [.notRequested])
    }
    func testOverBudgetCatalogChangeIsRejectedBeforeAcceptanceAndPreservesFiles() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: stateFile)
        var original = PersistedState()
        original.uiState.searchText = "original"
        try await store.save(original)
        let originalCatalog = try Data(contentsOf: stateFile)
        let uiFileURL = await store.uiFileURL
        let originalUI = try Data(contentsOf: uiFileURL)

        var overBudget = PersistedState()
        overBudget.watchRoots = (0...PersistedCatalogBudget.maxEntryCount).map { index in
            WatchRoot(
                id: UUID(),
                displayName: "Root \(index)",
                bookmarkData: Data(),
                lastResolvedPath: "/root-\(index)",
                resourceID: nil,
                exclusions: []
            )
        }
        do {
            try await store.save(overBudget)
            XCTFail("Expected over-budget catalog save to fail")
        } catch StateStoreError.catalogBudgetExceeded {
        }
        XCTAssertEqual(try Data(contentsOf: stateFile), originalCatalog)
        XCTAssertEqual(try Data(contentsOf: uiFileURL), originalUI)

        let change = CatalogChange(
            state: overBudget,
            sourceScans: [:],
            standaloneURLs: [:],
            repositories: [],
            scanMessages: [:],
            effect: .sourceRescanned(changedRepositoryIDs: [])
        )
        let catalogState = RepositoryCatalogState(fixture: nil)
        let probe = CatalogCommitProbe(stateFile: stateFile)
        let committer = RepositoryCatalogCommitter(stateStore: store, lifecycle: RepositoryCatalogLifecycle())
        committer.delegate = probe

        do {
            try await committer.commit(
                CatalogTransaction(
                    change: change,
                    persistenceOrder: .afterAcceptance(clearPersistenceErrorOnSuccess: true)
                ),
                state: catalogState
            )
            XCTFail("Expected over-budget catalog change to be rejected")
        } catch StateStoreError.catalogBudgetExceeded {
        }

        XCTAssertEqual(probe.reconcileCount, 0)
        XCTAssertEqual(probe.repositoryCatalogState, PersistedState())
        XCTAssertEqual(try Data(contentsOf: stateFile), originalCatalog)
        XCTAssertEqual(try Data(contentsOf: uiFileURL), originalUI)
    }


    func testSourcePreparationsUseExplicitPersistenceOrder() async throws {
        let workspace = try makeTestDirectory()
        let watchedRepository = workspace.appendingPathComponent("Watched", isDirectory: true)
        try makeGitRepository(at: watchedRepository)
        let addedRoot = try makeTestDirectory()
        try makeGitRepository(at: addedRoot)
        let standaloneRoot = try makeTestDirectory()
        try makeGitRepository(at: standaloneRoot)
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: workspace.appendingPathComponent("state.json"))
        )
        await coordinator.addWatchRoot(workspace)

        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)
        let operations = coordinator.catalog.sourceOperations
        let state = coordinator.state

        let addedWatchRoot = try await operations.prepareAddWatchRoot(addedRoot, state: state)
        XCTAssertEqual(addedWatchRoot.persistenceOrder, .beforeAcceptance)
        let addedStandalone = try await operations.prepareAddStandaloneRepository(standaloneRoot, state: state)
        guard case .changed(let addedTransaction) = addedStandalone else {
            XCTFail("Expected changed standalone preparation")
            return
        }
        XCTAssertEqual(addedTransaction.persistenceOrder, .beforeAcceptance)
        XCTAssertEqual(
            try operations.prepareRemoveSource(sourceID, state: state).persistenceOrder,
            .beforeAcceptance
        )
        let repositoryPath = try XCTUnwrap(coordinator.repositories.first?.relativePath)
        let excluded = try await operations.prepareExcludePath(
            sourceID: sourceID,
            path: repositoryPath,
            state: state
        )
        guard case .changed(let excludedTransaction) = excluded else {
            XCTFail("Expected changed exclusion preparation")
            return
        }
        XCTAssertEqual(excludedTransaction.persistenceOrder, .beforeAcceptance)
        let restoredExclusion = try operations.prepareRestoreExclusion(
            sourceID: sourceID,
            path: repositoryPath,
            state: state
        )
        guard case .changed(let restoredTransaction) = restoredExclusion else {
            XCTFail("Expected changed restoration preparation")
            return
        }
        XCTAssertEqual(restoredTransaction.persistenceOrder, .beforeAcceptance)
        let reauthorized = try await operations.prepareReauthorizeSource(
            sourceID,
            selectedURL: workspace,
            state: state
        )
        guard case .changed(let reauthorizedTransaction) = reauthorized else {
            XCTFail("Expected changed reauthorization preparation")
            return
        }
        XCTAssertEqual(reauthorizedTransaction.persistenceOrder, .beforeAcceptance)

        let restored = try await operations.prepareRestoreSources(
            state: state,
            generation: nil,
            refreshUpstream: true
        )
        XCTAssertEqual(restored.persistenceOrder, .afterAcceptance(clearPersistenceErrorOnSuccess: true))
        XCTAssertEqual(
            restored.change.effect.runtimeSteps[1],
            .scheduleGitHubURLLookups(target: .changed, forceRefresh: true)
        )
        let startupRestored = try await operations.prepareRestoreSources(
            state: state,
            generation: nil,
            refreshUpstream: true,
            initialStartup: true
        )
        XCTAssertEqual(
            startupRestored.change.effect.runtimeSteps[1],
            .scheduleGitHubURLLookups(target: .all, forceRefresh: true)
        )
        let rescanGeneration = operations.generation.beginSourceRescan(sourceID)
        guard let rescanned = try await operations.prepareRescanSource(
            sourceID,
            generation: rescanGeneration,
            state: state
        ) else {
            XCTFail("Expected source rescan transaction")
            return
        }
        XCTAssertEqual(rescanned.persistenceOrder, .afterAcceptance(clearPersistenceErrorOnSuccess: true))
    }
}
#if DEBUG
@MainActor
extension RepositoryCatalogRefactorTests {
    func testAfterAcceptanceCommitWritesChangedAcceptedCatalogInsteadOfValidatedCatalog() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: stateFile)
        let lifecycle = RepositoryCatalogLifecycle()
        let catalogState = RepositoryCatalogState(fixture: nil)
        let probe = CatalogCommitProbe(stateFile: stateFile)
        let change: CatalogChange = makeChange(message: "validated", effect: .sourceRescanned(changedRepositoryIDs: []))
        var acceptedState = change.state
        acceptedState.watchRoots = [WatchRoot(
            id: UUID(),
            displayName: "Accepted",
            bookmarkData: Data(),
            lastResolvedPath: "/accepted",
            resourceID: nil,
            exclusions: []
        )]
        probe.reconciledState = acceptedState
        let committer = RepositoryCatalogCommitter(stateStore: store, lifecycle: lifecycle)
        committer.delegate = probe

        try await committer.commit(
            CatalogTransaction(
                change: change,
                persistenceOrder: .afterAcceptance(clearPersistenceErrorOnSuccess: true)
            ),
            state: catalogState
        )

        let encodingCount = await store.catalogEncodingCountForTesting
        XCTAssertEqual(encodingCount, 2)
        let loaded = await store.load()
        XCTAssertEqual(loaded.state, acceptedState)
        XCTAssertEqual(probe.commitStatuses, [CatalogPersistenceStatus.succeeded])
    }
}
#endif