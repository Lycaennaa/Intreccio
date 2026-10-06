import Foundation
@testable import Intreccio

@MainActor
func makeOperations(
        watchRootScan: @escaping @MainActor @Sendable (WatchRoot) async throws -> RepositoryWatchRootScanOutcome,
        bookmarkStore: BookmarkStore = BookmarkStore(),
        gitService: GitService = GitService()
    ) -> (RepositoryCatalogSourceOperations, RepositoryCatalogState) {
        let catalogState = RepositoryCatalogState(fixture: nil)
        let lifecycle = RepositoryCatalogLifecycle()
        let scanner = RepoScanner(gitService: gitService)
        let resolver = RepositorySourceResolver(
            bookmarkStore: bookmarkStore,
            scanner: scanner,
            gitService: gitService
        )
        let operations = RepositoryCatalogSourceOperations(
            catalogState: catalogState,
            bookmarkStore: bookmarkStore,
            gitService: gitService,
            sourceResolver: resolver,
            lifecycle: lifecycle,
            generation: RepositoryCatalogGeneration(lifecycle: lifecycle),
            watchRootScanOperation: watchRootScan
        )
        return (operations, catalogState)
    }

struct ScanTestError: Error, CustomStringConvertible, Sendable {
    let message: String

    var description: String { message }
}

func makeWatchRoots(count: Int) -> [WatchRoot] {
    (0..<count).map { index in
        WatchRoot(
            id: UUID(),
            displayName: "source-\(index)",
            bookmarkData: Data("bookmark-\(index)".utf8),
            lastResolvedPath: "/watch-root-\(index)",
            resourceID: nil,
            exclusions: []
        )
    }
}

func successfulResolution(source: WatchRoot, index: Int) -> RepositoryWatchRootScanOutcome {
    var resolvedSource = source
    resolvedSource.displayName = "resolved-\(index)"
    resolvedSource.resourceID = "resource-\(index)"
    let repositoryURL = URL(fileURLWithPath: "/repository-\(index)", isDirectory: true)
    let result = RepoScanResult(
        repositories: [ScannedRepository(
            url: repositoryURL,
            canonicalURL: repositoryURL,
            relativePath: "repository-\(index)",
            resourceID: "repository-\(index)"
        )],
        warnings: [],
        incompleteReason: nil,
        visitedDirectoryCount: 1,
        duration: .zero
    )
    return .success(source: resolvedSource, result: result)
}

func failedResolution(source: WatchRoot, message: String) -> RepositoryWatchRootScanOutcome {
    var resolvedSource = source
    resolvedSource.displayName = "resolved-1"
    resolvedSource.resourceID = "resource-1"
    return .scanFailure(source: resolvedSource, message: message)
}

actor ScanProbe {
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startedIDs: [UUID] = []
    private var completedIDs: Set<UUID> = []
    private var releasedIDs: Set<UUID> = []
    private var releaseAllRequested = false
    private var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completedWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func recordStart(_ id: UUID) {
        startedIDs.append(id)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        let ready = startedWaiters.filter { $0.0 <= startedIDs.count }
        startedWaiters.removeAll { $0.0 <= startedIDs.count }
        ready.forEach { $0.1.resume() }
    }

    func recordFinish(_ id: UUID) {
        activeCount -= 1
        completedIDs.insert(id)
        completedWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
    }

    func waitForStarted(count: Int) async {
        guard startedIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func waitForCompleted(_ id: UUID) async {
        guard !completedIDs.contains(id) else { return }
        await withCheckedContinuation { continuation in
            completedWaiters[id, default: []].append(continuation)
        }
    }

    func waitUntilReleased(_ id: UUID) async {
        guard !releaseAllRequested, !releasedIDs.contains(id) else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[id, default: []].append(continuation)
        }
    }

    func release(_ id: UUID) {
        releasedIDs.insert(id)
        releaseWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
    }

    func releaseAll() {
        releaseAllRequested = true
        let waiters = releaseWaiters.values.flatMap { $0 }
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func stats() -> (maximumActive: Int, startedCount: Int) {
        (maximumActiveCount, startedIDs.count)
    }
}
actor StandaloneGitProbe {
    private let failingPaths: Set<String>
    private var pending: [String: CheckedContinuation<ProcessCommandResult, Error>] = [:]
    private var startedPaths: [String] = []
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startedWaiters: [(Set<String>, CheckedContinuation<Void, Never>)] = []

    init(failingPaths: Set<String>) {
        self.failingPaths = failingPaths
    }

    func execute(
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        timeout: Duration,
        priority: ProcessPriority
    ) async throws -> ProcessCommandResult {
        guard let repository else {
            throw ScanTestError(message: "missing repository")
        }
        let path = repository.path
        startedPaths.append(path)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        let started = Set(startedPaths)
        let ready = startedWaiters.filter { $0.0.isSubset(of: started) }
        startedWaiters.removeAll { $0.0.isSubset(of: started) }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[path] = continuation
        }
    }
    func executeStreaming(
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        timeout: Duration,
        priority: ProcessPriority,
        progress: @escaping @Sendable (ProcessOutputStream, Data) -> Void,
        control: ProcessControl?
    ) async throws -> ProcessCommandResult {
        try await execute(
            repository: repository,
            arguments: arguments,
            input: input,
            environment: environment,
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            priority: priority
        )
    }

    func waitForStarted(paths: Set<String>) async {
        let started = Set(startedPaths)
        guard !paths.isSubset(of: started) else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((paths, continuation))
        }
    }

    func release(_ path: String) {
        guard let continuation = pending.removeValue(forKey: path) else { return }
        activeCount -= 1
        if failingPaths.contains(path) {
            continuation.resume(throwing: GitRunnerError.nonZeroExit(
                recordedGitResult(error: "root failed", exitCode: 128)
            ))
        } else {
            continuation.resume(returning: recordedGitResult(output: "\(path)\n"))
        }
    }

    func stats() -> (maximumActive: Int, startedCount: Int) {
        (maximumActiveCount, startedPaths.count)
    }
}

extension StandaloneGitProbe: ProcessRunning {}

@MainActor
final class CatalogCommandDelegate: RepositoryCatalogDelegate {
    var repositoryCatalogState = PersistedState()
    var reconcileCount = 0
    var failures: [RepositoryCatalogFailure] = []

    func repositoryCatalogWillBeginSourceCommand() {}

    func repositoryCatalog(didLoad result: StateLoadResult) -> PersistedState? {
        result.state
    }

    func repositoryCatalog(reconcile change: CatalogChange) -> PersistedState {
        reconcileCount += 1
        repositoryCatalogState = change.state
        return repositoryCatalogState
    }

    func repositoryCatalog(didCommit result: CatalogCommitResult) async {}

    func repositoryCatalog(didFail failure: RepositoryCatalogFailure) {
        failures.append(failure)
    }
}