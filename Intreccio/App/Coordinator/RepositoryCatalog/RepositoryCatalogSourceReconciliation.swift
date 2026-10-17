import Foundation

private struct RestoredWatchRootSources {
    let sources: [WatchRoot]
    let scans: [UUID: RepoScanResult]
    let messages: [UUID: String]
}

private struct RestoredStandaloneSources {
    let sources: [StandaloneRepository]
    let locations: [UUID: StandaloneRepositoryLocation]
    let messages: [UUID: String]
}
nonisolated enum RepositoryCatalogSubmoduleDiagnostic {
    static func message(for submodules: ScannedSubmodules) -> String? {
        if let warning = submodules.warnings.first {
            return "Submodule scan warning: \(warning)"
        }
        if submodules.reachedTimeLimit { return "Submodule scan stopped at its time limit." }
        if submodules.reachedRepositoryLimit {
            return "Submodule scan stopped after finding the repository limit."
        }
        return nil
    }
}

@MainActor
final class RepositoryCatalogSourceReconciliation {
    private let catalogState: RepositoryCatalogState
    private let lifecycle: RepositoryCatalogLifecycle
    private let generation: RepositoryCatalogGeneration
    private let sourceScanner: RepositoryCatalogSourceScanner
    private let sourceResolver: RepositorySourceResolver
    private let standaloneResolver: RepositoryCatalogStandaloneResolver

    init(
        catalogState: RepositoryCatalogState,
        lifecycle: RepositoryCatalogLifecycle,
        generation: RepositoryCatalogGeneration,
        sourceScanner: RepositoryCatalogSourceScanner,
        sourceResolver: RepositorySourceResolver,
        standaloneResolver: RepositoryCatalogStandaloneResolver
    ) {
        self.catalogState = catalogState
        self.lifecycle = lifecycle
        self.generation = generation
        self.sourceScanner = sourceScanner
        self.sourceResolver = sourceResolver
        self.standaloneResolver = standaloneResolver
    }

    var sourceScans: [UUID: RepoScanResult] { catalogState.sourceScans }
    var standaloneRepositories: [UUID: StandaloneRepositoryLocation] { catalogState.standaloneRepositories }
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
        let candidateLimit = try PersistedCatalogBudget.remainingCandidateCapacity(for: state)
        let watchRootSources = try await resolveWatchRootSources(
            state.watchRoots,
            generation: generation,
            candidateLimit: candidateLimit
        )
        let watchRootCandidateCount = watchRootSources.scans.values.reduce(0) {
            $0 + $1.repositories.count
        }
        let standaloneCandidateLimit = candidateLimit - watchRootCandidateCount
        let standaloneSources = try await resolveStandaloneSources(
            state.standaloneRepos,
            generation: generation,
            candidateLimit: standaloneCandidateLimit
        )
        var proposed = state
        proposed.watchRoots = watchRootSources.sources
        proposed.standaloneRepos = standaloneSources.sources
        var messages = watchRootSources.messages
        messages.merge(standaloneSources.messages) { _, standaloneMessage in standaloneMessage }
        let snapshotGitDirectoryInfos = try await resolveSnapshotGitDirectoryInfos(
            state: proposed,
            sourceScans: watchRootSources.scans,
            standaloneRepositories: standaloneSources.locations,
            previousRepositories: Array(previousRepositories.values),
            generation: generation
        )
        guard !Task.isCancelled,
              !lifecycle.isShuttingDown,
              generation == nil || generation.map(self.generation.isCurrentFullRescan) == true else {
            throw CancellationError()
        }
        let provisional = catalogState.makeChange(
            state: proposed,
            sourceScans: watchRootSources.scans,
            standaloneRepositories: standaloneSources.locations,
            scanMessages: messages,
            snapshotGitDirectoryInfos: snapshotGitDirectoryInfos,
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
        let effect = restoredEffect(
            changedRepositoryIDs: changedRepositoryIDs,
            refreshUpstream: refreshUpstream,
            clearsStatusMessage: generation != nil,
            initialStartup: initialStartup
        )
        return CatalogTransaction(
            change: provisional.replacing(effect: effect),
            persistenceOrder: .afterAcceptance(clearPersistenceErrorOnSuccess: true)
        )
    }

    private func restoredEffect(
        changedRepositoryIDs: [UUID],
        refreshUpstream: Bool,
        clearsStatusMessage: Bool,
        initialStartup: Bool
    ) -> CatalogEffectPlan {
        if initialStartup {
            return .startupRestored(
                changedRepositoryIDs: changedRepositoryIDs,
                refreshUpstream: refreshUpstream,
                clearsStatusMessage: clearsStatusMessage
            )
        }
        return .restored(
            changedRepositoryIDs: changedRepositoryIDs,
            refreshUpstream: refreshUpstream,
            clearsStatusMessage: clearsStatusMessage
        )
    }

    private func resolveSnapshotGitDirectoryInfos(
        state: PersistedState,
        sourceScans: [UUID: RepoScanResult],
        standaloneRepositories: [UUID: StandaloneRepositoryLocation],
        previousRepositories: [RepoDescriptor],
        generation: UInt64?
    ) async throws -> [UUID: GitDirectoryInfo] {
        let snapshots = RepositoryCatalogRebuilder.snapshotsNeedingGitDirectoryInfo(
            state: state,
            sourceScans: sourceScans,
            standaloneRepositories: standaloneRepositories,
            previousRepositories: previousRepositories
        )
        var metadata: [UUID: GitDirectoryInfo] = [:]
        for snapshot in snapshots {
            guard isCurrentFullRescan(generation) else { throw CancellationError() }
            let url = URL(fileURLWithPath: snapshot.canonicalPath, isDirectory: true)
            let gitDirectoryInfo = await sourceResolver.inspectGitDirectory(at: url)
            guard isCurrentFullRescan(generation) else { throw CancellationError() }
            if let gitDirectoryInfo { metadata[snapshot.id] = gitDirectoryInfo }
        }
        return metadata
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
            return try failedSourceRescan(
                sourceID,
                generation: generation,
                state: state,
                message: message
            )
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
        var locations = standaloneRepositories
        var message: String?
        let candidateLimit = try PersistedCatalogBudget.remainingCandidateCapacity(for: state)
        let resolution = try await standaloneResolver.resolveStandalone(proposed.standaloneRepos[index])
        switch resolution {
        case .resolved(let source, let root, let gitDirectoryInfo, let submodules):
            try RepositoryCatalogScanError.validateCandidateCount(
                1 + submodules.repositories.count,
                limit: candidateLimit
            )
            proposed.standaloneRepos[index] = source
            locations[sourceID] = StandaloneRepositoryLocation(
                url: root,
                gitDirectoryInfo: gitDirectoryInfo,
                submoduleRepositories: submodules.repositories,
                hasSubmodules: submodules.hasConfiguredSubmodules,
                submoduleScanIncomplete: submodules.isIncomplete
            )
            message = RepositoryCatalogSubmoduleDiagnostic.message(for: submodules)
        case .repositoryUnavailable(let source, let diagnostic):
            proposed.standaloneRepos[index] = source
            locations[sourceID] = nil
            message = "Repository unavailable: \(diagnostic)"
        case .accessUnavailable(let source, let diagnostic):
            proposed.standaloneRepos[index] = source
            locations[sourceID] = nil
            message = "Access unavailable: \(diagnostic)"
        }

        guard self.generation.isCurrentSourceRescan(sourceID: sourceID, generation: generation) else {
            throw CancellationError()
        }
        var messages = scanMessages
        messages[sourceID] = message
        let provisional = catalogState.makeChange(
            state: proposed,
            standaloneRepositories: locations,
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

    private func resolveWatchRootSources(
        _ sources: [WatchRoot],
        generation: UInt64?,
        candidateLimit: Int
    ) async throws -> RestoredWatchRootSources {
        let outcomes = try await sourceScanner.scanWatchRoots(
            sources,
            generation: generation,
            candidateLimit: candidateLimit
        )
        var resolvedSources = sources
        var scans: [UUID: RepoScanResult] = [:]
        var messages: [UUID: String] = [:]
        for (index, outcome) in outcomes.enumerated() {
            let source = sources[index]
            switch outcome {
            case .success(let resolvedSource, let result):
                resolvedSources[index] = resolvedSource
                scans[source.id] = result
                messages[source.id] = repositoryCatalogScanMessage(for: result)
            case .scanFailure(let resolvedSource, let message):
                resolvedSources[index] = resolvedSource
                messages[source.id] = "Scan failed: \(message)"
            case .accessFailure(let resolvedSource, let message):
                resolvedSources[index] = resolvedSource
                messages[source.id] = "Access unavailable: \(message)"
            }
        }
        return RestoredWatchRootSources(sources: resolvedSources, scans: scans, messages: messages)
    }

    private func resolveStandaloneSources(
        _ sources: [StandaloneRepository],
        generation: UInt64?,
        candidateLimit: Int
    ) async throws -> RestoredStandaloneSources {
        let resolutions = try await standaloneResolver.resolveStandalones(
            sources,
            generation: generation,
            candidateLimit: candidateLimit
        )
        var resolvedSources = sources
        var locations: [UUID: StandaloneRepositoryLocation] = [:]
        var messages: [UUID: String] = [:]
        for (index, resolution) in resolutions.enumerated() {
            let source = sources[index]
            switch resolution {
            case .resolved(let resolvedSource, let root, let gitDirectoryInfo, let submodules):
                resolvedSources[index] = resolvedSource
                locations[source.id] = StandaloneRepositoryLocation(
                    url: root,
                    gitDirectoryInfo: gitDirectoryInfo,
                    submoduleRepositories: submodules.repositories,
                    hasSubmodules: submodules.hasConfiguredSubmodules,
                    submoduleScanIncomplete: submodules.isIncomplete
                )
                if let message = RepositoryCatalogSubmoduleDiagnostic.message(for: submodules) {
                    messages[source.id] = message
                }
            case .repositoryUnavailable(let resolvedSource, let message):
                resolvedSources[index] = resolvedSource
                messages[source.id] = "Repository unavailable: \(message)"
            case .accessUnavailable(let resolvedSource, let message):
                resolvedSources[index] = resolvedSource
                messages[source.id] = "Access unavailable: \(message)"
            }
        }
        return RestoredStandaloneSources(
            sources: resolvedSources,
            locations: locations,
            messages: messages
        )
    }


    private func failedSourceRescan(
        _ sourceID: UUID,
        generation: UInt64,
        state: PersistedState,
        message: String
    ) throws -> CatalogTransaction {
        guard self.generation.isCurrentSourceRescan(sourceID: sourceID, generation: generation) else {
            throw CancellationError()
        }
        var messages = scanMessages
        messages[sourceID] = "Scan failed: \(message)"
        let change = catalogState.makeChange(state: state, scanMessages: messages, effect: .scanFailed)
        return CatalogTransaction(change: change, persistenceOrder: .acceptanceOnly)
    }

    private func isCurrentFullRescan(_ generation: UInt64?) -> Bool {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { return false }
        guard let generation else { return true }
        return self.generation.isCurrentFullRescan(generation)
    }
}
