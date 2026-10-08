import Darwin
import Foundation
extension GitService {
    func diff(
        repository: URL,
        kind: DiffKind,
        changes: [FileChange],
        limits: DiffLimits = .render
    ) async throws -> GitDiff {
        let selected = changes.filter { kind.includes($0) }
        guard !selected.isEmpty else { return .empty }

        let summaries = selected.map(\.diffSummary)
        let tracked = selected.filter {
            $0.kind != .untracked && $0.kind != .unmerged && $0.isGitAddressable
        }
        let invalidTracked = selected.filter {
            $0.kind != .untracked && $0.kind != .unmerged && !$0.isGitAddressable
        }
        var documents: [GitDiff] = []
        var byteCount = 0
        var lineCount = 0
        var generatedFileCount = 0
        var trackedRawOutput: GitRawOutput?

        func rawPatch() -> DiffRawPatch {
            if generatedFileCount == 0 {
                return trackedRawOutput.map(DiffRawPatch.git) ?? .unavailable
            }
            return trackedRawOutput.map(DiffRawPatch.mixed) ?? .synthetic
        }

        func aggregate(_ reason: DiffFallbackReason, sourceBytes: Int, sourceLines: Int) -> GitDiff {
            let renderedFiles = documents.flatMap(\.files)
            let renderedSummaries = Set(renderedFiles.map(\.diffSummary))
            let unrenderedSummaries = summaries.filter { !renderedSummaries.contains($0) }
            return GitDiff(
                files: renderedFiles,
                fallback: DiffFallback(reason: reason, files: unrenderedSummaries),
                sourceByteCount: sourceBytes,
                sourceLineCount: sourceLines,
                rawPatch: rawPatch()
            )
        }

        if !invalidTracked.isEmpty {
            let invalidDocuments = invalidTracked.map { change in
                GitDiff(
                    files: [DiffFile(
                        gitPath: change.gitPath,
                        originalGitPath: change.originalGitPath,
                        change: change.diffFileChange,
                        content: .unavailable(.invalidPath)
                    )],
                    fallback: nil,
                    sourceByteCount: change.gitPath.byteCount + 64,
                    sourceLineCount: 2,
                    rawPatch: .synthetic
                )
            }
            documents.append(contentsOf: invalidDocuments)
            generatedFileCount += invalidDocuments.count
            byteCount += invalidDocuments.reduce(0) { $0 + $1.sourceByteCount }
            lineCount += invalidDocuments.reduce(0) { $0 + $1.sourceLineCount }
        }

        let conflicts = selected.filter { $0.kind == .unmerged }.map { change in
            DiffFile(
                gitPath: change.gitPath,
                originalGitPath: change.originalGitPath,
                change: .conflicted,
                content: .conflicted(statusX: change.indexState, statusY: change.worktreeState)
            )
        }
        if !conflicts.isEmpty {
            let conflictDocument = GitDiff(
                files: conflicts,
                fallback: nil,
                sourceByteCount: conflicts.reduce(0) { $0 + $1.gitPath.byteCount + 32 },
                sourceLineCount: conflicts.count * 2,
                rawPatch: .synthetic
            )
            documents.append(conflictDocument)
            generatedFileCount += conflicts.count
            byteCount += conflictDocument.sourceByteCount
            lineCount += conflictDocument.sourceLineCount
        }

        if !tracked.isEmpty {
            let pathspecs = tracked.map { ":(literal)\($0.gitPath.decodedString)" }
            guard Self.isDiffPathspecWithinLimit(pathspecs) else {
                return aggregate(
                    .selectionLimit(
                        maximumFiles: Self.diffPathspecCountLimit,
                        maximumBytes: Self.diffPathspecByteLimit
                    ),
                    sourceBytes: byteCount,
                    sourceLines: lineCount
                )
            }
            var arguments = ["diff"]
            arguments += try await diffComparisonArguments(for: kind, repository: repository)
            arguments += ["--no-color", "--no-ext-diff", "--find-renames", "--find-copies", "--src-prefix=a/", "--dst-prefix=b/", "--"]
            arguments += pathspecs
            do {
                let result = try await runner.run(
                    repository: repository,
                    arguments: arguments,
                    environment: readEnvironment,
                    outputLimit: limits.maximumBytes,
                    priority: .selectedRepository
                )
                trackedRawOutput = GitRawOutput(bytes: result.standardOutput)
                let document = UnifiedDiffParser.parse(
                    result.standardOutput,
                    limits: limits,
                    summaries: summaries
                )
                documents.append(document)
                byteCount += document.sourceByteCount
                lineCount += document.sourceLineCount
            } catch ProcessRunnerError.outputLimitExceeded(let stream, let limit, let result) where stream == .standardOutput {
                trackedRawOutput = GitRawOutput(
                    bytes: result.standardOutput,
                    completeness: .truncated(limit: limit)
                )
                return aggregate(.byteLimit(limit), sourceBytes: byteCount + result.standardOutput.count, sourceLines: lineCount)
            }
        }

        if kind != .staged {
            for change in selected where change.kind == .untracked {
                try Task.checkCancellation()
                generatedFileCount += 1
                let document: GitDiff
                do {
                    document = try untrackedDiffDocument(repository: repository, change: change, limits: limits)
                } catch let error as SyntheticUntrackedDiffError {
                    document = unavailableUntrackedDocument(change: change, error: error)
                }
                documents.append(document)
                let isMetadataOnly = document.files.allSatisfy { file in
                    if case .text = file.content { return false }
                    return true
                }
                byteCount += isMetadataOnly
                    ? min(document.sourceByteCount, max(0, limits.maximumBytes))
                    : document.sourceByteCount
                lineCount += isMetadataOnly
                    ? min(document.sourceLineCount, max(0, limits.maximumLines))
                    : document.sourceLineCount
                if !isMetadataOnly, byteCount > limits.maximumBytes {
                    documents.removeLast()
                    return aggregate(.byteLimit(limits.maximumBytes), sourceBytes: byteCount, sourceLines: lineCount)
                }
                if !isMetadataOnly, lineCount > limits.maximumLines {
                    documents.removeLast()
                    return aggregate(.lineLimit(limits.maximumLines), sourceBytes: byteCount, sourceLines: lineCount)
                }
            }
        }

        if let fallback = documents.compactMap(\.fallback).first {
            return aggregate(fallback.reason, sourceBytes: byteCount, sourceLines: lineCount)
        }
        guard byteCount <= limits.maximumBytes else {
            return aggregate(.byteLimit(limits.maximumBytes), sourceBytes: byteCount, sourceLines: lineCount)
        }
        guard lineCount <= limits.maximumLines else {
            return aggregate(.lineLimit(limits.maximumLines), sourceBytes: byteCount, sourceLines: lineCount)
        }
        return GitDiff(
            files: documents.flatMap(\.files),
            fallback: nil,
            sourceByteCount: byteCount,
            sourceLineCount: lineCount,
            rawPatch: rawPatch()
        )
    }

    private func unavailableUntrackedDocument(change: FileChange, error: SyntheticUntrackedDiffError) -> GitDiff {
        let reason: DiffFileUnavailableReason
        switch error {
        case .invalidPath:
            reason = .invalidPath
        case .unsupportedFile:
            reason = .unsupportedFile
        case .changedDuringRead:
            reason = .changedDuringRead
        case .openFailed(_, let code), .readFailed(_, let code):
            if code == ELOOP {
                reason = .unsupportedFile
            } else {
                reason = code == EACCES || code == EPERM ? .permissionDenied : .readFailed("read")
            }
        }
        return GitDiff(
            files: [DiffFile(
                gitPath: change.gitPath,
                originalGitPath: change.originalGitPath,
                change: .untracked,
                content: .unavailable(reason)
            )],
            fallback: nil,
            sourceByteCount: change.gitPath.byteCount + 64,
            sourceLineCount: 2,
            rawPatch: .synthetic
        )
    }
    private func untrackedDiffDocument(
        repository: URL,
        change: FileChange,
        limits: DiffLimits
    ) throws -> GitDiff {
        guard limits.maximumBytes >= 0,
              limits.maximumLines >= 0,
              limits.maximumBytes <= DiffLimits.render.maximumBytes,
              limits.maximumLines <= DiffLimits.render.maximumLines else {
            return try SyntheticUntrackedDiff.build(repository: repository, change: change, limits: limits)
        }
        guard let analysis = try untrackedFileAnalysis(
            repository: repository,
            path: change.gitPath,
            maximumBytes: Int64(limits.maximumBytes),
            validateCached: true,
            requiresContent: true
        ) else {
            return try SyntheticUntrackedDiff.build(repository: repository, change: change, limits: limits)
        }
        if let document = try SyntheticUntrackedDiff.build(change: change, analysis: analysis, limits: limits) {
            return document
        }

        untrackedDiffAnalysisCache.invalidate(path: change.gitPath)
        guard let refreshed = try untrackedFileAnalysis(
            repository: repository,
            path: change.gitPath,
            maximumBytes: Int64(limits.maximumBytes),
            validateCached: true,
            requiresContent: true
        ) else {
            return try SyntheticUntrackedDiff.build(repository: repository, change: change, limits: limits)
        }
        if let document = try SyntheticUntrackedDiff.build(change: change, analysis: refreshed, limits: limits) {
            return document
        }
        return try SyntheticUntrackedDiff.build(repository: repository, change: change, limits: limits)
    }
}
