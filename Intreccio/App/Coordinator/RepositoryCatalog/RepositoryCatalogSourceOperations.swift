import Foundation

enum CatalogCommandPreparation {
    case changed(CatalogTransaction)
    case selectedRepository(UUID)
    case noChange
}

func repositoryCatalogScanMessage(for result: RepoScanResult) -> String? {
    if let reason = result.incompleteReason { return reason }
    if !result.warnings.isEmpty { return result.warnings.joined(separator: "\n") }
    return nil
}

@MainActor
final class RepositoryCatalogSourceOperations {
    let catalogState: RepositoryCatalogState
    let bookmarkStore: BookmarkStore
    let gitService: GitService
    let sourceResolver: RepositorySourceResolver
    let lifecycle: RepositoryCatalogLifecycle
    let generation: RepositoryCatalogGeneration
    private let mutationOperations: RepositoryCatalogSourceMutationOperations
    private let reconciliationOperations: RepositoryCatalogSourceReconciliation

    init(
        catalogState: RepositoryCatalogState,
        bookmarkStore: BookmarkStore,
        gitService: GitService,
        sourceResolver: RepositorySourceResolver,
        lifecycle: RepositoryCatalogLifecycle,
        generation: RepositoryCatalogGeneration,
        watchRootScanOperation: (@MainActor @Sendable (WatchRoot) async throws -> RepositoryWatchRootScanOutcome)? = nil
    ) {
        self.catalogState = catalogState
        self.bookmarkStore = bookmarkStore
        self.gitService = gitService
        self.sourceResolver = sourceResolver
        self.lifecycle = lifecycle
        self.generation = generation

        let sourceScanner = RepositoryCatalogSourceScanner(
            operation: watchRootScanOperation ?? { source in
                try await sourceResolver.scanWatchRoot(source)
            },
            generation: generation,
            lifecycle: lifecycle
        )
        let standaloneResolver = RepositoryCatalogStandaloneResolver(
            sourceResolver: sourceResolver,
            lifecycle: lifecycle,
            generation: generation
        )
        mutationOperations = RepositoryCatalogSourceMutationOperations(
            catalogState: catalogState,
            bookmarkStore: bookmarkStore,
            gitService: gitService,
            lifecycle: lifecycle,
            sourceScanner: sourceScanner
        )
        reconciliationOperations = RepositoryCatalogSourceReconciliation(
            catalogState: catalogState,
            lifecycle: lifecycle,
            generation: generation,
            sourceScanner: sourceScanner,
            standaloneResolver: standaloneResolver
        )
    }

    var sourceScans: [UUID: RepoScanResult] { catalogState.sourceScans }
    var standaloneURLs: [UUID: URL] { catalogState.standaloneURLs }
    var repositories: [RepoDescriptor] { catalogState.repositories }
    var scanMessages: [UUID: String] { catalogState.scanMessages }

    func prepareAddWatchRoot(_ selectedURL: URL, state: PersistedState) async throws -> CatalogTransaction {
        try await mutationOperations.prepareAddWatchRoot(selectedURL, state: state)
    }

    func prepareAddStandaloneRepository(
        _ selectedURL: URL,
        state: PersistedState
    ) async throws -> CatalogCommandPreparation {
        try await mutationOperations.prepareAddStandaloneRepository(selectedURL, state: state)
    }

    func prepareRemoveSource(_ sourceID: UUID, state: PersistedState) throws -> CatalogTransaction {
        try mutationOperations.prepareRemoveSource(sourceID, state: state)
    }

    func prepareExcludePath(
        sourceID: UUID,
        path: String,
        state: PersistedState
    ) async throws -> CatalogCommandPreparation {
        try await mutationOperations.prepareExcludePath(sourceID: sourceID, path: path, state: state)
    }

    func prepareRestoreExclusion(
        sourceID: UUID,
        path: String,
        state: PersistedState
    ) throws -> CatalogCommandPreparation {
        try mutationOperations.prepareRestoreExclusion(sourceID: sourceID, path: path, state: state)
    }

    func prepareReauthorizeSource(
        _ sourceID: UUID,
        selectedURL: URL,
        state: PersistedState
    ) async throws -> CatalogCommandPreparation {
        try await mutationOperations.prepareReauthorizeSource(
            sourceID,
            selectedURL: selectedURL,
            state: state
        )
    }

    func prepareRestoreSources(
        state: PersistedState,
        generation: UInt64?,
        refreshUpstream: Bool,
        initialStartup: Bool = false
    ) async throws -> CatalogTransaction {
        try await reconciliationOperations.prepareRestoreSources(
            state: state,
            generation: generation,
            refreshUpstream: refreshUpstream,
            initialStartup: initialStartup
        )
    }

    func prepareRescanSource(
        _ sourceID: UUID,
        generation: UInt64,
        state: PersistedState
    ) async throws -> CatalogTransaction? {
        try await reconciliationOperations.prepareRescanSource(
            sourceID,
            generation: generation,
            state: state
        )
    }

    func prepareRescanStandaloneSource(
        _ sourceID: UUID,
        generation: UInt64,
        state: PersistedState
    ) async throws -> CatalogTransaction? {
        try await reconciliationOperations.prepareRescanStandaloneSource(
            sourceID,
            generation: generation,
            state: state
        )
    }
}
