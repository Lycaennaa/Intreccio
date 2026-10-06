import Foundation

nonisolated struct SourceRepositoryFileEventSlice: Sendable {
    let events: [SourceRepositoryFileEvent]
    let rawBatch: FileEventBatch
    let caseSensitiveVolume: Bool
    let generation: UInt64
}

nonisolated struct SourceRepositoryFileEventGroupPartition: Sendable {
    let slicesBySourceID: [UUID: SourceRepositoryFileEventSlice]
    let normalizedPathCount: Int
}

nonisolated final class SourceRepositoryFileEventGroupRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceIndexes: [UUID: SourceRepositoryPathIndex]
    private var generation: UInt64 = 0

    init(sourceIndexes: [UUID: SourceRepositoryPathIndex]) {
        self.sourceIndexes = sourceIndexes
    }

    func update(sourceIndexes: [UUID: SourceRepositoryPathIndex]) {
        lock.lock()
        self.sourceIndexes = sourceIndexes
        generation &+= 1
        lock.unlock()
    }

    func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expectedGeneration
    }
    func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func partition(_ events: [FileSystemEvent]) -> SourceRepositoryFileEventGroupPartition {
        let configuration: ([UUID: SourceRepositoryPathIndex], UInt64) = {
            lock.lock()
            defer { lock.unlock() }
            return (sourceIndexes, generation)
        }()
        let sharedBatch = FileEventBatch(
            paths: Set(events.map(\.path)),
            sourceRescanPaths: Set(events.filter(\.requiresSourceRescan).map(\.path)),
            requiresFullRescan: events.contains(where: \.requiresFullRescan),
            hasUnrepresentedChanges: events.contains(where: \.hasUnrepresentedChanges)
        )
        let needsCaseInsensitivePaths = configuration.0.values.contains { !$0.caseSensitiveVolume }
        let normalizedBatch = SourceRepositoryNormalizedFileEventBatch(
            sharedBatch,
            needsCaseInsensitivePaths: needsCaseInsensitivePaths
        )
        let slices = configuration.0.mapValues { index in
            let events = index.partition(normalizedBatch)
            let sourceBatch = FileEventBatch(
                paths: Set(events.map(\.eventPath.path)),
                sourceRescanPaths: Set(events.filter(\.eventPath.isSourceRescan).map(\.eventPath.path)),
                requiresFullRescan: sharedBatch.requiresFullRescan,
                hasUnrepresentedChanges: sharedBatch.hasUnrepresentedChanges
            )
            return SourceRepositoryFileEventSlice(
                events: events,
                rawBatch: sourceBatch,
                caseSensitiveVolume: index.caseSensitiveVolume,
                generation: configuration.1
            )
        }
        return SourceRepositoryFileEventGroupPartition(
            slicesBySourceID: slices,
            normalizedPathCount: normalizedBatch.normalizedPathCount
        )
    }
}