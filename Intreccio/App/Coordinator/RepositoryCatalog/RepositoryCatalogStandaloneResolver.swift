import Foundation

@MainActor
final class RepositoryCatalogStandaloneResolver {
    private struct IndexedStandaloneResolution: Sendable {
        let index: Int
        let resolution: RepositoryStandaloneResolution
    }

    private let sourceResolver: RepositorySourceResolver
    private let lifecycle: RepositoryCatalogLifecycle
    private let generation: RepositoryCatalogGeneration

    init(
        sourceResolver: RepositorySourceResolver,
        lifecycle: RepositoryCatalogLifecycle,
        generation: RepositoryCatalogGeneration
    ) {
        self.sourceResolver = sourceResolver
        self.lifecycle = lifecycle
        self.generation = generation
    }

    func resolveStandalone(_ source: StandaloneRepository) async throws -> RepositoryStandaloneResolution {
        try await sourceResolver.resolveStandalone(source)
    }

    func resolveStandalones(
        _ sources: [StandaloneRepository],
        generation: UInt64?
    ) async throws -> [RepositoryStandaloneResolution] {
        guard isCurrentFullRescan(generation) else { throw CancellationError() }
        guard !sources.isEmpty else { return [] }

        let sourceResolver = sourceResolver
        let operation: @MainActor @Sendable (StandaloneRepository) async throws -> RepositoryStandaloneResolution = {
            source in
            try await sourceResolver.resolveStandalone(source)
        }
        return try await withThrowingTaskGroup(of: IndexedStandaloneResolution.self) { group in
            defer { group.cancelAll() }
            var resolutions = Array<RepositoryStandaloneResolution?>(
                repeating: nil,
                count: sources.count
            )
            var nextIndex = 0
            let initialCount = min(RepoScanner.maximumConcurrentScans, sources.count)

            while nextIndex < initialCount {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    try await Self.resolveStandalone(
                        index: index,
                        source: sources[index],
                        operation: operation
                    )
                }
            }

            while let indexedResolution = try await group.next() {
                resolutions[indexedResolution.index] = indexedResolution.resolution
                guard isCurrentFullRescan(generation) else {
                    throw CancellationError()
                }
                guard nextIndex < sources.count else { continue }
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    try await Self.resolveStandalone(
                        index: index,
                        source: sources[index],
                        operation: operation
                    )
                }
            }

            return try resolutions.map { resolution in
                guard let resolution else { throw CancellationError() }
                return resolution
            }
        }
    }

    private static func resolveStandalone(
        index: Int,
        source: StandaloneRepository,
        operation: @escaping @MainActor @Sendable (StandaloneRepository) async throws -> RepositoryStandaloneResolution
    ) async throws -> IndexedStandaloneResolution {
        try Task.checkCancellation()
        let resolution = try await operation(source)
        try Task.checkCancellation()
        return IndexedStandaloneResolution(index: index, resolution: resolution)
    }

    private func isCurrentFullRescan(_ generation: UInt64?) -> Bool {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { return false }
        guard let generation else { return true }
        return self.generation.isCurrentFullRescan(generation)
    }
}