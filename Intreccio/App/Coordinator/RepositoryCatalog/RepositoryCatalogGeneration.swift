import Foundation

@MainActor
final class RepositoryCatalogGeneration {
    let lifecycle: RepositoryCatalogLifecycle
    var fullRescanGeneration: UInt64 = 0
    var sourceRefreshGenerations: [UUID: UInt64] = [:]

    init(lifecycle: RepositoryCatalogLifecycle) {
        self.lifecycle = lifecycle
    }

    func beginFullRescan() -> UInt64 {
        fullRescanGeneration &+= 1
        return fullRescanGeneration
    }

    func beginSourceRescan(_ sourceID: UUID) -> UInt64 {
        sourceRefreshGenerations[sourceID, default: 0] &+= 1
        return sourceRefreshGenerations[sourceID]!
    }

    func isCurrentFullRescan(_ generation: UInt64) -> Bool {
        !lifecycle.isShuttingDown && fullRescanGeneration == generation && !Task.isCancelled
    }

    func isCurrentSourceRescan(sourceID: UUID, generation: UInt64) -> Bool {
        !lifecycle.isShuttingDown
            && sourceRefreshGenerations[sourceID] == generation
            && !Task.isCancelled
    }

    func invalidateForShutdown() {
        fullRescanGeneration &+= 1
        for sourceID in sourceRefreshGenerations.keys {
            sourceRefreshGenerations[sourceID, default: 0] &+= 1
        }
    }

    func cancelSourceRescan(_ sourceID: UUID) {
        sourceRefreshGenerations[sourceID, default: 0] &+= 1
    }
}
