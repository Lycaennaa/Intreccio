import Foundation

@MainActor
final class RepositoryCatalogSourceMutationOperations {
    private let catalogState: RepositoryCatalogState
    private let bookmarkStore: BookmarkStore
    private let gitService: GitService
    private let sourceResolver: RepositorySourceResolver
    private let lifecycle: RepositoryCatalogLifecycle
    private let sourceScanner: RepositoryCatalogSourceScanner
    init(
        catalogState: RepositoryCatalogState,
        bookmarkStore: BookmarkStore,
        gitService: GitService,
        sourceResolver: RepositorySourceResolver,
        lifecycle: RepositoryCatalogLifecycle,
        sourceScanner: RepositoryCatalogSourceScanner
    ) {
        self.catalogState = catalogState
        self.bookmarkStore = bookmarkStore
        self.gitService = gitService
        self.sourceResolver = sourceResolver
        self.lifecycle = lifecycle
        self.sourceScanner = sourceScanner
    }
    var sourceScans: [UUID: RepoScanResult] { catalogState.sourceScans }
    var standaloneRepositories: [UUID: StandaloneRepositoryLocation] { catalogState.standaloneRepositories }
    var repositories: [RepoDescriptor] { catalogState.repositories }
    var scanMessages: [UUID: String] { catalogState.scanMessages }

    func prepareAddWatchRoot(_ selectedURL: URL, state: PersistedState) async throws -> CatalogTransaction {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        let url = RepositoryPathPolicy.canonicalURL(selectedURL)
        guard !state.watchRoots.contains(where: {
            RepositoryPathPolicy.canonicalPath($0.lastResolvedPath) == url.path
        }) else {
            throw RepositoryCatalogCommandError.duplicateWatchRoot
        }

        let candidateLimit = try PersistedCatalogBudget.remainingCandidateCapacity(
            for: state,
            additionalSourceCount: 1
        )

        let bookmark = try await bookmarkStore.create(for: url)
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        let source = WatchRoot(
            id: UUID(),
            displayName: url.lastPathComponent,
            bookmarkData: bookmark,
            lastResolvedPath: url.path,
            resourceID: ResourceIdentity.read(from: url),
            exclusions: []
        )
        let outcome = try await sourceScanner.scanWatchRoot(
            source,
            candidateLimit: candidateLimit
        )

        let resolvedSource: WatchRoot
        let result: RepoScanResult
        switch outcome {
        case .success(let source, let scanned):
            resolvedSource = source
            result = scanned
        case .scanFailure(_, let message), .accessFailure(_, let message):
            throw RepositorySourceScanError(message: message)
        }
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }

        var proposed = state
        proposed.watchRoots.append(resolvedSource)
        var scans = sourceScans
        scans[source.id] = result
        var messages = scanMessages
        messages[source.id] = repositoryCatalogScanMessage(for: result)
        let change = catalogState.makeChange(
            state: proposed,
            sourceScans: scans,
            scanMessages: messages,
            effect: .sourceAdded()
        )
        return CatalogTransaction(change: change, persistenceOrder: .beforeAcceptance)
    }

    func prepareAddStandaloneRepository(
        _ selectedURL: URL,
        state: PersistedState
    ) async throws -> CatalogCommandPreparation {
        let url = RepositoryPathPolicy.canonicalURL(selectedURL)
        guard RepositoryPathPolicy.isRealDirectory(url) else {
            throw CoordinatorError.invalidRepository("Select a folder inside a Git repository.")
        }
        let root: URL
        do {
            root = try await gitService.repositoryRoot(at: url)
        } catch {
            guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
            throw CoordinatorError.invalidRepository("The selected folder is not inside a Git repository.")
        }
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        let resourceID = ResourceIdentity.read(from: root)
        if let existing = repositories.first(where: {
            $0.canonicalURL == root || (resourceID != nil && $0.resourceID == resourceID)
        }) {
            return .selectedRepository(existing.id)
        }
        let candidateLimit = try PersistedCatalogBudget.remainingCandidateCapacity(
            for: state,
            additionalSourceCount: 1
        )
        let gitDirectoryInfo = await sourceResolver.inspectGitDirectory(at: root)
        let submodules = try await sourceResolver.scanner.scanInitializedSubmodules(of: root)
        try RepositoryCatalogScanError.validateCandidateCount(
            1 + submodules.repositories.count,
            limit: candidateLimit
        )
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        let bookmark = try await bookmarkStore.create(for: root)
        let source = StandaloneRepository(
            id: UUID(),
            displayName: root.lastPathComponent,
            bookmarkData: bookmark,
            lastResolvedPath: root.path,
            resourceID: resourceID
        )
        var proposed = state
        proposed.standaloneRepos.append(source)
        var standaloneRepositories = self.standaloneRepositories
        standaloneRepositories[source.id] = StandaloneRepositoryLocation(
            url: root,
            gitDirectoryInfo: gitDirectoryInfo,
            submoduleRepositories: submodules.repositories,
            hasSubmodules: submodules.hasConfiguredSubmodules,
            submoduleScanIncomplete: submodules.isIncomplete
        )
        var messages = scanMessages
        messages[source.id] = RepositoryCatalogSubmoduleDiagnostic.message(for: submodules)
        let change = catalogState.makeChange(
            state: proposed,
            standaloneRepositories: standaloneRepositories,
            scanMessages: messages,
            effect: .sourceAdded()
        )
        return .changed(CatalogTransaction(change: change, persistenceOrder: .beforeAcceptance))
    }

    func prepareRemoveSource(_ sourceID: UUID, state: PersistedState) throws -> CatalogTransaction {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        let removed = repositories.filter { $0.source.id == sourceID }.map(\.id)
        var proposed = state
        proposed.watchRoots.removeAll { $0.id == sourceID }
        proposed.standaloneRepos.removeAll { $0.id == sourceID }
        var scans = sourceScans
        var repositories = standaloneRepositories
        var messages = scanMessages
        scans[sourceID] = nil
        repositories[sourceID] = nil
        messages[sourceID] = nil
        let provisional = catalogState.makeChange(
            state: proposed,
            sourceScans: scans,
            standaloneRepositories: repositories,
            scanMessages: messages,
            effect: .sourceRemoved(sourceID: sourceID, removedRepositoryIDs: [])
        )
        let repositoryIDs = Set(provisional.repositories.map(\.id))
        let removedWithoutReplacement = removed.filter { !repositoryIDs.contains($0) }
        let change = provisional.replacing(effect: .sourceRemoved(
            sourceID: sourceID,
            removedRepositoryIDs: removedWithoutReplacement
        ))
        return CatalogTransaction(change: change, persistenceOrder: .beforeAcceptance)
    }

    func prepareExcludePath(
        sourceID: UUID,
        path: String,
        state: PersistedState
    ) async throws -> CatalogCommandPreparation {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        let normalizedPath = RepositoryPathPolicy.normalizedRelativePath(path)
        let exclusionPath = normalizedPath.isEmpty ? "." : normalizedPath
        guard let index = state.watchRoots.firstIndex(where: { $0.id == sourceID }) else {
            return .noChange
        }
        let sourceRoot = URL(fileURLWithPath: state.watchRoots[index].lastResolvedPath, isDirectory: true)
        let caseSensitive = RepositoryPathPolicy.isCaseSensitiveVolume(at: sourceRoot)
        guard !state.watchRoots[index].exclusions.contains(where: {
            RepositoryPathPolicy.isWithin(
                relativePath: exclusionPath,
                folder: $0,
                caseSensitive: caseSensitive
            )
        }) else {
            return .noChange
        }

        let removedRepositoryIDs = repositories.filter {
            $0.source.id == sourceID
                && RepositoryPathPolicy.isWithin(
                    relativePath: $0.relativePath,
                    folder: exclusionPath,
                    caseSensitive: caseSensitive
                )
        }.map(\.id)
        var proposed = state
        proposed.watchRoots[index].exclusions.removeAll {
            RepositoryPathPolicy.isWithin(
                relativePath: $0,
                folder: exclusionPath,
                caseSensitive: caseSensitive
            )
        }
        proposed.watchRoots[index].exclusions.append(exclusionPath)
        proposed.watchRoots[index].exclusions.sort()
        var scans = sourceScans
        scans[sourceID]?.repositories.removeAll {
            RepositoryPathPolicy.isWithin(
                relativePath: $0.relativePath,
                folder: exclusionPath,
                caseSensitive: caseSensitive
            )
        }
        let provisional = catalogState.makeChange(
            state: proposed,
            sourceScans: scans,
            effect: .sourceExcluded(removedRepositoryIDs: []),
            repositoryFilter: CatalogRepositoryFilter(
                sourceID: sourceID,
                folder: exclusionPath,
                caseSensitive: caseSensitive
            )
        )
        let repositoryIDs = Set(provisional.repositories.map(\.id))
        let removedWithoutReplacement = removedRepositoryIDs.filter { !repositoryIDs.contains($0) }
        let change = provisional.replacing(effect: .sourceExcluded(
            removedRepositoryIDs: removedWithoutReplacement
        ))
        return .changed(CatalogTransaction(change: change, persistenceOrder: .beforeAcceptance))
    }

    func prepareRestoreExclusion(
        sourceID: UUID,
        path: String,
        state: PersistedState
    ) throws -> CatalogCommandPreparation {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        guard let index = state.watchRoots.firstIndex(where: { $0.id == sourceID }) else {
            return .noChange
        }
        var proposed = state
        proposed.watchRoots[index].exclusions.removeAll { $0 == path }
        let change = catalogState.makeChange(state: proposed, effect: .exclusionRestored)
        return .changed(CatalogTransaction(change: change, persistenceOrder: .beforeAcceptance))
    }

    func prepareReauthorizeSource(
        _ sourceID: UUID,
        selectedURL: URL,
        state: PersistedState
    ) async throws -> CatalogCommandPreparation {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        let url = RepositoryPathPolicy.canonicalURL(selectedURL)
        let bookmark = try await bookmarkStore.create(for: url)
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        var proposed = state
        var standaloneRepositories = self.standaloneRepositories
        var messages = scanMessages
        if let index = proposed.watchRoots.firstIndex(where: { $0.id == sourceID }) {
            proposed.watchRoots[index].bookmarkData = bookmark
            proposed.watchRoots[index].lastResolvedPath = url.path
            proposed.watchRoots[index].displayName = url.lastPathComponent
            proposed.watchRoots[index].resourceID = ResourceIdentity.read(from: url)
        } else if let index = proposed.standaloneRepos.firstIndex(where: { $0.id == sourceID }) {
            guard RepositoryPathPolicy.isRealDirectory(url.appendingPathComponent(".git", isDirectory: true)) else {
                throw CoordinatorError.invalidRepository("Select the repository top-level folder.")
            }
            let repositoryRoot = try await gitService.repositoryRoot(at: url)
            guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
            guard repositoryRoot == url else {
                throw CoordinatorError.invalidRepository("Select the repository top-level folder.")
            }
            let candidateLimit = try PersistedCatalogBudget.remainingCandidateCapacity(for: state)
            let gitDirectoryInfo = await sourceResolver.inspectGitDirectory(at: repositoryRoot)
            let submodules = try await sourceResolver.scanner.scanInitializedSubmodules(of: repositoryRoot)
            try RepositoryCatalogScanError.validateCandidateCount(
                1 + submodules.repositories.count,
                limit: candidateLimit
            )
            guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
            proposed.standaloneRepos[index].bookmarkData = bookmark
            proposed.standaloneRepos[index].lastResolvedPath = url.path
            proposed.standaloneRepos[index].displayName = url.lastPathComponent
            proposed.standaloneRepos[index].resourceID = ResourceIdentity.read(from: url)
            standaloneRepositories[sourceID] = StandaloneRepositoryLocation(
                url: repositoryRoot,
                gitDirectoryInfo: gitDirectoryInfo,
                submoduleRepositories: submodules.repositories,
                hasSubmodules: submodules.hasConfiguredSubmodules,
                submoduleScanIncomplete: submodules.isIncomplete
            )
            messages[sourceID] = RepositoryCatalogSubmoduleDiagnostic.message(for: submodules)
        } else {
            return .noChange
        }
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        let change = catalogState.makeChange(
            state: proposed,
            standaloneRepositories: standaloneRepositories,
            scanMessages: messages,
            effect: .sourceReauthorized
        )
        return .changed(CatalogTransaction(change: change, persistenceOrder: .beforeAcceptance))
    }

}
