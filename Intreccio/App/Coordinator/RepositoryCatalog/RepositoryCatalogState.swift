import Foundation

struct CatalogRepositoryFilter: Sendable, Equatable {
    let sourceID: UUID
    let folder: String
    let caseSensitive: Bool

    func removes(_ repository: RepoDescriptor) -> Bool {
        repository.source.id == sourceID
            && RepositoryPathPolicy.isWithin(
                relativePath: repository.relativePath,
                folder: folder,
                caseSensitive: caseSensitive
            )
    }
}

@MainActor
final class RepositoryCatalogState {
    private(set) var sourceScans: [UUID: RepoScanResult] = [:]
    private(set) var standaloneRepositories: [UUID: StandaloneRepositoryLocation] = [:]
    private(set) var repositories: [RepoDescriptor] = []
    private(set) var repositoryIndex: RepositoryCatalogIndex
    private(set) var scanMessages: [UUID: String] = [:]

    init(fixture: RepositoryCatalogFixture?) {
        let initialRepositories = fixture?.repositories ?? []
        repositories = initialRepositories
        repositoryIndex = RepositoryCatalogIndex(repositories: initialRepositories)
    }

    func makeChange(
        state: PersistedState,
        sourceScans: [UUID: RepoScanResult]? = nil,
        standaloneRepositories: [UUID: StandaloneRepositoryLocation]? = nil,
        scanMessages: [UUID: String]? = nil,
        snapshotGitDirectoryInfos: [UUID: GitDirectoryInfo] = [:],
        effect: CatalogEffectPlan,
        repositoryFilter: CatalogRepositoryFilter? = nil
    ) -> CatalogChange {
        let scans = sourceScans ?? self.sourceScans
        let standaloneRepositories = standaloneRepositories ?? self.standaloneRepositories
        let rebuilt = RepositoryCatalogRebuilder.rebuild(
            state: state,
            sourceScans: scans,
            standaloneRepositories: standaloneRepositories,
            previousRepositories: self.repositories,
            snapshotGitDirectoryInfos: snapshotGitDirectoryInfos
        )
        var repositories = rebuilt.repositories
        if let repositoryFilter {
            repositories.removeAll(where: repositoryFilter.removes)
        }
        var persisted = state
        persisted.repoSnapshots = rebuilt.snapshots
        let repositoryIDs = Set(repositories.map(\.id))
        CatalogRepositoryUIReconciliation.removeMissingRepositories(
            from: &persisted.uiState,
            repositoryIDs: repositoryIDs
        )
        return CatalogChange(
            state: persisted,
            sourceScans: scans,
            standaloneRepositories: standaloneRepositories,
            repositories: repositories,
            scanMessages: scanMessages ?? self.scanMessages,
            effect: effect
        )
    }

    func accept(_ change: CatalogChange) {
        sourceScans = change.sourceScans
        standaloneRepositories = change.standaloneRepositories
        repositories = change.repositories
        repositoryIndex = RepositoryCatalogIndex(repositories: repositories)
        scanMessages = change.scanMessages
    }
}
