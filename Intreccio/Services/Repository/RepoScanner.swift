import Foundation

private nonisolated final class RepoScanWarningCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ warning: String) {
        lock.withLock {
            if values.count < 100 { values.append(warning) }
            else if values.count == 100 { values.append("Additional scan warnings omitted.") }
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
}

nonisolated struct RepoScanResult: Sendable, Equatable {
    var repositories: [ScannedRepository]
    var warnings: [String]
    var incompleteReason: String?
    var visitedDirectoryCount: Int
    var duration: Duration
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
        let clock = ContinuousClock()
        let startedAt = clock.now
        let canonicalRoot = RepositoryPathPolicy.canonicalURL(root)
        let caseSensitive = RepositoryPathPolicy.isCaseSensitiveVolume(at: canonicalRoot)
        let excluded = Set(exclusions.map {
            RepositoryPathPolicy.normalizedRelativePath($0, caseSensitive: caseSensitive)
        })
        let deadline = Date().addingTimeInterval(configuration.timeLimit)
        var visited = 0
        var repositories: [ScannedRepository] = []
        let warningCollector = RepoScanWarningCollector()
        var incompleteReason: String?
        func recordWarning(_ message: String) {
            warningCollector.append(message)
        }
        let enumerator = fileManager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) { url, error in
            recordWarning("Could not scan \(url.path): \(error.localizedDescription)")
            return true
        }
        var pendingRoot: URL? = canonicalRoot

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
                    recordWarning("Could not inspect \(child.path): \(error.localizedDescription)")
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
            if Date() >= deadline {
                incompleteReason = "Scan stopped after \(Int(configuration.timeLimit)) seconds."
                break
            }
            guard visited < configuration.directoryLimit else {
                incompleteReason = "Scan stopped after visiting \(configuration.directoryLimit) directories."
                break
            }
            visited += 1

            let relativePath = RepositoryPathPolicy.relativePath(from: canonicalRoot, to: directory) ?? directory.path
            if RepositoryPathPolicy.isExactlyExcluded(
                relativePath,
                normalizedExclusions: excluded,
                caseSensitive: caseSensitive
            ) {
                if directory == canonicalRoot { break }
                enumerator?.skipDescendants()
                continue
            }

            let marker = directory.appendingPathComponent(".git", isDirectory: true)
            if isNormalGitDirectory(marker) {
                do {
                    let gitRoot = try await gitService.repositoryRoot(at: directory)
                    if gitRoot == RepositoryPathPolicy.canonicalURL(directory) {
                        repositories.append(ScannedRepository(
                            url: directory,
                            canonicalURL: gitRoot,
                            relativePath: relativePath,
                            resourceID: ResourceIdentity.read(from: gitRoot)
                        ))
                        if repositories.count >= configuration.repositoryLimit {
                            incompleteReason = "Scan stopped after finding \(configuration.repositoryLimit) repositories."
                            break
                        }
                        if directory == canonicalRoot { break }
                        enumerator?.skipDescendants()
                        continue
                    }
                } catch {
                    recordWarning("Ignored invalid repository marker at \(directory.path): \(error)")
                }
            }
        }

        return RepoScanResult(
            repositories: repositories,
            warnings: warningCollector.warnings,
            incompleteReason: incompleteReason,
            visitedDirectoryCount: visited,
            duration: startedAt.duration(to: clock.now)
        )
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
