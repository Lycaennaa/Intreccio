import Foundation

nonisolated struct WatchRoot: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
    var lastResolvedPath: String
    var resourceID: String?
    var exclusions: [String]
}

nonisolated struct StandaloneRepository: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
    var lastResolvedPath: String
    var resourceID: String?
}

nonisolated enum RepositorySource: Sendable, Equatable {
    case watchRoot(id: UUID, name: String, path: String)
    case standalone(id: UUID)

    var id: UUID {
        switch self {
        case .watchRoot(let id, _, _), .standalone(let id): id
        }
    }
}

nonisolated enum ResourceIdentity {
    static func read(from url: URL) -> String? {
        if let value = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            if let data = value as? Data { return data.base64EncodedString() }
            if let data = value as? NSData { return Data(referencing: data).base64EncodedString() }
            return String(describing: value)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device.stringValue):\(fileNumber.stringValue)"
    }
}
