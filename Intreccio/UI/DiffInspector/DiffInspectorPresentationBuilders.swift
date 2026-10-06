import Foundation


nonisolated extension DiffPresentationBuilder {
    static func summary(for model: DiffPresentationModel, mode: DiffSummaryMode) -> DiffSummaryModel {
        var unavailableFileCount = 0
        var oversizedFileCount = 0
        var oversizedReasons: [DiffFileOversizedReason] = []
        for file in model.files {
            guard case .content(let content) = file.state else { continue }
            switch content {
            case .unavailable: unavailableFileCount += 1
            case .oversized(let reason, _):
                oversizedFileCount += 1
                if !oversizedReasons.contains(reason) { oversizedReasons.append(reason) }
            case .text, .binary, .conflicted: break
            }
        }

        let oversizedReason = oversizedReasons.count == 1 ? oversizedReasons[0] : nil
        var notices: [DiffSummaryNotice] = []
        if unavailableFileCount > 0 {
            notices.append(.unavailable(count: unavailableFileCount))
        }
        if oversizedFileCount > 0 {
            notices.append(.oversized(count: oversizedFileCount, reason: oversizedReason))
        }
        if let fallback = model.fallback {
            notices.append(.limited(fallback.reason))
        }
        if let metadata = model.metadata {
            switch metadata.completeness {
            case .complete:
                break
            case .truncated(let omittedBytes, let omittedLines):
                notices.append(.metadataTruncated(omittedBytes: omittedBytes, omittedLines: omittedLines))
            case .unavailable:
                notices.append(.metadataUnavailable)
            }
        }

        return DiffSummaryModel(
            mode: mode,
            fileCount: model.files.count,
            additions: model.stats.additions,
            deletions: model.stats.deletions,
            notices: notices
        )
    }

    static func filePicker(
        for model: DiffPresentationModel,
        mode: DiffSummaryMode = .changes
    ) -> DiffFilePickerModel? {
        guard model.files.count > 1 else { return DiffFilePickerModel(entries: []) }
        let overall = summary(for: model, mode: mode)
        var entries = [DiffFilePickerEntry(
            pathTitle: "All files (\(model.files.count))",
            id: nil,
            statusText: "All",
            showsStatusInTitle: false,
            countText: statsText(overall.additions, overall.deletions),
            stateText: overall.statusText,
            accessibilityText: overall.accessibilityText
        )]
        entries.reserveCapacity(model.files.count + 1)
        for file in model.files {
            if Task.isCancelled { return nil }
            let status = diffChangeLabel(file.header.change)
            entries.append(DiffFilePickerEntry(
                pathTitle: file.displayPath,
                path: file.path,
                id: file.id,
                statusText: status,
                countText: statsText(file.header.stats.additions, file.header.stats.deletions),
                stateText: fileStateText(file.state),
                accessibilityText: fileAccessibilityText(file)
            ))
        }
        return DiffFilePickerModel(entries: entries)
    }

    static func commitPrefix(_ details: CommitDetails) -> String? {
        guard !Task.isCancelled else { return nil }
        let commit = details.commit
        guard let joinedParents = joined(commit.parentIDs, separator: " ") else { return nil }
        let parents = commit.parentIDs.isEmpty ? "Root commit" : joinedParents
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .long
        var sections = [
            commit.subject.isEmpty ? "(no subject)" : commit.subject,
            "Commit: \(commit.objectID)\nAuthor: \(commit.authorName) <\(commit.authorEmail)>\nDate: \(formatter.string(from: commit.authoredAt))\nParents: \(parents)\nComparison basis: \(details.comparisonBasis)",
        ]
        switch details.metadata.subject.completeness {
        case .complete:
            break
        case .truncated(let omittedBytes, _):
            sections.append("[Commit subject truncated: \(omittedBytes) bytes omitted]")
        case .unavailable:
            sections.append("[Commit subject unavailable]")
        }
        guard let body = trimmedWhitespaceAndNewlines(details.metadata.body.text) else { return nil }
        if !body.isEmpty { sections.append(body) }
        switch details.metadata.body.completeness {
        case .complete:
            break
        case .truncated(let omittedBytes, let omittedLines):
            let lineDescription = omittedLines.map { ", \($0) lines" } ?? ""
            sections.append("[Commit message truncated: \(omittedBytes) bytes\(lineDescription) omitted]")
        case .unavailable:
            sections.append("[Commit message unavailable]")
        }

        let summaryFiles: [DiffFileSummary]
        if details.metadata.changedFiles.files.isEmpty,
           details.metadata.changedFiles.completeness == .complete
               || details.metadata.changedFiles.completeness == .unavailable {
            summaryFiles = details.diff.files.map { $0.diffSummary }
        } else {
            summaryFiles = details.metadata.changedFiles.files
        }
        guard let bounded = boundedFileSummaries(summaryFiles),
              let joinedFiles = joined(bounded.values, separator: "\n") else { return nil }
        var summary = bounded.values.isEmpty
            ? "Changed files: none"
            : "Changed files (\(bounded.values.count))\n" + joinedFiles
        let metadataOmitted = details.metadata.changedFiles.omittedFileCount ?? 0
        let omittedCount = metadataOmitted + bounded.omittedCount
        switch details.metadata.changedFiles.completeness {
        case .complete:
            if omittedCount > 0 {
                summary += "\n\n[\(omittedCount) changed-file summaries omitted]"
            }
        case .truncated:
            let omitted = omittedCount > 0 ? String(omittedCount) : "some"
            summary += "\n\n[\(omitted) changed-file summaries omitted]"
        case .unavailable:
            let omitted = omittedCount > 0 ? "; \(omittedCount) summaries omitted" : ""
            summary += "\n\n[Changed-file metadata unavailable\(omitted)]"
        }
        sections.append(summary)
        guard var result = joined(sections, separator: "\n\n"), !Task.isCancelled else { return nil }
        result.append("\n")
        return Task.isCancelled ? nil : result
    }

    static func diffFallbackText(_ fallback: DiffFallback) -> String? {
        let reason = switch fallback.reason {
        case .byteLimit(let limit): "Diff exceeds the \(limit)-byte render limit."
        case .lineLimit(let limit): "Diff exceeds the \(limit)-line render limit."
        case .selectionLimit(let maximumFiles, let maximumBytes):
            "Selection exceeds the safe pathspec limit (\(maximumFiles) files or \(maximumBytes) bytes)."
        case .malformed: "Git returned a malformed diff."
        case .truncated: "Git returned a truncated diff."
        }
        var paths: [String] = []
        paths.reserveCapacity(fallback.files.count)
        for file in fallback.files {
            if Task.isCancelled { return nil }
            paths.append(file.displayPath)
        }
        guard let joinedPaths = joined(paths, separator: "\n") else { return nil }
        return paths.isEmpty ? reason : reason + "\n\n" + joinedPaths
    }

    static func boundedFileSummaries(_ files: [DiffFileSummary]) -> (values: [String], omittedCount: Int)? {
        let limits = HistoryMetadataLimits.default
        var values: [String] = []
        values.reserveCapacity(min(files.count, limits.maximumSummaryFiles))
        var byteCount = 0
        var omittedCount = 0
        for file in files {
            if Task.isCancelled { return nil }
            let originalPath = file.displayOriginalPath ?? file.originalGitPath?.displayString
            let path = originalPath.map { "\($0) -> \(file.displayPath)" } ?? file.displayPath
            let value = "\(diffChangeLabel(file.change))  \(path)"
            let separatorBytes = values.isEmpty ? 0 : 1
            let valueBytes = value.utf8.count + separatorBytes
            if values.count >= limits.maximumSummaryFiles
                || byteCount.addingReportingOverflow(valueBytes).overflow
                || byteCount + valueBytes > limits.maximumSummaryBytes {
                omittedCount += 1
                continue
            }
            values.append(value)
            byteCount += valueBytes
        }
        return (values, omittedCount)
    }

    static func statsText(_ additions: Int?, _ deletions: Int?) -> String? {
        guard let additions, let deletions else { return nil }
        return "+\(additions) −\(deletions)"
    }

    static func fileStateText(_ state: DiffPresentationFileState) -> String? {
        switch state {
        case .aggregateFallback(let reason):
            return "Limited: \(diffFallbackReasonLabel(reason))"
        case .content(let content):
            switch content {
            case .text:
                return nil
            case .binary(let byteCount):
                return byteCount.map { "Binary (\($0) bytes)" } ?? "Binary"
            case .oversized(let reason, let byteCount):
                let count = byteCount.map { " (\($0) bytes)" } ?? ""
                return "Oversized: \(diffOversizedReasonLabel(reason))\(count)"
            case .unavailable(let reason):
                return "Unavailable: \(unavailableReasonText(reason))"
            case .conflicted:
                return "Conflict"
            }
        }
    }

    static func fileAccessibilityText(_ file: DiffPresentationFile) -> String {
        var parts = [diffChangeLabel(file.header.change), file.displayPath]
        if let countText = statsText(file.header.stats.additions, file.header.stats.deletions) {
            parts.append(countText)
        }
        if let stateText = fileStateText(file.state) {
            parts.append(stateText)
        }
        return parts.joined(separator: ", ")
    }



    static func unavailableReasonText(_ reason: DiffFileUnavailableReason) -> String {
        switch reason {
        case .invalidPath: "invalid path"
        case .unsupportedFile: "unsupported file"
        case .permissionDenied: "permission denied"
        case .changedDuringRead: "changed during read"
        case .readFailed(let message): "read failed (\(bounded(message)))"
        }
    }

    private static func bounded(_ value: String, maximumCharacters: Int = 120) -> String {
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters - 1)) + "…"
    }

    static func joined(_ values: [String], separator: String) -> String? {
        var result = ""
        for (index, value) in values.enumerated() {
            if Task.isCancelled { return nil }
            if index > 0 { result.append(separator) }
            result.append(value)
        }
        return Task.isCancelled ? nil : result
    }

    static func trimmedWhitespaceAndNewlines(_ value: String) -> String? {
        var lowerBound = value.startIndex
        var upperBound = value.endIndex
        var checkedCharacters = 0
        while lowerBound < upperBound, value[lowerBound].isWhitespace {
            if checkedCharacters.isMultiple(of: 1_024), Task.isCancelled { return nil }
            checkedCharacters += 1
            lowerBound = value.index(after: lowerBound)
        }
        while lowerBound < upperBound {
            if checkedCharacters.isMultiple(of: 1_024), Task.isCancelled { return nil }
            checkedCharacters += 1
            let previous = value.index(before: upperBound)
            guard value[previous].isWhitespace else { break }
            upperBound = previous
        }
        guard !Task.isCancelled else { return nil }
        let result = String(value[lowerBound..<upperBound])
        return Task.isCancelled ? nil : result
    }
}