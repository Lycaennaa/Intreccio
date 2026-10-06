import CryptoKit
import Foundation

nonisolated struct DiffStatsSnapshot: Sendable, Equatable {
    let stats: DiffLineStats
    let worktreeFingerprint: [String: FileContentFingerprint]
    let trackedDiffFingerprint: Data?
}

extension GitService {
    func status(
        repository: URL,
        refreshUpstream: Bool = false,
        priority: ProcessPriority = .normal,
        includeDiffStats: Bool = false,
        expandUntrackedDirectories: Bool = true
    ) async throws -> RepoStatus {
        let status = try await statusWithoutDiffStats(
            repository: repository,
            refreshUpstream: refreshUpstream,
            priority: priority,
            expandUntrackedDirectories: expandUntrackedDirectories
        )
        return try await statusWithDiffStats(
            status,
            repository: repository,
            enabled: includeDiffStats,
            priority: priority,
            expandUntrackedDirectories: expandUntrackedDirectories
        )
    }

    private struct DiffStatsRefreshSnapshot {
        let status: RepoStatus
        var fingerprintCache: DiffStatsRefreshFingerprintCache
        var stagedTrackedWorktreeFingerprint: [String: FileContentFingerprint]?
        var unstagedTrackedWorktreeFingerprint: [String: FileContentFingerprint]?

        init(status: RepoStatus, generation: UInt64) {
            self.status = status
            fingerprintCache = DiffStatsRefreshFingerprintCache(statusGeneration: generation)
        }
    }

     func statusWithDiffStats(
        _ status: RepoStatus,
        repository: URL,
        enabled: Bool,
        priority: ProcessPriority,
        expandUntrackedDirectories: Bool = true
    ) async throws -> RepoStatus {
        guard enabled else { return status }
        guard !status.changes.isEmpty else {
            var result = status
            result.stagedLineStats = .zero
            result.unstagedLineStats = .zero
            return result
        }

        var refreshStatus = status
        var statusGeneration: UInt64 = 0
        for attempt in 0...1 {
            guard !refreshStatus.changes.isEmpty else {
                var result = refreshStatus
                result.stagedLineStats = .zero
                result.unstagedLineStats = .zero
                return result
            }

            var snapshot = DiffStatsRefreshSnapshot(status: refreshStatus, generation: statusGeneration)
            let stagedTrackedChanges = refreshStatus.changes.filter { change in
                change.hasStagedChange && change.kind != .untracked && change.kind != .unmerged
            }
            let unstagedTrackedChanges = refreshStatus.changes.filter { change in
                change.hasUnstagedChange && change.kind != .untracked && change.kind != .unmerged
            }
            snapshot.stagedTrackedWorktreeFingerprint = try trackedWorktreeFingerprintsIfAvailable(
                repository: repository,
                changes: stagedTrackedChanges,
                maximumBytes: Int64(DiffLimits.render.maximumBytes / 2),
                cache: &snapshot.fingerprintCache
            )
            snapshot.unstagedTrackedWorktreeFingerprint = try trackedWorktreeFingerprintsIfAvailable(
                repository: repository,
                changes: unstagedTrackedChanges,
                maximumBytes: Int64(DiffLimits.render.maximumBytes / 2),
                cache: &snapshot.fingerprintCache
            )

            let changes = refreshStatus.changes
            let stagedTrackedFingerprint = snapshot.stagedTrackedWorktreeFingerprint
            let unstagedTrackedFingerprint = snapshot.unstagedTrackedWorktreeFingerprint
            async let staged = diffStatsSnapshotIfAvailable(
                repository: repository,
                kind: .staged,
                changes: changes,
                priority: priority,
                precomputedTrackedWorktreeFingerprint: stagedTrackedFingerprint,
                skipTrackedFinalConsistencyCheck: stagedTrackedFingerprint != nil
            )
            async let unstaged = diffStatsSnapshotIfAvailable(
                repository: repository,
                kind: .unstaged,
                changes: changes,
                priority: priority,
                precomputedTrackedWorktreeFingerprint: unstagedTrackedFingerprint,
                skipTrackedFinalConsistencyCheck: unstagedTrackedFingerprint != nil
            )
            let stagedSnapshot = try await staged
            let unstagedSnapshot = try await unstaged

            let finalStatus: RepoStatus
            do {
                finalStatus = try await repositoryStatus(
                    repository: repository,
                    priority: priority,
                    expandUntrackedDirectories: expandUntrackedDirectories
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProcessRunnerError {
                if case .cancelled = error { throw CancellationError() }
                return refreshStatus
            } catch {
                return refreshStatus
            }
            guard finalStatus == snapshot.status else {
                guard attempt == 0 else { return finalStatus }
                refreshStatus = finalStatus
                statusGeneration &+= 1
                snapshot.fingerprintCache.invalidate(for: statusGeneration)
                continue
            }

            guard try await trackedDiffFingerprintMatches(
                snapshot: stagedSnapshot,
                kind: .staged,
                status: finalStatus,
                repository: repository,
                priority: priority
            ), try await trackedDiffFingerprintMatches(
                snapshot: unstagedSnapshot,
                kind: .unstaged,
                status: finalStatus,
                repository: repository,
                priority: priority
            ) else {
                guard attempt == 0 else { return finalStatus }
                refreshStatus = finalStatus
                statusGeneration &+= 1
                snapshot.fingerprintCache.invalidate(for: statusGeneration)
                continue
            }

            snapshot.fingerprintCache.invalidate()
            let finalStagedTrackedFingerprint: [String: FileContentFingerprint]?
            if stagedSnapshot != nil, snapshot.stagedTrackedWorktreeFingerprint != nil {
                guard let fingerprint = try trackedWorktreeFingerprintsIfAvailable(
                    repository: repository,
                    changes: stagedTrackedChanges,
                    maximumBytes: Int64(DiffLimits.render.maximumBytes / 2),
                    cache: &snapshot.fingerprintCache
                ) else { return finalStatus }
                finalStagedTrackedFingerprint = fingerprint
            } else {
                finalStagedTrackedFingerprint = nil
            }
            let finalUnstagedTrackedFingerprint: [String: FileContentFingerprint]?
            if unstagedSnapshot != nil, snapshot.unstagedTrackedWorktreeFingerprint != nil {
                guard let fingerprint = try trackedWorktreeFingerprintsIfAvailable(
                    repository: repository,
                    changes: unstagedTrackedChanges,
                    maximumBytes: Int64(DiffLimits.render.maximumBytes / 2),
                    cache: &snapshot.fingerprintCache
                ) else { return finalStatus }
                finalUnstagedTrackedFingerprint = fingerprint
            } else {
                finalUnstagedTrackedFingerprint = nil
            }

            if let initial = snapshot.stagedTrackedWorktreeFingerprint,
               stagedSnapshot != nil {
                guard let current = finalStagedTrackedFingerprint,
                      Self.fingerprintSubset(initial, paths: Self.diffPaths(for: stagedTrackedChanges))
                          == Self.fingerprintSubset(current, paths: Self.diffPaths(for: stagedTrackedChanges)) else {
                    guard attempt == 0 else { return finalStatus }
                    refreshStatus = finalStatus
                    statusGeneration &+= 1
                    snapshot.fingerprintCache.invalidate(for: statusGeneration)
                    continue
                }
            }
            if let initial = snapshot.unstagedTrackedWorktreeFingerprint,
               unstagedSnapshot != nil {
                guard let current = finalUnstagedTrackedFingerprint,
                      Self.fingerprintSubset(initial, paths: Self.diffPaths(for: unstagedTrackedChanges))
                          == Self.fingerprintSubset(current, paths: Self.diffPaths(for: unstagedTrackedChanges)) else {
                    guard attempt == 0 else { return finalStatus }
                    refreshStatus = finalStatus
                    statusGeneration &+= 1
                    snapshot.fingerprintCache.invalidate(for: statusGeneration)
                    continue
                }
            }

            var result = finalStatus
            if let stagedSnapshot {
                result.stagedLineStats = stagedSnapshot.stats
            }
            if let unstagedSnapshot {
                result.unstagedLineStats = unstagedSnapshot.stats
            }
            return result
        }
        return refreshStatus
    }

    private func diffStatsSnapshotIfAvailable(
        repository: URL,
        kind: DiffKind,
        changes: [FileChange],
        priority: ProcessPriority,
        precomputedTrackedWorktreeFingerprint: [String: FileContentFingerprint]?,
        skipTrackedFinalConsistencyCheck: Bool
    ) async throws -> DiffStatsSnapshot? {
        do {
            return try await diffStatsSnapshot(
                repository: repository,
                kind: kind,
                changes: changes,
                priority: priority,
                precomputedTrackedWorktreeFingerprint: precomputedTrackedWorktreeFingerprint,
                skipTrackedFinalConsistencyCheck: skipTrackedFinalConsistencyCheck
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProcessRunnerError {
            if case .cancelled = error { throw CancellationError() }
            return nil
        } catch {
            return nil
        }
    }

    private func trackedWorktreeFingerprintsIfAvailable(
        repository: URL,
        changes: [FileChange],
        maximumBytes: Int64,
        cache: inout DiffStatsRefreshFingerprintCache
    ) throws -> [String: FileContentFingerprint]? {
        do {
            return try trackedWorktreeFingerprints(
                repository: repository,
                changes: changes,
                maximumBytes: maximumBytes,
                cache: &cache
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func trackedDiffFingerprintMatches(
        snapshot: DiffStatsSnapshot?,
        kind: DiffKind,
        status: RepoStatus,
        repository: URL,
        priority: ProcessPriority
    ) async throws -> Bool {
        guard let expected = snapshot?.trackedDiffFingerprint else { return true }
        let changes = status.changes.filter { kind.includes($0) }
        guard let batches = Self.diffPathspecBatches(for: changes), !batches.isEmpty else {
            return false
        }
        do {
            var hasher = SHA256()
            for pathspecs in batches {
                try Task.checkCancellation()
                hasher.update(data: try await rawDiffFingerprint(
                    repository: repository,
                    kind: kind,
                    pathspecs: pathspecs,
                    priority: priority
                ))
            }
            return Data(hasher.finalize()) == expected
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProcessRunnerError {
            if case .cancelled = error { throw CancellationError() }
            return false
        } catch {
            return false
        }
    }

    func diffStats(
        repository: URL,
        kind: DiffKind,
        changes: [FileChange],
        priority: ProcessPriority = .selectedRepository
    ) async throws -> DiffLineStats? {
        try await diffStatsSnapshot(
            repository: repository,
            kind: kind,
            changes: changes,
            priority: priority
        )?.stats
    }

    func diffStatsSnapshot(
        repository: URL,
        kind: DiffKind,
        changes: [FileChange],
        priority: ProcessPriority = .selectedRepository,
        precomputedTrackedWorktreeFingerprint: [String: FileContentFingerprint]? = nil,
        skipTrackedFinalConsistencyCheck: Bool = false
    ) async throws -> DiffStatsSnapshot? {
        let selected = changes.filter { change in
            kind.includes(change)
        }
        guard !selected.isEmpty else {
            return DiffStatsSnapshot(stats: .zero, worktreeFingerprint: [:], trackedDiffFingerprint: nil)
        }
        guard !selected.contains(where: { $0.kind == .unmerged }) else { return nil }
        guard selected.allSatisfy(\.isGitAddressable) else { return nil }

        let tracked = selected.filter { $0.kind != .untracked && $0.kind != .unmerged }
        let trackedPaths = Self.diffPaths(for: tracked)
        let trackedPathspecBatches: [[String]]
        if trackedPaths.isEmpty {
            trackedPathspecBatches = []
        } else {
            guard let batches = Self.diffPathspecBatches(for: tracked) else { return nil }
            trackedPathspecBatches = batches
        }
        let untracked = kind != .staged ? selected.filter { $0.kind == .untracked } : []
        let untrackedPaths = Self.diffPaths(for: untracked)
        let fingerprintBudget = Int64(DiffLimits.render.maximumBytes / 2)
        if !untracked.isEmpty {
            beginUntrackedDiffAnalysisRefresh(for: repository)
        }
        var worktreeFingerprint: [String: FileContentFingerprint] = [:]
        if let precomputedTrackedWorktreeFingerprint {
            worktreeFingerprint = Self.fingerprintSubset(precomputedTrackedWorktreeFingerprint, paths: trackedPaths)
        }
        let untrackedDiffStats: UntrackedDiffStats?
        if !untracked.isEmpty {
            guard let stats = try untrackedDiffStatsForDiffStats(
                repository: repository,
                changes: untracked,
                validateCached: false
            ) else { return nil }
            worktreeFingerprint.merge(stats.fingerprints, uniquingKeysWith: { _, new in new })
            untrackedDiffStats = stats
        } else {
            untrackedDiffStats = nil
        }

        var statsAccumulator = SCCDiffStatsAccumulator(
            changes: selected,
            hasSCCCounter: sccLineCounter != nil
        )
        var trackedDiffFingerprintHasher = SHA256()
        for pathspecs in trackedPathspecBatches {
            try Task.checkCancellation()
            let fingerprint = try await rawDiffFingerprint(
                repository: repository,
                kind: kind,
                pathspecs: pathspecs,
                priority: priority
            )
            var arguments = [
                "diff", "--numstat", "-z", "--no-color", "--no-ext-diff",
                "--find-renames", "--find-copies"
            ]
            arguments += try await diffComparisonArguments(for: kind, repository: repository)
            arguments += ["--"] + pathspecs
            let result: ProcessCommandResult
            do {
                result = try await runner.run(
                    repository: repository,
                    arguments: arguments,
                    environment: readEnvironment,
                    outputLimit: Self.diffOutputLimit,
                    priority: priority
                )
            } catch ProcessRunnerError.outputLimitExceeded(let stream, _, _) where stream == .standardOutput {
                return nil
            }
            guard let stats = DiffLineStatsParser.parse(result.standardOutput) else { return nil }
            if statsAccumulator.canRunSCC {
                if let sourceFiles = try await sourceLineFiles(
                    repository: repository,
                    kind: kind,
                    pathspecs: pathspecs,
                    priority: priority
                ) {
                    statsAccumulator.add(sourceFiles)
                } else {
                    statsAccumulator.invalidateSCC()
                }
            }
            let currentFingerprint = try await rawDiffFingerprint(
                repository: repository,
                kind: kind,
                pathspecs: pathspecs,
                priority: priority
            )
            guard fingerprint == currentFingerprint else { return nil }
            trackedDiffFingerprintHasher.update(data: fingerprint)
            guard statsAccumulator.add(stats) else { return nil }
        }

        if let untrackedDiffStats {
            guard statsAccumulator.add(untrackedDiffStats) else { return nil }
        }
        if precomputedTrackedWorktreeFingerprint != nil && !skipTrackedFinalConsistencyCheck {
            guard let currentWorktreeFingerprint = try worktreeFingerprints(
                repository: repository,
                changes: selected,
                maximumBytes: fingerprintBudget,
                validateCached: true
            ), currentWorktreeFingerprint == worktreeFingerprint else { return nil }
        } else if !untracked.isEmpty {
            guard let currentUntrackedStats = try untrackedDiffStatsForDiffStats(
                repository: repository,
                changes: untracked,
                validateCached: true
            ), Self.fingerprintSubset(currentUntrackedStats.fingerprints, paths: untrackedPaths)
                == Self.fingerprintSubset(worktreeFingerprint, paths: untrackedPaths) else { return nil }
        }
        if statsAccumulator.canRunSCC, let sccLineCounter {
            if let sccCounts = try await sccLineCounter.count(
                additions: statsAccumulator.sccInputs.additions,
                deletions: statsAccumulator.sccInputs.deletions
            ) {
                statsAccumulator.apply(sccCounts)
            } else {
                statsAccumulator.invalidateSCC()
            }
        } else {
            statsAccumulator.markSCCUnavailable()
        }

        return DiffStatsSnapshot(
            stats: statsAccumulator.makeStats(),
            worktreeFingerprint: worktreeFingerprint,
            trackedDiffFingerprint: trackedPathspecBatches.isEmpty ? nil : Data(trackedDiffFingerprintHasher.finalize())
        )
    }

}
