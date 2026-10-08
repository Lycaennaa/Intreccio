import Foundation

@MainActor
final class RepositoryCatalogSourceReconciliation {
    private let catalogState: RepositoryCatalogState
    private let lifecycle: RepositoryCatalogLifecycle
    private let generation: RepositoryCatalogGeneration
    private let sourceScanner: RepositoryCatalogSourceScanner
    private let standaloneResolver: RepositoryCatalogStandaloneResolver

    init(
        catalogState: RepositoryCatalogState,
        lifecycle: RepositoryCatalogLifecycle,
        generation: RepositoryCatalogGeneration,
        sourceScanner: RepositoryCatalogSourceScanner,
        standaloneResolver: RepositoryCatalogStandaloneResolver
    ) {
        self.catalogState = catalogState
        self.lifecycle = lifecycle
        self.generation = generation
        self.sourceScanner = sourceScanner
        self.standaloneResolver = standaloneResolver
    }

    var sourceScans: [UUID: RepoScanResult] { catalogState.sourceScans }
    var standaloneURLs: [UUID: URL] { catalogState.standaloneURLs }
    var repositories: [RepoDescriptor] { catalogState.repositories }
    var scanMessages: [UUID: String] { catalogState.scanMessages }

    func prepareRestoreSources(
        state: PersistedState,
        generation: UInt64?,
        refreshUpstream: Bool,
        initialStartup: Bool = false
    ) async throws -> CatalogTransaction {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        let previousRepositories = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        var scans: [UUID: RepoScanResult] = [:]
        var urls: [UUID: URL] = [:]
        var proposed = state
        var messages: [UUID: String] = [:]

        let candidateLimit = try PersistedCatalogBudget.remainingCandidateCapacity(for: proposed)

        let watchRootOutcomes = try await sourceScanner.scanWatchRoots(
            proposed.watchRoots,
            generation: generation,
            candidateLimit: candidateLimit
        )

        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        for (index, outcome) in watchRootOutcomes.enumerated() {
            let source = proposed.watchRoots[index]
            switch outcome {
            case .success(let resolvedSource, let result):
                proposed.watchRoots[index] = resolvedSource
                scans[source.id] = result
                messages[source.id] = repositoryCatalogScanMessage(for: result)
            case .scanFailure(let resolvedSource, let message):
                proposed.watchRoots[index] = resolvedSource
                messages[source.id] = "Scan failed: \(message)"
            case .accessFailure(let resolvedSource, let message):
                proposed.watchRoots[index] = resolvedSource
                messages[source.id] = "Access unavailable: \(message)"
            }
        }

        let standaloneResolutions = try await standaloneResolver.resolveStandalones(
            proposed.standaloneRepos,
            generation: generation
        )
        for (index, resolution) in standaloneResolutions.enumerated() {
            let source = proposed.standaloneRepos[index]
            switch resolution {
            case .resolved(let resolvedSource, let root):
                proposed.standaloneRepos[index] = resolvedSource
                urls[source.id] = root
            case .repositoryUnavailable(let resolvedSource, let message):
                proposed.standaloneRepos[index] = resolvedSource
                messages[source.id] = "Repository unavailable: \(message)"
            case .accessUnavailable(let resolvedSource, let message):
                proposed.standaloneRepos[index] = resolvedSource
                messages[source.id] = "Access unavailable: \(message)"
            }
        }

        guard !Task.isCancelled,
              !lifecycle.isShuttingDown,
              generation == nil || generation.map(self.generation.isCurrentFullRescan) == true else {
            throw CancellationError()
        }
        let provisional = catalogState.makeChange(
            state: proposed,
            sourceScans: scans,
            standaloneURLs: urls,
            scanMessages: messages,
            effect: .restored(
                changedRepositoryIDs: [],
                refreshUpstream: refreshUpstream,
                clearsStatusMessage: generation != nil
            )
        )
        let changedRepositoryIDs = provisional.repositories.filter { repository in
            guard repository.availability == .available else { return false }
            guard let previous = previousRepositories[repository.id] else { return true }
            return previous.availability != .available
                || previous.canonicalURL != repository.canonicalURL
                || previous.resourceID != repository.resourceID
        }.map(\.id)
        let effect = initialStartup
            ? CatalogEffectPlan.startupRestored(
                changedRepositoryIDs: changedRepositoryIDs,
                refreshUpstream: refreshUpstream,
                clearsStatusMessage: generation != nil
            )
            : CatalogEffectPlan.restored(
                changedRepositoryIDs: changedRepositoryIDs,
                refreshUpstream: refreshUpstream,
                clearsStatusMessage: generation != nil
            )
        let change = provisional.replacing(effect: effect)
        return CatalogTransaction(
            change: change,
            persistenceOrder: .afterAcceptance(clearPersistenceErrorOnSuccess: true)
        )
    }

    func prepareRescanSource(
        _ sourceID: UUID,
        generation: UInt64,
        state: PersistedState
    ) async throws -> CatalogTransaction? {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        if state.standaloneRepos.contains(where: { $0.id == sourceID }) {
            return try await prepareRescanStandaloneSource(
                sourceID,
                generation: generation,
                state: state
            )
        }
        guard let source = state.watchRoots.first(where: { $0.id == sourceID }) else { return nil }
        let candidateLimit = try PersistedCatalogBudget.remainingCandidateCapacity(for: state)

        let previousRepositories = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        let outcome = try await sourceScanner.scanWatchRoot(
            source,
            candidateLimit: candidateLimit
        )
        let resolutionSource: WatchRoot
        let result: RepoScanResult
        switch outcome {
        case .success(let source, let scanned):
            resolutionSource = source
            result = scanned
        case .scanFailure(_, let message), .accessFailure(_, let message):
            guard self.generation.isCurrentSourceRescan(sourceID: sourceID, generation: generation) else {
                throw CancellationError()
            }
            var messages = scanMessages
            messages[sourceID] = "Scan failed: \(message)"
            let change = catalogState.makeChange(
                state: state,
                scanMessages: messages,
                effect: .scanFailed
            )
            return CatalogTransaction(change: change, persistenceOrder: .acceptanceOnly)
        }

        guard self.generation.isCurrentSourceRescan(sourceID: sourceID, generation: generation),
              let index = state.watchRoots.firstIndex(where: { $0.id == sourceID }) else {
            throw CancellationError()
        }
        var proposed = state
        proposed.watchRoots[index] = resolutionSource
        var scans = sourceScans
        scans[sourceID] = result
        var messages = scanMessages
        messages[sourceID] = repositoryCatalogScanMessage(for: result)
        let provisional = catalogState.makeChange(
            state: proposed,
            sourceScans: scans,
            scanMessages: messages,
            effect: .sourceRescanned(changedRepositoryIDs: [])
        )
        let changedRepositoryIDs = provisional.repositories.filter { repository in
            guard repository.source.id == sourceID, repository.availability == .available else { return false }
            guard let previous = previousRepositories[repository.id] else { return true }
            return previous.availability != .available
                || previous.canonicalURL != repository.canonicalURL
                || previous.resourceID != repository.resourceID
        }.map(\.id)
        let change = provisional.replacing(effect: .sourceRescanned(
            changedRepositoryIDs: changedRepositoryIDs
        ))
        return CatalogTransaction(
            change: change,
            persistenceOrder: .afterAcceptance(clearPersistenceErrorOnSuccess: true)
        )
    }

    func prepareRescanStandaloneSource(
        _ sourceID: UUID,
        generation: UInt64,
        state: PersistedState
    ) async throws -> CatalogTransaction? {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }
        guard let index = state.standaloneRepos.firstIndex(where: { $0.id == sourceID }) else { return nil }
        var proposed = state
        var urls = standaloneURLs
        var message: String?
        let resolution = try await standaloneResolver.resolveStandalone(proposed.standaloneRepos[index])
        switch resolution {
        case .resolved(let source, let root):
            proposed.standaloneRepos[index] = source
            urls[sourceID] = root
        case .repositoryUnavailable(let source, let diagnostic):
            proposed.standaloneRepos[index] = source
            urls[sourceID] = nil
            message = "Repository unavailable: \(diagnostic)"
        case .accessUnavailable(let source, let diagnostic):
            proposed.standaloneRepos[index] = source
            urls[sourceID] = nil
            message = "Access unavailable: \(diagnostic)"
        }

        guard self.generation.isCurrentSourceRescan(sourceID: sourceID, generation: generation) else {
            throw CancellationError()
        }
        var messages = scanMessages
        messages[sourceID] = message
        let provisional = catalogState.makeChange(
            state: proposed,
            standaloneURLs: urls,
            scanMessages: messages,
            effect: .sourceRescanned(changedRepositoryIDs: [])
        )
        let changedRepositoryIDs = provisional.repositories.filter {
            $0.source.id == sourceID && $0.availability == .available
        }.map(\.id)
        let change = provisional.replacing(effect: .sourceRescanned(
            changedRepositoryIDs: changedRepositoryIDs
        ))
        return CatalogTransaction(
            change: change,
            persistenceOrder: .afterAcceptance(clearPersistenceErrorOnSuccess: true)
        )
    }

    private func isCurrentFullRescan(_ generation: UInt64?) -> Bool {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { return false }
        guard let generation else { return true }
        return self.generation.isCurrentFullRescan(generation)
    }
}
