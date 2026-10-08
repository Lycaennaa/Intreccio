import Foundation

nonisolated struct SCCDiffStatsAccumulator: Sendable {
    private(set) var additions = 0
    private(set) var deletions = 0
    private(set) var slocAdditions = 0
    private(set) var slocDeletions = 0
    private(set) var hasNonCodeFiles: Bool
    private(set) var hasCodeFiles = false
    private(set) var slocAvailability: SLOCAvailability

    private let hasPotentialSCCFiles: Bool
    private var sccInputComplete: Bool
    private var sccAdditions: [SCCSourceFile] = []
    private var sccDeletions: [SCCSourceFile] = []
    private var sccInputByteCount = 0

    init(changes: [FileChange], hasSCCCounter: Bool) {
        hasNonCodeFiles = changes.contains {
            SourceCodeFileClassifier.sccFileName(for: $0.gitPath) == nil
        }
        hasPotentialSCCFiles = changes.contains {
            SourceCodeFileClassifier.sccFileName(for: $0.gitPath) != nil
        }
        sccInputComplete = hasSCCCounter && hasPotentialSCCFiles
        slocAvailability = hasSCCCounter ? .available : .unavailable
    }

    var canRunSCC: Bool {
        sccInputComplete
    }

    var sccInputs: (additions: [SCCSourceFile], deletions: [SCCSourceFile]) {
        (sccAdditions, sccDeletions)
    }

    mutating func add(_ stats: DiffLineStats) -> Bool {
        guard add(stats.additions, to: &additions),
              add(stats.deletions, to: &deletions) else { return false }
        hasNonCodeFiles = hasNonCodeFiles || stats.hasNonCodeFiles
        hasCodeFiles = hasCodeFiles || stats.hasCodeFiles
        return true
    }

    mutating func add(_ stats: UntrackedDiffStats) -> Bool {
        guard add(stats.stats) else { return false }
        hasNonCodeFiles = hasNonCodeFiles || stats.hasNonCodeFiles
        hasCodeFiles = hasCodeFiles || stats.hasCodeFiles
        guard sccInputComplete else { return true }
        guard stats.sccSourceFilesComplete else {
            sccInputComplete = false
            return true
        }
        var byteCount = sccInputByteCount
        guard Self.append(stats.sccSourceFiles, to: &sccAdditions, byteCount: &byteCount) else {
            sccInputComplete = false
            return true
        }
        sccInputByteCount = byteCount
        return true
    }

    mutating func add(
        _ sourceFiles: (additions: [SCCSourceFile], deletions: [SCCSourceFile])
    ) {
        guard sccInputComplete else { return }
        var byteCount = sccInputByteCount
        guard Self.append(sourceFiles.additions, to: &sccAdditions, byteCount: &byteCount),
              Self.append(sourceFiles.deletions, to: &sccDeletions, byteCount: &byteCount) else {
            sccInputComplete = false
            return
        }
        sccInputByteCount = byteCount
    }

    mutating func invalidateSCC() {
        sccInputComplete = false
        slocAvailability = .unavailable
    }

    mutating func markSCCUnavailable() {
        guard hasPotentialSCCFiles else { return }
        slocAvailability = .unavailable
    }

    mutating func apply(_ counts: SCCLineCounts) {
        slocAdditions = counts.additions
        slocDeletions = counts.deletions
        hasNonCodeFiles = hasNonCodeFiles || counts.hasNonCodeFiles
        hasCodeFiles = counts.hasCodeFiles
    }

    func makeStats() -> DiffLineStats {
        DiffLineStats(
            additions: additions,
            deletions: deletions,
            slocAdditions: slocAdditions,
            slocDeletions: slocDeletions,
            hasNonCodeFiles: hasNonCodeFiles,
            hasCodeFiles: hasCodeFiles,
            slocAvailability: slocAvailability
        )
    }

    private static func append(
        _ sourceFiles: [SCCSourceFile],
        to destination: inout [SCCSourceFile],
        byteCount: inout Int
    ) -> Bool {
        for sourceFile in sourceFiles {
            let inputBytes = sourceFile.contents.count + (sourceFile.baselineContents?.count ?? 0)
            let result = byteCount.addingReportingOverflow(inputBytes)
            guard !result.overflow, result.partialValue <= SCCLineCounter.maximumInputBytes else {
                return false
            }
            destination.append(sourceFile)
            byteCount = result.partialValue
        }
        return true
    }

    private func add(_ value: Int, to total: inout Int) -> Bool {
        let result = total.addingReportingOverflow(value)
        guard !result.overflow else { return false }
        total = result.partialValue
        return true
    }
}

extension GitService {
    func sourceLineFiles(
        repository: URL,
        kind: DiffKind,
        pathspecs: [String],
        priority: ProcessPriority
    ) async throws -> (additions: [SCCSourceFile], deletions: [SCCSourceFile])? {
        var arguments = [
            "diff", "--unified=1000000", "--no-color", "--no-ext-diff",
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
        } catch ProcessRunnerError.cancelled {
            throw CancellationError()
        } catch {
            return nil
        }
        let diff = UnifiedDiffParser.parse(
            result.standardOutput,
            limits: DiffLimits(maximumBytes: Self.diffOutputLimit, maximumLines: Int.max)
        )
        guard diff.fallback == nil else { return nil }
        return Self.sccSourceFiles(from: diff)
    }

    static func sccSourceFiles(
        from diff: GitDiff
    ) -> (additions: [SCCSourceFile], deletions: [SCCSourceFile]) {
        var additions: [SCCSourceFile] = []
        var deletions: [SCCSourceFile] = []
        for file in diff.files {
            guard case .text(let hunks) = file.content else { continue }
            if let fileName = SourceCodeFileClassifier.sccFileName(for: file.gitPath) {
                for hunk in hunks {
                    let additionsLines = hunk.lines.filter { $0.kind != .deletion }
                    let contextLines = hunk.lines.filter { $0.kind == .context }
                    if let sourceFile = sccSourceFile(
                        fileName: fileName,
                        lines: additionsLines,
                        baselineLines: contextLines
                    ) {
                        additions.append(sourceFile)
                    }
                }
            }
            let originalPath = file.originalGitPath ?? file.gitPath
            if let fileName = SourceCodeFileClassifier.sccFileName(for: originalPath) {
                for hunk in hunks {
                    let deletionsLines = hunk.lines.filter { $0.kind != .addition }
                    let contextLines = hunk.lines.filter { $0.kind == .context }
                    if let sourceFile = sccSourceFile(
                        fileName: fileName,
                        lines: deletionsLines,
                        baselineLines: contextLines
                    ) {
                        deletions.append(sourceFile)
                    }
                }
            }
        }
        return (additions, deletions)
    }

    static func sccSourceFile(
        fileName: String,
        lines: [DiffLine],
        baselineLines: [DiffLine]
    ) -> SCCSourceFile? {
        guard lines.contains(where: { $0.kind != .context }) else { return nil }
        let contents = lines.map(\.text).joined(separator: "\n") + "\n"
        let baselineContents = baselineLines.map(\.text).joined(separator: "\n") + "\n"
        return SCCSourceFile(
            fileName: fileName,
            contents: Data(contents.utf8),
            baselineContents: Data(baselineContents.utf8)
        )
    }

    static func appendSCCSourceFiles(
        _ sourceFiles: [SCCSourceFile],
        to destination: inout [SCCSourceFile],
        byteCount: inout Int
    ) -> Bool {
        for sourceFile in sourceFiles {
            let inputBytes = sourceFile.contents.count + (sourceFile.baselineContents?.count ?? 0)
            let result = byteCount.addingReportingOverflow(inputBytes)
            guard !result.overflow, result.partialValue <= SCCLineCounter.maximumInputBytes else {
                return false
            }
            destination.append(sourceFile)
            byteCount = result.partialValue
        }
        return true
    }
}
