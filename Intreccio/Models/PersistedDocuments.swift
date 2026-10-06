import Foundation
nonisolated struct PersistedCatalogState: Codable, Sendable, Equatable {
    static let currentSchemaVersion = PersistedState.currentSchemaVersion
    static let documentType = "catalog"

    private enum CodingKeys: String, CodingKey {
        case documentType
        case schemaVersion
        case watchRoots
        case standaloneRepos
        case repoSnapshots
    }

    let documentType: String
    let schemaVersion: Int
    var watchRoots: [WatchRoot]
    var standaloneRepos: [StandaloneRepository]
    var repoSnapshots: [RepositorySnapshot]

    init(_ state: PersistedState) {
        documentType = Self.documentType
        schemaVersion = state.schemaVersion
        watchRoots = state.watchRoots
        standaloneRepos = state.standaloneRepos
        repoSnapshots = state.repoSnapshots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentType = try container.decode(String.self, forKey: .documentType)
        guard documentType == Self.documentType else {
            throw DecodingError.dataCorruptedError(
                forKey: .documentType,
                in: container,
                debugDescription: "Unexpected persisted document type."
            )
        }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        var budget = PersistedCatalogDecodeBudget()
        watchRoots = try budget.decode(
            WatchRoot.self,
            from: container,
            forKey: .watchRoots,
            optional: true
        )
        standaloneRepos = try budget.decode(
            StandaloneRepository.self,
            from: container,
            forKey: .standaloneRepos,
            optional: true
        )
        repoSnapshots = try budget.decode(
            RepositorySnapshot.self,
            from: container,
            forKey: .repoSnapshots,
            optional: true
        )
    }

    func state(with uiState: PersistedUIState) -> PersistedState {
        PersistedState(
            schemaVersion: schemaVersion,
            watchRoots: watchRoots,
            standaloneRepos: standaloneRepos,
            repoSnapshots: repoSnapshots,
            uiState: uiState
        )
    }
}

nonisolated struct PersistedUIStateDocument: Codable, Sendable, Equatable {
    static let currentSchemaVersion = PersistedState.currentSchemaVersion
    static let documentType = "uiState"

    private enum CodingKeys: String, CodingKey {
        case documentType
        case schemaVersion
        case uiState
    }

    let documentType: String
    let schemaVersion: Int
    var uiState: PersistedUIState

    init(_ uiState: PersistedUIState) {
        documentType = Self.documentType
        schemaVersion = Self.currentSchemaVersion
        self.uiState = uiState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentType = try container.decode(String.self, forKey: .documentType)
        guard documentType == Self.documentType else {
            throw DecodingError.dataCorruptedError(
                forKey: .documentType,
                in: container,
                debugDescription: "Unexpected persisted document type."
            )
        }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        uiState = try container.decode(PersistedUIState.self, forKey: .uiState)
    }
}
nonisolated enum PersistedDocumentEnvelope: Decodable {
    case catalog(PersistedCatalogState)
    case legacy(PersistedState)
    case ui(PersistedUIStateDocument)
    case unsupportedSchema(Int)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case documentType
    }

    init(from decoder: Decoder) throws {
        let header = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try header.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == PersistedState.currentSchemaVersion else {
            self = .unsupportedSchema(schemaVersion)
            return
        }

        if header.contains(.documentType) {
            switch try header.decode(String.self, forKey: .documentType) {
            case PersistedCatalogState.documentType:
                self = .catalog(try PersistedCatalogState(from: decoder))
            case PersistedUIStateDocument.documentType:
                self = .ui(try PersistedUIStateDocument(from: decoder))
            default:
                throw PersistedDocumentEnvelopeError.unexpectedDocumentType
            }
        } else {
            self = .legacy(try PersistedState(from: decoder))
        }
    }
}

nonisolated enum PersistedDocumentEnvelopeError: Error, Sendable, CustomStringConvertible {
    case unexpectedDocumentType

    var description: String {
        switch self {
        case .unexpectedDocumentType: "Unexpected persisted document type."
        }
    }
}
