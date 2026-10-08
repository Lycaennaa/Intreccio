import Foundation

nonisolated enum RepositoryCatalogScanError: Error, Sendable, Equatable, CustomStringConvertible {
    case candidateBudgetExceeded(limit: Int)

    var description: String {
        switch self {
        case .candidateBudgetExceeded(let limit):
            "Catalog scan exceeded remaining catalog capacity of \(limit) repository entries."
        }
    }
}

@MainActor
final class RepositoryCatalogSourceScanner {
    private struct IndexedOutcome: Sendable {
        let index: Int
        let outcome: RepositoryWatchRootScanOutcome
    }

    private let operation: @MainActor @Sendable (WatchRoot) async throws -> RepositoryWatchRootScanOutcome
    private let generation: RepositoryCatalogGeneration
    private let lifecycle: RepositoryCatalogLifecycle

    init(
        operation: @escaping @MainActor @Sendable (WatchRoot) async throws -> RepositoryWatchRootScanOutcome,
        generation: RepositoryCatalogGeneration,
        lifecycle: RepositoryCatalogLifecycle
    ) {
        self.operation = operation
        self.generation = generation
        self.lifecycle = lifecycle
    }

    func scanWatchRoots(
        _ sources: [WatchRoot],
        generation: UInt64?,
        candidateLimit: Int? = nil
    ) async throws -> [RepositoryWatchRootScanOutcome] {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else {
            throw CancellationError()
        }
        guard !sources.isEmpty else { return [] }
        guard isCurrentFullRescan(generation) else { throw CancellationError() }
        try Self.validateCandidateLimit(candidateLimit)

        let operation = operation
        return try await withThrowingTaskGroup(of: IndexedOutcome.self) { group in
            defer { group.cancelAll() }
            var outcomes = [RepositoryWatchRootScanOutcome?](
                repeating: nil,
                count: sources.count
            )
            var candidateCount = 0
            var nextIndex = 0
            let initialCount = min(RepoScanner.maximumConcurrentScans, sources.count)

            while nextIndex < initialCount {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    try await Self.scanWatchRoot(
                        index: index,
                        source: sources[index],
                        operation: operation
                    )
                }
            }

            while let indexedOutcome = try await group.next() {
                guard isCurrentFullRescan(generation) else {
                    throw CancellationError()
                }
                try Self.collectCandidates(
                    from: indexedOutcome.outcome,
                    candidateCount: &candidateCount,
                    candidateLimit: candidateLimit
                )
                outcomes[indexedOutcome.index] = indexedOutcome.outcome
                guard nextIndex < sources.count else { continue }
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    try await Self.scanWatchRoot(
                        index: index,
                        source: sources[index],
                        operation: operation
                    )
                }
            }

            return try outcomes.map { outcome in
                guard let outcome else { throw CancellationError() }
                return outcome
            }
        }
    }

    func scanWatchRoot(
        _ source: WatchRoot,
        candidateLimit: Int? = nil
    ) async throws -> RepositoryWatchRootScanOutcome {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else {
            throw CancellationError()
        }
        try Self.validateCandidateLimit(candidateLimit)
        let operation = operation
        let indexedOutcome = try await Self.scanWatchRoot(
            index: 0,
            source: source,
            operation: operation
        )
        guard !Task.isCancelled, !lifecycle.isShuttingDown else {
            throw CancellationError()
        }
        var candidateCount = 0
        try Self.collectCandidates(
            from: indexedOutcome.outcome,
            candidateCount: &candidateCount,
            candidateLimit: candidateLimit
        )
        return indexedOutcome.outcome
    }

    private static func validateCandidateLimit(_ candidateLimit: Int?) throws {
        if let candidateLimit, candidateLimit < 0 {
            throw RepositoryCatalogScanError.candidateBudgetExceeded(limit: candidateLimit)
        }
    }

    private static func collectCandidates(
        from outcome: RepositoryWatchRootScanOutcome,
        candidateCount: inout Int,
        candidateLimit: Int?
    ) throws {
        guard let candidateLimit,
              case .success(_, let result) = outcome else { return }
        guard result.repositories.count <= candidateLimit - candidateCount else {
            throw RepositoryCatalogScanError.candidateBudgetExceeded(limit: candidateLimit)
        }
        candidateCount += result.repositories.count
    }

    private static func scanWatchRoot(
        index: Int,
        source: WatchRoot,
        operation: @escaping @MainActor @Sendable (WatchRoot) async throws -> RepositoryWatchRootScanOutcome
    ) async throws -> IndexedOutcome {
        try Task.checkCancellation()
        let outcome: RepositoryWatchRootScanOutcome
        do {
            outcome = try await operation(source)
            try Task.checkCancellation()
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else {
                throw CancellationError()
            }
            return IndexedOutcome(
                index: index,
                outcome: .accessFailure(source: source, message: String(describing: error))
            )
        }
        return IndexedOutcome(index: index, outcome: outcome)
    }

    private func isCurrentFullRescan(_ generation: UInt64?) -> Bool {
        guard !Task.isCancelled, !lifecycle.isShuttingDown else { return false }
        guard let generation else { return true }
        return self.generation.isCurrentFullRescan(generation)
    }
}
