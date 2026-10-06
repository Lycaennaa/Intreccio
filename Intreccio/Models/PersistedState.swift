import Foundation

nonisolated enum AppMode: String, Codable, Sendable {
    case changes
    case history
}



nonisolated struct PersistedState: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case watchRoots
        case standaloneRepos
        case repoSnapshots
        case uiState
    }

    var schemaVersion = PersistedState.currentSchemaVersion
    var watchRoots: [WatchRoot] = []
    var standaloneRepos: [StandaloneRepository] = []
    var repoSnapshots: [RepositorySnapshot] = []
    var uiState = PersistedUIState()

    init(
        schemaVersion: Int = PersistedState.currentSchemaVersion,
        watchRoots: [WatchRoot] = [],
        standaloneRepos: [StandaloneRepository] = [],
        repoSnapshots: [RepositorySnapshot] = [],
        uiState: PersistedUIState = PersistedUIState()
    ) {
        self.schemaVersion = schemaVersion
        self.watchRoots = watchRoots
        self.standaloneRepos = standaloneRepos
        self.repoSnapshots = repoSnapshots
        self.uiState = uiState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        var budget = PersistedCatalogDecodeBudget()
        watchRoots = try budget.decode(
            WatchRoot.self,
            from: container,
            forKey: .watchRoots,
            optional: false
        )
        standaloneRepos = try budget.decode(
            StandaloneRepository.self,
            from: container,
            forKey: .standaloneRepos,
            optional: false
        )
        repoSnapshots = try budget.decode(
            RepositorySnapshot.self,
            from: container,
            forKey: .repoSnapshots,
            optional: false
        )
        uiState = try container.decode(PersistedUIState.self, forKey: .uiState)
    }
}

