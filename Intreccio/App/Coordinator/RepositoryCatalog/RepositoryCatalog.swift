import Foundation

nonisolated struct RepositoryCatalogIndex: Sendable {
    private let repositoriesByID: [UUID: RepoDescriptor]
    private let repositoryOrderByID: [UUID: Int]
    private let sourceIDs: Set<UUID>

    init(repositories: [RepoDescriptor]) {
        var repositoriesByID: [UUID: RepoDescriptor] = [:]
        var repositoryOrderByID: [UUID: Int] = [:]
        var sourceIDs = Set<UUID>()
        for repository in repositories {
            sourceIDs.insert(repository.source.id)
        }
        for (order, repository) in Self.firstRepositories(repositories).enumerated() {
            repositoriesByID[repository.id] = repository
            repositoryOrderByID[repository.id] = order
        }
        self.repositoriesByID = repositoriesByID
        self.repositoryOrderByID = repositoryOrderByID
        self.sourceIDs = sourceIDs
    }

    static func firstRepositories(_ repositories: [RepoDescriptor]) -> [RepoDescriptor] {
        var seen = Set<UUID>()
        return repositories.filter { seen.insert($0.id).inserted }
    }

    func repository(for id: UUID) -> RepoDescriptor? {
        repositoriesByID[id]
    }

    func availableRepositories(for ids: Set<UUID>) -> [RepoDescriptor] {
        let matching = ids.compactMap { id -> (order: Int, repository: RepoDescriptor)? in
            guard let repository = repositoriesByID[id],
                  repository.availability == .available,
                  let order = repositoryOrderByID[id] else { return nil }
            return (order, repository)
        }
        return matching.sorted { $0.order < $1.order }.map(\.repository)
    }

    func containsRepository(from sourceID: UUID) -> Bool {
        sourceIDs.contains(sourceID)
    }
}

@MainActor
protocol RepositoryCatalogDelegate: AnyObject {
    var repositoryCatalogState: PersistedState { get }

    func repositoryCatalogWillBeginSourceCommand()

    func repositoryCatalog(didLoad result: StateLoadResult) -> PersistedState?

    func repositoryCatalog(reconcile change: CatalogChange) -> PersistedState

    func repositoryCatalog(didCommit result: CatalogCommitResult) async

    func repositoryCatalog(didFail failure: RepositoryCatalogFailure)
}

nonisolated struct CatalogChange: Sendable {
    let state: PersistedState
    let sourceScans: [UUID: RepoScanResult]
    let standaloneRepositories: [UUID: StandaloneRepositoryLocation]
    let repositories: [RepoDescriptor]
    let scanMessages: [UUID: String]
    let effect: CatalogEffectPlan

    var repositoryIDs: Set<UUID> { Set(repositories.map(\.id)) }

    func replacing(effect: CatalogEffectPlan) -> CatalogChange {
        CatalogChange(
            state: state,
            sourceScans: sourceScans,
            standaloneRepositories: standaloneRepositories,
            repositories: repositories,
            scanMessages: scanMessages,
            effect: effect
        )
    }
}

@MainActor
enum CatalogCommandOutcome {
    case changed
    case createdRepository(URL)
    case selectedRepository(UUID)
    case noChange
}

nonisolated enum RepositoryCatalogFailure: Sendable {
    case sourcesPersistence(String)
    case sourceRescanPersistence(String)
}

struct RepositoryCatalogFixture {
    let repositories: [RepoDescriptor]
}
