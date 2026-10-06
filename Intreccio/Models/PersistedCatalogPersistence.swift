import Foundation
nonisolated enum PersistedCatalogBudgetError: Error, Sendable, CustomStringConvertible {
    case entryCountExceeded
    case encodedSizeExceeded

    var description: String {
        switch self {
        case .entryCountExceeded:
            "catalog entry count exceeds \(PersistedCatalogBudget.maxEntryCount)"
        case .encodedSizeExceeded:
            "encoded catalog size exceeds \(PersistedCatalogBudget.maxEncodedBytes) bytes"
        }
    }
}

/// Hard limits for the persisted catalog document. The entry limit applies to
/// the combined watch-root, standalone-repository, and repository-snapshot arrays.
/// The encoded-size limit bounds the input Data retained while decoding.
nonisolated enum PersistedCatalogBudget {
    static let maxEntryCount = 10_000
    static let maxEncodedBytes = 4 * 1024 * 1024

    static func validate(_ state: PersistedState) throws {
        var entryCount = 0
        for count in [state.watchRoots.count, state.standaloneRepos.count, state.repoSnapshots.count] {
            guard count <= maxEntryCount - entryCount else {
                throw PersistedCatalogBudgetError.entryCountExceeded
            }
            entryCount += count
        }
    }
    static func remainingCandidateCapacity(
        for state: PersistedState,
        additionalSourceCount: Int = 0
    ) throws -> Int {
        try validate(state)
        let sourceCount = state.watchRoots.count + state.standaloneRepos.count
        guard additionalSourceCount >= 0,
              additionalSourceCount <= maxEntryCount - sourceCount else {
            throw PersistedCatalogBudgetError.entryCountExceeded
        }
        return maxEntryCount - sourceCount - additionalSourceCount
    }

    static func validateEncodedSize(_ byteCount: Int) throws {
        guard byteCount <= maxEncodedBytes else {
            throw PersistedCatalogBudgetError.encodedSizeExceeded
        }
    }
}

nonisolated struct PersistedCatalogDecodeBudget {
    private var remainingEntryCount = PersistedCatalogBudget.maxEntryCount

    mutating func decode<T: Decodable, Key: CodingKey>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        optional: Bool
    ) throws -> [T] {
        if optional {
            guard container.contains(key), try !container.decodeNil(forKey: key) else {
                return []
            }
        }

        var values = try container.nestedUnkeyedContainer(forKey: key)
        if let count = values.count, count > remainingEntryCount {
            throw PersistedCatalogBudgetError.entryCountExceeded
        }
        var decoded: [T] = []
        if let count = values.count {
            decoded.reserveCapacity(count)
        }
        while !values.isAtEnd {
            guard remainingEntryCount > 0 else {
                throw PersistedCatalogBudgetError.entryCountExceeded
            }
            decoded.append(try values.decode(T.self))
            remainingEntryCount -= 1
        }
        return decoded
    }
}
