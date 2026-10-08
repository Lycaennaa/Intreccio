import Darwin
import Foundation
nonisolated struct DiffStatsRefreshFingerprintCache: Sendable {
    struct Key: Hashable, Sendable {
        let statusGeneration: UInt64
        let path: GitPath
        let maximumBytes: Int64
    }

    private(set) var statusGeneration: UInt64
    private var values: [Key: FileContentFingerprint] = [:]

    init(statusGeneration: UInt64) {
        self.statusGeneration = statusGeneration
    }

    func key(path: String, maximumBytes: Int64) -> Key {
        key(path: GitPath(path), maximumBytes: maximumBytes)
    }

    func key(path: GitPath, maximumBytes: Int64) -> Key {
        Key(statusGeneration: statusGeneration, path: path, maximumBytes: maximumBytes)
    }

    func value(for key: Key) -> FileContentFingerprint? {
        values[key]
    }

    mutating func store(_ value: FileContentFingerprint, for key: Key) {
        values[key] = value
    }

    mutating func invalidate() {
        values.removeAll(keepingCapacity: true)
    }

    mutating func invalidate(for statusGeneration: UInt64) {
        self.statusGeneration = statusGeneration
        values.removeAll(keepingCapacity: true)
    }
}
extension GitService {
    func rawDiffFingerprint(
        repository: URL,
        kind: DiffKind,
        pathspecs: [String],
        priority: ProcessPriority
    ) async throws -> Data {
        var arguments = ["diff", "--raw", "-z", "--no-color", "--no-ext-diff", "--find-renames", "--find-copies"]
        arguments += try await diffComparisonArguments(for: kind, repository: repository)
        arguments += ["--"] + pathspecs
        let result = try await runner.run(
            repository: repository,
            arguments: arguments,
            environment: readEnvironment,
            outputLimit: Self.diffOutputLimit,
            priority: priority
        )
        return result.standardOutput
    }
    private nonisolated enum TrackedFingerprintResult {
        case fingerprint(FileContentFingerprint)
        case skipped
        case unavailable
    }
    private nonisolated static func trackedFingerprint(
        repository: URL,
        path: String,
        maximumBytes: Int64,
        remainingBytes: Int64,
        cache: inout DiffStatsRefreshFingerprintCache
    ) throws -> TrackedFingerprintResult {
        let key = cache.key(path: path, maximumBytes: maximumBytes)
        if let cached = cache.value(for: key) {
            guard cached.byteCount <= remainingBytes else { return .unavailable }
            return .fingerprint(cached)
        }
        do {
            guard let fingerprint = try SyntheticUntrackedDiff.contentFingerprint(
                repository: repository,
                relativePath: path,
                maximumBytes: remainingBytes
            ) else { return .unavailable }
            cache.store(fingerprint, for: key)
            return .fingerprint(fingerprint)
        } catch let error as SyntheticUntrackedDiffError {
            switch error {
            case .unsupportedFile:
                return .skipped
            case .openFailed(_, let code) where code == ELOOP:
                return .skipped
            default:
                throw error
            }
        }
    }
    func worktreeFingerprints(
        repository: URL,
        changes: [FileChange],
        maximumBytes: Int64,
        validateCached: Bool = true
    ) throws -> [String: FileContentFingerprint]? {
        guard changes.allSatisfy(\.isGitAddressable) else { return nil }
        let paths = Self.diffPaths(for: changes)
        var untrackedPaths = Set<String>()
        for change in changes where change.kind == .untracked {
            untrackedPaths.insert(change.path)
            if let originalPath = change.originalPath {
                untrackedPaths.insert(originalPath)
            }
        }
        var fingerprints: [String: FileContentFingerprint] = [:]
        var remainingBytes = maximumBytes
        var trackedCache = DiffStatsRefreshFingerprintCache(statusGeneration: 0)
        for path in paths {
            try Task.checkCancellation()
            let isUntracked = untrackedPaths.contains(path)
            if isUntracked {
                do {
                    guard let analysis = try untrackedFileAnalysis(
                        repository: repository,
                        path: path,
                        maximumBytes: remainingBytes,
                        validateCached: validateCached,
                        verifyFreshContent: validateCached
                    ), analysis.fingerprint.byteCount <= remainingBytes else { return nil }
                    fingerprints[path] = analysis.fingerprint
                    remainingBytes -= analysis.fingerprint.byteCount
                    continue
                } catch let error as SyntheticUntrackedDiffError {
                    guard case .openFailed(_, let code) = error,
                          code == ELOOP || code == ENOENT || code == ENOTDIR else { throw error }
                }
                let fingerprint = try SyntheticUntrackedDiff.contentFingerprint(
                    repository: repository,
                    relativePath: path,
                    maximumBytes: remainingBytes
                )
                guard let fingerprint else { return nil }
                fingerprints[path] = fingerprint
                remainingBytes -= fingerprint.byteCount
                continue
            }
            switch try Self.trackedFingerprint(
                repository: repository,
                path: path,
                maximumBytes: maximumBytes,
                remainingBytes: remainingBytes,
                cache: &trackedCache
            ) {
            case .fingerprint(let fingerprint):
                fingerprints[path] = fingerprint
                remainingBytes -= fingerprint.byteCount
            case .skipped:
                continue
            case .unavailable:
                return nil
            }
        }
        return fingerprints
    }
    nonisolated func trackedWorktreeFingerprints(
        repository: URL,
        changes: [FileChange],
        maximumBytes: Int64,
        cache: inout DiffStatsRefreshFingerprintCache
    ) throws -> [String: FileContentFingerprint]? {
        guard changes.allSatisfy(\.isGitAddressable) else { return nil }
        let paths = Self.diffPaths(for: changes)
        var fingerprints: [String: FileContentFingerprint] = [:]
        var remainingBytes = maximumBytes
        for path in paths {
            try Task.checkCancellation()
            switch try Self.trackedFingerprint(
                repository: repository,
                path: path,
                maximumBytes: maximumBytes,
                remainingBytes: remainingBytes,
                cache: &cache
            ) {
            case .fingerprint(let fingerprint):
                fingerprints[path] = fingerprint
                remainingBytes -= fingerprint.byteCount
            case .skipped:
                continue
            case .unavailable:
                return nil
            }
        }
        return fingerprints
    }
    nonisolated static func fingerprintSubset(
        _ fingerprints: [String: FileContentFingerprint],
        paths: [String]
    ) -> [String: FileContentFingerprint] {
        let pathSet = Set(paths)
        return fingerprints.filter { pathSet.contains($0.key) }
    }
    nonisolated static func diffPathValues(for changes: [FileChange]) -> [GitPath] {
        Array(Set(changes.flatMap { change -> [GitPath] in
            switch change.kind {
            case .renamed, .copied:
                if let originalPath = change.originalGitPath { return [change.gitPath, originalPath] }
            default:
                break
            }
            return [change.gitPath]
        })).sorted { $0.displayString.localizedStandardCompare($1.displayString) == .orderedAscending }
    }

    nonisolated static func diffPaths(for changes: [FileChange]) -> [String] {
        diffPathValues(for: changes)
            .filter(\.isAddressable)
            .map(\.decodedString)
    }

    nonisolated static func isDiffPathspecWithinLimit(_ paths: [String]) -> Bool {
        guard paths.count <= diffPathspecCountLimit else { return false }
        var bytes = 0
        for path in paths {
            bytes += path.utf8.count + 1
            if bytes > diffPathspecByteLimit { return false }
        }
        return true
    }

    nonisolated static func diffPathspecBatches(for changes: [FileChange]) -> [[String]]? {
        guard changes.allSatisfy(\.isGitAddressable) else { return nil }
        var seen = Set<GitPath>()
        let pathGroups = changes.compactMap { change -> [String]? in
            let paths: [GitPath]
            switch change.kind {
            case .renamed, .copied:
                paths = [change.gitPath, change.originalGitPath].compactMap(\.self)
            default:
                paths = [change.gitPath]
            }
            let uniquePaths = paths
                .filter { seen.insert($0).inserted }
                .sorted { $0.displayString.localizedStandardCompare($1.displayString) == .orderedAscending }
                .map(\.decodedString)
            return uniquePaths.isEmpty ? nil : uniquePaths
        }.sorted { lhs, rhs in
            lhs.joined(separator: "\0") < rhs.joined(separator: "\0")
        }
        return diffPathspecBatches(pathGroups: pathGroups)
    }

    private nonisolated static func diffPathspecBatches(pathGroups: [[String]]) -> [[String]]? {
        var batches: [[String]] = []
        var batch: [String] = []
        var byteCount = 0
        for paths in pathGroups {
            let pathspecs = paths.map { ":(literal)\($0)" }
            let pathspecBytes = pathspecs.reduce(0) { $0 + $1.utf8.count + 1 }
            guard pathspecs.count <= diffPathspecCountLimit,
                  pathspecBytes <= diffPathspecByteLimit else { return nil }
            if !batch.isEmpty, batch.count + pathspecs.count > diffPathspecCountLimit
                    || byteCount + pathspecBytes > diffPathspecByteLimit {
                batches.append(batch)
                batch = []
                byteCount = 0
            }
            batch.append(contentsOf: pathspecs)
            byteCount += pathspecBytes
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }
}
