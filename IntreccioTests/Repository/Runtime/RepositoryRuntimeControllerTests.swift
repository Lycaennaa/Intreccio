import AppKit
import Foundation
import XCTest
@testable import Intreccio

@MainActor
final class RuntimeTestDelegate: RepositoryRuntimeControllerDelegate {
    var state: PersistedState
    var repositories: [RepoDescriptor] {
        didSet {
            repositoryIndex = RepositoryCatalogIndex(repositories: repositories)
        }
    }
    var repositoryIndex: RepositoryCatalogIndex
    var isShuttingDown = false
    var changes: [RepositoryRuntimeChange] = []
    var statusWasPublishedAfterSnapshotUpdate = false

    init(state: PersistedState = PersistedState(), repositories: [RepoDescriptor]) {
        self.state = state
        self.repositories = repositories
        repositoryIndex = RepositoryCatalogIndex(repositories: repositories)
    }

    var repositoryRuntimeContext: RepositoryRuntimeContext {
        RepositoryRuntimeContext(
            state: state,
            repositories: repositories,
            isShuttingDown: isShuttingDown,
            repositoryIndex: repositoryIndex
        )
    }

    func repositoryRuntimeController(
        _ controller: RepositoryRuntimeController,
        didChange change: RepositoryRuntimeChange
    ) {
        if case .status = change {
            statusWasPublishedAfterSnapshotUpdate = controller.snapshot.refreshStates.values.contains {
                $0.statusGeneration > 0
            }
        }
        changes.append(change)
    }
}

actor GitHubLookupContinuationProbe {
    private var continuations: [URL: [CheckedContinuation<URL?, Never>]] = [:]
    private var callCounts: [URL: Int] = [:]

    func lookup(_ repository: URL) async -> URL? {
        callCounts[repository, default: 0] += 1
        return await withCheckedContinuation { continuation in
            continuations[repository, default: []].append(continuation)
        }
    }

    func callCount(for repository: URL) -> Int {
        callCounts[repository, default: 0]
    }

    func finishNext(for repository: URL, with result: URL?) {
        guard var pending = continuations[repository], !pending.isEmpty else { return }
        let continuation = pending.removeFirst()
        continuations[repository] = pending
        continuation.resume(returning: result)
    }
}

actor ImmediateGitHubLookupProbe {
    private var callCounts: [URL: Int] = [:]

    func lookup(_ repository: URL) async -> URL? {
        callCounts[repository, default: 0] += 1
        return URL(string: "https://github.com/cache/\(repository.lastPathComponent)")
    }

    func callCount(for repository: URL) -> Int {
        callCounts[repository, default: 0]
    }
}

actor CancellableGitHubLookupProbe {
    private var startedRepositories = Set<URL>()
    private var cancellationCount = 0

    func lookup(_ repository: URL) async throws -> URL? {
        startedRepositories.insert(repository)
        do {
            try await Task.sleep(for: .seconds(10))
            return nil
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }

    func hasStarted(_ repository: URL) -> Bool {
        startedRepositories.contains(repository)
    }

    func cancellationCountValue() -> Int {
        cancellationCount
    }
}

func makeRuntimeRepository(id: UUID = UUID(), path: String) -> RepoDescriptor {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    return RepoDescriptor(
        id: id,
        source: .standalone(id: id),
        url: url,
        canonicalURL: url,
        resourceID: nil,
        relativePath: nil,
        availability: .available
    )
}

@MainActor
func historyInvalidation(in changes: [RepositoryRuntimeChange]) -> Bool? {
    guard let change = changes.last else { return nil }
    guard case .status(_, let invalidated) = change else { return nil }
    return invalidated
}

@MainActor
final class RepositoryRuntimeControllerTests: XCTestCase {
}