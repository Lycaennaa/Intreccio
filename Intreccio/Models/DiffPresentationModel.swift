import Foundation

nonisolated struct DiffSnapshotID: Sendable, Equatable, Hashable {
    let repositoryID: UUID
    let revision: UUID

    init(repositoryID: UUID, revision: UUID = UUID()) {
        self.repositoryID = repositoryID
        self.revision = revision
    }
}

nonisolated struct DiffFileID: Sendable, Equatable, Hashable {
    let snapshotID: DiffSnapshotID
    let ordinal: Int
}

nonisolated enum DiffPresentationScope: Sendable, Equatable {
    case allFiles
    case focused(DiffFileID)
}

nonisolated enum DiffPresentationState: Sendable, Equatable {
    case complete
    case partial(unavailableFileCount: Int, oversizedFileCount: Int)
    case aggregateFallback(DiffFallbackReason)
}
nonisolated enum DiffCountAvailability: Sendable, Equatable {
    case known
    case unavailable
}

nonisolated enum DiffPresentationLineStats: Sendable, Equatable {
    case known(additions: Int, deletions: Int)
    case unavailable

    init(additions: Int?, deletions: Int?) {
        guard let additions, let deletions else {
            self = .unavailable
            return
        }
        self = .known(additions: additions, deletions: deletions)
    }

    var additions: Int? {
        guard case .known(let additions, _) = self else { return nil }
        return additions
    }

    var deletions: Int? {
        guard case .known(_, let deletions) = self else { return nil }
        return deletions
    }

    var availability: DiffCountAvailability {
        switch self {
        case .known: return .known
        case .unavailable: return .unavailable
        }
    }
}

nonisolated struct DiffPresentationFileHeader: Sendable, Equatable {
    let id: DiffFileID
    let change: DiffFileChange
    let path: GitPath
    let originalPath: GitPath?
    let oldMode: String?
    let newMode: String?
    let stats: DiffPresentationLineStats

    var displayPath: String {
        path.displayString
    }

    var displayOriginalPath: String? {
        originalPath?.displayString
    }
}

nonisolated enum DiffPresentationFileState: Sendable, Equatable {
    case content(DiffFileContent)
    case aggregateFallback(DiffFallbackReason)
}

nonisolated struct DiffPresentationFile: Sendable, Equatable {
    let header: DiffPresentationFileHeader
    let state: DiffPresentationFileState

    var id: DiffFileID {
        header.id
    }

    var path: GitPath {
        header.path
    }

    var displayPath: String {
        header.displayPath
    }
}

nonisolated struct DiffPresentationModel: Sendable, Equatable {
    let snapshotID: DiffSnapshotID
    let files: [DiffPresentationFile]
    let state: DiffPresentationState
    let fallback: DiffFallback?
    let rawPatch: DiffRawPatch
    let stats: DiffPresentationLineStats
    let metadata: CommitDetailsMetadata?

    init(
        diff: GitDiff,
        snapshotID: DiffSnapshotID,
        metadata: CommitDetailsMetadata? = nil,
        rawPatch: DiffRawPatch? = nil
    ) {
        self.snapshotID = snapshotID
        fallback = diff.fallback
        self.rawPatch = rawPatch ?? diff.rawPatch
        self.metadata = metadata

        let renderedFiles = diff.files.enumerated().map { index, file in
            DiffPresentationFile(
                header: DiffPresentationFileHeader(
                    id: DiffFileID(snapshotID: snapshotID, ordinal: index),
                    change: file.change,
                    path: file.gitPath,
                    originalPath: file.originalGitPath,
                    oldMode: file.oldMode,
                    newMode: file.newMode,
                    stats: Self.lineStats(for: file.content)
                ),
                state: .content(file.content)
            )
        }
        let renderedSummaries = Set(diff.files.map(\.diffSummary))
        let unrenderedSummaries = diff.fallback?.files.filter { !renderedSummaries.contains($0) } ?? []
        let fallbackFiles = unrenderedSummaries.enumerated().map { index, summary in
            DiffPresentationFile(
                header: DiffPresentationFileHeader(
                    id: DiffFileID(snapshotID: snapshotID, ordinal: renderedFiles.count + index),
                    change: summary.change,
                    path: summary.gitPath,
                    originalPath: summary.originalGitPath,
                    oldMode: nil,
                    newMode: nil,
                    stats: .unavailable
                ),
                state: .aggregateFallback(diff.fallback?.reason ?? .malformed)
            )
        }
        let presentationFiles = renderedFiles + fallbackFiles
        files = presentationFiles
        if let fallback = diff.fallback {
            state = .aggregateFallback(fallback.reason)
            stats = .unavailable
        } else {
            let unavailableCount = diff.files.reduce(into: 0) { count, file in
                if case .unavailable = file.content { count += 1 }
            }
            let oversizedCount = diff.files.reduce(into: 0) { count, file in
                if file.content.oversizedReason != nil { count += 1 }
            }
            state = unavailableCount == 0 && oversizedCount == 0
                ? .complete
                : .partial(unavailableFileCount: unavailableCount, oversizedFileCount: oversizedCount)
            stats = Self.aggregateLineStats(presentationFiles.map(\.header.stats))
        }
    }

    init(diff: GitDiff, repositoryID: UUID, revision: UUID = UUID()) {
        self.init(diff: diff, snapshotID: DiffSnapshotID(repositoryID: repositoryID, revision: revision))
    }

    init(details: CommitDetails, repositoryID: UUID, revision: UUID = UUID()) {
        self.init(
            diff: details.diff,
            snapshotID: DiffSnapshotID(repositoryID: repositoryID, revision: revision),
            metadata: details.metadata,
            rawPatch: .git(details.rawPatch)
        )
    }

    func files(for scope: DiffPresentationScope) -> [DiffPresentationFile] {
        switch scope {
        case .allFiles:
            return files
        case .focused(let id):
            guard id.snapshotID == snapshotID else { return [] }
            return files.filter { $0.id == id }
        }
    }

    func file(with id: DiffFileID) -> DiffPresentationFile? {
        guard id.snapshotID == snapshotID else { return nil }
        return files.first { $0.id == id }
    }

    private static func lineStats(for content: DiffFileContent) -> DiffPresentationLineStats {
        guard case .text(let hunks) = content else { return .unavailable }
        var additions = 0
        var deletions = 0
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .addition: additions += 1
                case .deletion: deletions += 1
                case .context: break
                }
            }
        }
        return DiffPresentationLineStats(additions: additions, deletions: deletions)
    }

    private static func aggregateLineStats(_ fileStats: [DiffPresentationLineStats]) -> DiffPresentationLineStats {
        guard fileStats.allSatisfy({ $0.availability == .known }) else { return .unavailable }
        return DiffPresentationLineStats(
            additions: fileStats.compactMap(\.additions).reduce(0, +),
            deletions: fileStats.compactMap(\.deletions).reduce(0, +)
        )
    }
}
