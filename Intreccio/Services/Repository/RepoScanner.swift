import Foundation

private nonisolated final class RepoScanWarningCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ warning: String) {
        lock.withLock {
            if values.count < 100 { values.append(warning) } else if values.count == 100 { values.append("Additional scan warnings omitted.") }
        }
    }

    var warnings: [String] {
        lock.withLock { values }
    }
}

nonisolated struct ScannedRepository: Sendable, Equatable {
    let url: URL
    let canonicalURL: URL
    let relativePath: String
    let resourceID: String?
    let gitDirectoryInfo: GitDirectoryInfo?
    let submoduleParentCanonicalURL: URL?
    let submodulePath: String?
    let hasSubmodules: Bool

    init(
        url: URL,
        canonicalURL: URL,
        relativePath: String,
        resourceID: String?,
        gitDirectoryInfo: GitDirectoryInfo? = nil,
        submoduleParentCanonicalURL: URL? = nil,
        submodulePath: String? = nil,
        hasSubmodules: Bool = false
    ) {
        self.url = url
        self.canonicalURL = canonicalURL
        self.relativePath = relativePath
        self.resourceID = resourceID
        self.gitDirectoryInfo = gitDirectoryInfo
        self.submoduleParentCanonicalURL = submoduleParentCanonicalURL
        self.submodulePath = submodulePath
        self.hasSubmodules = hasSubmodules
    }
}

nonisolated struct ScannedSubmodules: Sendable {
    let repositories: [ScannedRepository]
    let hasConfiguredSubmodules: Bool
    let warnings: [String]
    let reachedRepositoryLimit: Bool
    let reachedTimeLimit: Bool
    var isIncomplete: Bool {
        !warnings.isEmpty || reachedRepositoryLimit || reachedTimeLimit
    }
}

private nonisolated struct RepositoryDirectoryScan: Sendable {
    let repository: ScannedRepository
    let submodules: ScannedSubmodules
}

private nonisolated struct RepositoryScanWalkState: Sendable {
    var repositories: [ScannedRepository] = []
    var incompleteReason: String?
    var visitedDirectoryCount = 0
}

private nonisolated enum RepositoryScanDirective: Sendable {
    case next
    case skipDescendants
    case stop
}

private nonisolated struct RepositoryScanStepResult: Sendable {
    let state: RepositoryScanWalkState
    let directive: RepositoryScanDirective
}

private nonisolated struct RepositoryScanContext: Sendable {
    let root: URL
    let normalizedExclusions: Set<String>
    let caseSensitive: Bool
    let deadline: Date
    let warningCollector: RepoScanWarningCollector
}

nonisolated struct RepoScanResult: Sendable, Equatable {
    var repositories: [ScannedRepository]
    var warnings: [String]
    var incompleteReason: String?
    var visitedDirectoryCount: Int
    var duration: Duration
    var isIncomplete: Bool { incompleteReason != nil || !warnings.isEmpty }
}

nonisolated enum RepoScannerError: Error, Sendable {
    case scanQueueFull
}

actor RepoScanner {
    nonisolated static let maximumConcurrentScans = 2
    nonisolated struct Configuration: Sendable {
        var directoryLimit = 100_000
        var repositoryLimit = 50
        var timeLimit: TimeInterval = 30
    }

    private let gitService: GitService
    private let fileManager: FileManager
    private let configuration: Configuration
    private var activeScans = 0
    private struct ScanWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var scanWaiters: [ScanWaiter] = []

#if DEBUG
    var waitingCountForTesting: Int { scanWaiters.count }
#endif
    init(
        gitService: GitService = GitService(),
        fileManager: FileManager = .default,
        configuration: Configuration = Configuration()
    ) {
        self.gitService = gitService
        self.fileManager = fileManager
        self.configuration = configuration
    }

    func scan(root: URL, exclusions: [String]) async throws -> RepoScanResult {
        try await acquireScanSlot()
        defer { releaseScanSlot() }
        try Task.checkCancellation()
        return try await scanRepositoryTree(root: root, exclusions: exclusions)
    }

    private func scanRepositoryTree(root: URL, exclusions: [String]) async throws -> RepoScanResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let canonicalRoot = RepositoryPathPolicy.canonicalURL(root)
        let caseSensitive = RepositoryPathPolicy.isCaseSensitiveVolume(at: canonicalRoot)
        let context = RepositoryScanContext(
            root: canonicalRoot,
            normalizedExclusions: Set(exclusions.map {
                RepositoryPathPolicy.normalizedRelativePath($0, caseSensitive: caseSensitive)
            }),
            caseSensitive: caseSensitive,
            deadline: Date().addingTimeInterval(configuration.timeLimit),
            warningCollector: RepoScanWarningCollector()
        )
        let state = try await walkDirectories(context: context)
        return RepoScanResult(
            repositories: state.repositories,
            warnings: context.warningCollector.warnings,
            incompleteReason: state.incompleteReason,
            visitedDirectoryCount: state.visitedDirectoryCount,
            duration: startedAt.duration(to: clock.now)
        )
    }

    private func walkDirectories(context: RepositoryScanContext) async throws -> RepositoryScanWalkState {
        let enumerator = fileManager.enumerator(
            at: context.root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) { url, error in
            context.warningCollector.append("Could not scan \(url.path): \(error.localizedDescription)")
            return true
        }
        var state = RepositoryScanWalkState()
        var pendingRoot: URL? = context.root

        while true {
            try Task.checkCancellation()
            let directory: URL
            if let root = pendingRoot {
                directory = root
                pendingRoot = nil
            } else {
                guard let child = enumerator?.nextObject() as? URL else { break }
                let values: URLResourceValues
                do {
                    values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey])
                } catch {
                    context.warningCollector.append("Could not inspect \(child.path): \(error.localizedDescription)")
                    continue
                }
                guard values.isDirectory == true else { continue }
                guard values.isSymbolicLink != true,
                      values.isHidden != true,
                      !child.lastPathComponent.hasPrefix(".") else {
                    enumerator?.skipDescendants()
                    continue
                }
                directory = RepositoryPathPolicy.standardizedURL(child)
            }
            let result = try await scanDirectory(directory, state: state, context: context)
            state = result.state
            switch result.directive {
            case .next:
                continue
            case .skipDescendants:
                enumerator?.skipDescendants()
            case .stop:
                return state
            }
        }
        return state
    }

    private func scanDirectory(
        _ directory: URL,
        state currentState: RepositoryScanWalkState,
        context: RepositoryScanContext
    ) async throws -> RepositoryScanStepResult {
        var state = currentState
        if Date() >= context.deadline {
            state.incompleteReason = "Scan stopped after \(Int(configuration.timeLimit)) seconds."
            return RepositoryScanStepResult(state: state, directive: .stop)
        }
        guard state.visitedDirectoryCount < configuration.directoryLimit else {
            state.incompleteReason = "Scan stopped after visiting \(configuration.directoryLimit) directories."
            return RepositoryScanStepResult(state: state, directive: .stop)
        }
        state.visitedDirectoryCount += 1

        let relativePath = RepositoryPathPolicy.relativePath(from: context.root, to: directory) ?? directory.path
        if RepositoryPathPolicy.isExactlyExcluded(
            relativePath,
            normalizedExclusions: context.normalizedExclusions,
            caseSensitive: context.caseSensitive
        ) {
            return RepositoryScanStepResult(
                state: state,
                directive: directory == context.root ? .stop : .skipDescendants
            )
        }
        let marker = directory.appendingPathComponent(".git", isDirectory: true)
        guard isNormalGitDirectory(marker) else {
            return RepositoryScanStepResult(state: state, directive: .next)
        }
        do {
            guard let scanned = try await scanRepositoryDirectory(
                at: directory,
                relativePath: relativePath,
                currentRepositoryCount: state.repositories.count,
                context: context
            ) else {
                return RepositoryScanStepResult(state: state, directive: .next)
            }
            state.repositories.append(scanned.repository)
            state.repositories.append(contentsOf: scanned.submodules.repositories)
            scanned.submodules.warnings.forEach(context.warningCollector.append)
            if scanned.submodules.reachedRepositoryLimit
                || scanned.submodules.reachedTimeLimit
                || state.repositories.count >= configuration.repositoryLimit {
                state.incompleteReason = scanned.submodules.reachedTimeLimit
                    ? "Scan stopped after \(Int(configuration.timeLimit)) seconds."
                    : "Scan stopped after finding \(configuration.repositoryLimit) repositories."
                return RepositoryScanStepResult(state: state, directive: .stop)
            }
            return RepositoryScanStepResult(
                state: state,
                directive: directory == context.root ? .stop : .skipDescendants
            )
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            context.warningCollector.append("Ignored invalid repository marker at \(directory.path): \(error)")
            return RepositoryScanStepResult(state: state, directive: .next)
        }
    }

    private func scanRepositoryDirectory(
        at directory: URL,
        relativePath: String,
        currentRepositoryCount: Int,
        context: RepositoryScanContext
    ) async throws -> RepositoryDirectoryScan? {
        let gitRoot = try await gitService.repositoryRoot(at: directory)
        guard gitRoot == RepositoryPathPolicy.canonicalURL(directory) else { return nil }
        let submodules = try await scanInitializedSubmodules(
            of: gitRoot,
            relativePathPrefix: relativePath,
            maximumRepositories: max(
                0,
                configuration.repositoryLimit - currentRepositoryCount - 1
            ),
            normalizedExclusions: context.normalizedExclusions,
            caseSensitive: context.caseSensitive,
            deadline: context.deadline
        )
        return RepositoryDirectoryScan(
            repository: ScannedRepository(
                url: directory,
                canonicalURL: gitRoot,
                relativePath: relativePath,
                resourceID: ResourceIdentity.read(from: gitRoot),
                gitDirectoryInfo: GitDirectoryInfo.read(at: gitRoot),
                hasSubmodules: submodules.hasConfiguredSubmodules
            ),
            submodules: submodules
        )
    }
    func scanInitializedSubmodules(
        of parentURL: URL,
        relativePathPrefix: String? = nil,
        maximumRepositories: Int? = nil,
        normalizedExclusions: Set<String> = [],
        caseSensitive: Bool = true,
        deadline: Date? = nil
    ) async throws -> ScannedSubmodules {
        try await RepositorySubmoduleScanner(
            gitService: gitService,
            repositoryLimit: configuration.repositoryLimit,
            timeLimit: configuration.timeLimit
        ).scan(
            of: parentURL,
            relativePathPrefix: relativePathPrefix,
            maximumRepositories: maximumRepositories,
            normalizedExclusions: normalizedExclusions,
            caseSensitive: caseSensitive,
            deadline: deadline
        )
    }

    func gitDirectoryInfo(at workingDirectoryURL: URL) -> GitDirectoryInfo? {
        GitDirectoryInfo.read(at: workingDirectoryURL)
    }

    private func isNormalGitDirectory(_ marker: URL) -> Bool {
        guard let values = try? marker.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func acquireScanSlot() async throws {
        try Task.checkCancellation()
        if activeScans < Self.maximumConcurrentScans {
            activeScans += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard scanWaiters.count < 32 else {
                    continuation.resume(throwing: RepoScannerError.scanQueueFull)
                    return
                }
                scanWaiters.append(ScanWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelScanWaiter(id) }
        }
    }

    private func releaseScanSlot() {
        if scanWaiters.isEmpty {
            activeScans -= 1
        } else {
            scanWaiters.removeFirst().continuation.resume()
        }
    }

    private func cancelScanWaiter(_ id: UUID) {
        guard let index = scanWaiters.firstIndex(where: { $0.id == id }) else { return }
        scanWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
