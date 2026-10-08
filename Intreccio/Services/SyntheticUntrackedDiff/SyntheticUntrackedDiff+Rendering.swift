import Foundation
nonisolated extension SyntheticUntrackedDiff {
    static func build(
        repository: URL,
        change: FileChange,
        limits: DiffLimits = .render
    ) throws -> GitDiff {
        let analysis = try analyze(
            repository: repository,
            relativePath: change.gitPath,
            maximumBytes: limits.maximumBytes,
            maximumLines: limits.maximumLines
        )
        return try build(change: change, analysis: analysis, limits: limits)
            ?? metadata(change, .oversized(
                reason: analysis.oversizedReason ?? .byteLimit(maximumBytes: limits.maximumBytes),
                byteCount: analysis.fingerprint.byteCount
            ))
    }
    static func build(
        change: FileChange,
        analysis: UntrackedFileAnalysis,
        limits: DiffLimits
    ) throws -> GitDiff? {
        try Task.checkCancellation()
        let byteCount = analysis.fingerprint.byteCount
        guard byteCount <= Int64(limits.maximumBytes) else {
            return metadata(change, .oversized(
                reason: .byteLimit(maximumBytes: limits.maximumBytes),
                byteCount: byteCount
            ))
        }
        switch analysis.kind {
        case .binary:
            return metadata(change, .binary(byteCount: byteCount))
        case .oversized:
            return metadata(change, .oversized(
                reason: analysis.oversizedReason ?? .byteLimit(maximumBytes: limits.maximumBytes),
                byteCount: byteCount
            ))
        case .text:
            guard analysis.isComplete,
                  let data = analysis.content,
                  let lineStats = analysis.lineStats else { return nil }
            let patchLineCount = 4 + lineStats.additions + (analysis.hasFinalNewline ? 0 : 1)
            guard patchLineCount <= limits.maximumLines else {
                return metadata(change, .oversized(
                    reason: .lineLimit(maximumLines: limits.maximumLines),
                    byteCount: byteCount
                ))
            }
            let text = String(decoding: data, as: UTF8.self)
            let whitespaceCost = data.reduce(into: 0) { total, byte in
                switch byte {
                case 0x20: total += 2
                case 0x09: total += 3
                default: break
                }
            }
            let pathCost = change.gitPath.displayString.utf8.count.multipliedReportingOverflow(by: 4)
            let contentCost = text.utf8.count.addingReportingOverflow(whitespaceCost)
            let estimated = contentCost.partialValue.addingReportingOverflow(96)
            let estimatedBytes = estimated.partialValue.addingReportingOverflow(pathCost.partialValue)
            guard !pathCost.overflow, !contentCost.overflow, !estimated.overflow, !estimatedBytes.overflow,
                  estimatedBytes.partialValue <= limits.maximumBytes else {
                return metadata(change, .oversized(
                    reason: .estimatedRenderSizeLimit(maximumBytes: limits.maximumBytes),
                    byteCount: byteCount
                ))
            }
            let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let contentLines = analysis.hasFinalNewline ? rawLines.dropLast() : rawLines[...]
            var lines: [DiffLine] = []
            lines.reserveCapacity(contentLines.count)
            for (offset, rawLine) in contentLines.enumerated() {
                if offset.isMultiple(of: 256) { try Task.checkCancellation() }
                let value = String(rawLine)
                lines.append(DiffLine(
                    kind: .addition,
                    text: value,
                    oldLineNumber: nil,
                    newLineNumber: offset + 1,
                    hasTrailingNewline: analysis.hasFinalNewline || offset < contentLines.count - 1,
                    tokens: DiffSyntaxTokenizer.tokenize(value)
                ))
            }
            let hunk = lines.isEmpty ? [] : [DiffHunk(
                oldRange: DiffRange(start: 0, count: 0),
                newRange: DiffRange(start: 1, count: lines.count),
                heading: nil,
                lines: lines
            )]
            return GitDiff(
                files: [DiffFile(
                    gitPath: change.gitPath,
                    originalGitPath: nil,
                    change: .untracked,
                    content: .text(hunk)
                )],
                fallback: nil,
                sourceByteCount: estimatedBytes.partialValue,
                sourceLineCount: patchLineCount,
                rawPatch: .synthetic
            )
        }
    }
    private static func metadata(_ change: FileChange, _ content: DiffFileContent) -> GitDiff {
        GitDiff(
            files: [DiffFile(
                gitPath: change.gitPath,
                originalGitPath: nil,
                change: .untracked,
                content: content
            )],
            fallback: nil,
            sourceByteCount: change.gitPath.byteCount + 64,
            sourceLineCount: 2,
            rawPatch: .synthetic
        )
    }
}
