import Foundation

nonisolated enum DiffSearchMatcher {
    static func matches(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var matches: [NSRange] = []
        var location = 0
        while location < source.length {
            let searchRange = NSRange(location: location, length: source.length - location)
            let match = source.range(of: query, options: [.caseInsensitive, .literal], range: searchRange)
            guard match.location != NSNotFound else { break }
            matches.append(match)
            location = match.location + max(match.length, 1)
        }
        return matches
    }
}

nonisolated enum DiffRawCopyAvailability: Sendable, Equatable {
    case exact
    case synthetic
    case mixed
    case mixedIncomplete
    case incomplete
    case unavailable

    init(_ patch: DiffRawPatch) {
        switch patch {
        case .git(let output): self = output.isComplete ? .exact : .incomplete
        case .synthetic: self = .synthetic
        case .mixed(let output): self = output.isComplete ? .mixed : .mixedIncomplete
        case .unavailable: self = .unavailable
        }
    }

    var isExact: Bool {
        self == .exact
    }

    var accessibilityText: String {
        switch self {
        case .exact: "Complete Git raw patch available"
        case .synthetic: "Raw patch unavailable because this view contains generated content"
        case .mixed: "Only tracked Git output is available; generated content is not included"
        case .mixedIncomplete: "Tracked Git output is incomplete and generated content is not included"
        case .incomplete: "Git raw patch is incomplete because output was truncated"
        case .unavailable: "Raw patch unavailable"
        }
    }

    var failureMessage: String {
        switch self {
        case .exact: ""
        case .synthetic:
            "Raw patch unavailable: this selection contains generated content, such as an untracked file or conflict. Use Copy Displayed Diff instead."
        case .mixed:
            "Raw patch is partial: Git output covers tracked files only; generated files are omitted."
        case .mixedIncomplete:
            "Raw patch unavailable: tracked Git output was truncated and generated files are omitted."
        case .incomplete:
            "Raw patch unavailable: Git output was truncated before the complete patch was captured."
        case .unavailable:
            "Raw patch unavailable for this diff."
        }
    }
}

nonisolated enum DiffFileAction: Sendable, Equatable {
    case open(GitPath)
    case reveal(GitPath)
}

nonisolated enum DiffLineDisplaySegment: Sendable, Equatable {
    case line(DiffLine)
    case folded(count: Int)
}

nonisolated enum DiffContextFolding {
    static let minimumFoldedRunLength = 4

    static func segments(
        for lines: [DiffLine],
        enabled: Bool
    ) -> [DiffLineDisplaySegment] {
        guard enabled,
              lines.contains(where: { $0.kind != .context }) else {
            return lines.map(DiffLineDisplaySegment.line)
        }

        var result: [DiffLineDisplaySegment] = []
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .context else {
                result.append(.line(lines[index]))
                index += 1
                continue
            }
            let runStart = index
            while index < lines.count, lines[index].kind == .context { index += 1 }
            let runLength = index - runStart
            guard runLength >= minimumFoldedRunLength else {
                result.append(contentsOf: lines[runStart..<index].map(DiffLineDisplaySegment.line))
                continue
            }
            result.append(.line(lines[runStart]))
            result.append(.folded(count: runLength - 2))
            result.append(.line(lines[index - 1]))
        }
        return result
    }
}

nonisolated enum DiffFileNavigator {
    static func targetIndex(selectedIndex: Int, entryCount: Int, offset: Int) -> Int? {
        let fileCount = entryCount - 1
        guard fileCount > 1 else { return nil }
        let currentFileOffset = selectedIndex > 0
            ? selectedIndex - 1
            : (offset > 0 ? fileCount - 1 : 0)
        let nextFileOffset = (currentFileOffset + offset + fileCount) % fileCount
        return nextFileOffset + 1
    }
}

nonisolated enum DiffAccessibilityNodeKind: String, Sendable, Equatable {
    case root
    case file
    case hunk
    case line
    case foldedContext
    case state
}

nonisolated struct DiffAccessibilityNode: Sendable, Equatable {
    let kind: DiffAccessibilityNodeKind
    let label: String
    let value: String?
    let children: [DiffAccessibilityNode]

    init(
        kind: DiffAccessibilityNodeKind,
        label: String,
        value: String? = nil,
        children: [DiffAccessibilityNode] = []
    ) {
        self.kind = kind
        self.label = label
        self.value = value
        self.children = children
    }
}

nonisolated enum DiffAccessibilityBuilder {
    static func make(
        for model: DiffPresentationModel,
        foldContext: Bool
    ) -> DiffAccessibilityNode {
        make(files: model.files, metadata: model.metadata, foldContext: foldContext, renderLimited: false)
    }

    static func make(
        for model: DiffPresentationModel,
        scope: DiffPresentationScope,
        foldContext: Bool,
        renderLimited: Bool
    ) -> DiffAccessibilityNode {
        make(
            files: model.files(for: scope),
            metadata: model.metadata,
            foldContext: foldContext,
            renderLimited: renderLimited
        )
    }

    private static func make(
        files: [DiffPresentationFile],
        metadata: CommitDetailsMetadata?,
        foldContext: Bool,
        renderLimited: Bool
    ) -> DiffAccessibilityNode {
        var children = files.map { file in
            fileNode(file, foldContext: foldContext, renderLimited: renderLimited)
        }
        if let metadata {
            switch metadata.completeness {
            case .complete:
                break
            case .truncated(let omittedBytes, let omittedLines):
                let lines = omittedLines.map { ", " + String($0) + " lines" } ?? ""
                children.append(DiffAccessibilityNode(
                    kind: .state,
                    label: "Commit metadata truncated",
                    value: String(omittedBytes) + " bytes" + lines + " omitted"
                ))
            case .unavailable:
                children.append(DiffAccessibilityNode(
                    kind: .state,
                    label: "Commit metadata unavailable"
                ))
            }
        }
        return DiffAccessibilityNode(
            kind: .root,
            label: "Diff",
            value: String(files.count) + " " + (files.count == 1 ? "file" : "files"),
            children: children
        )
    }

    private static func fileNode(
        _ file: DiffPresentationFile,
        foldContext: Bool,
        renderLimited: Bool
    ) -> DiffAccessibilityNode {
        var children: [DiffAccessibilityNode] = []
        if renderLimited {
            if case .aggregateFallback(let reason) = file.state {
                children.append(DiffAccessibilityNode(
                    kind: .state,
                    label: "Diff fallback",
                    value: diffFallbackReasonLabel(reason)
                ))
            }
            children.append(DiffAccessibilityNode(
                kind: .state,
                label: "Diff display limited",
                value: "This file is not expanded because the rendered diff exceeded its display limit"
            ))
        } else {
            switch file.state {
            case .aggregateFallback(let reason):
                children.append(DiffAccessibilityNode(
                    kind: .state,
                    label: "Diff fallback",
                    value: diffFallbackReasonLabel(reason)
                ))
            case .content(let content):
                switch content {
                case .text(let hunks):
                    for (index, hunk) in hunks.enumerated() {
                        children.append(hunkNode(hunk, index: index, foldContext: foldContext))
                    }
                    if hunks.isEmpty {
                        children.append(DiffAccessibilityNode(kind: .state, label: "No changed lines"))
                    }
                case .binary(let byteCount):
                    children.append(DiffAccessibilityNode(
                        kind: .state,
                        label: "Binary file",
                        value: byteCount.map { String($0) + " bytes" }
                    ))
                case .oversized(let reason, let byteCount):
                    children.append(DiffAccessibilityNode(
                        kind: .state,
                        label: "File too large to display",
                        value: [diffOversizedReasonLabel(reason), byteCount.map { String($0) + " bytes" }]
                            .compactMap(\.self)
                            .joined(separator: ", ")
                    ))
                case .unavailable(let reason):
                    children.append(DiffAccessibilityNode(
                        kind: .state,
                        label: "File unavailable",
                        value: DiffPresentationBuilder.unavailableReasonText(reason)
                    ))
                case .conflicted(let statusX, let statusY):
                    children.append(DiffAccessibilityNode(
                        kind: .state,
                        label: "Unmerged conflict",
                        value: "Status " + statusX.rawValue + statusY.rawValue
                    ))
                }
            }
        }

        return DiffAccessibilityNode(
            kind: .file,
            label: diffChangeLabel(file.header.change) + " " + file.displayPath,
            value: fileValue(file),
            children: children
        )
    }

    private static func hunkNode(
        _ hunk: DiffHunk,
        index: Int,
        foldContext: Bool
    ) -> DiffAccessibilityNode {
        let range = "-" + String(hunk.oldRange.start) + "," + String(hunk.oldRange.count) + " +" + String(hunk.newRange.start) + "," + String(hunk.newRange.count)
        let heading = hunk.heading.map { ", " + $0 } ?? ""
        let children = DiffContextFolding.segments(for: hunk.lines, enabled: foldContext).map { segment in
            switch segment {
            case .line(let line):
                return DiffAccessibilityNode(
                    kind: .line,
                    label: lineLabel(line),
                    value: line.text.isEmpty ? "(empty line)" : line.text
                )
            case .folded(let count):
                return DiffAccessibilityNode(
                    kind: .foldedContext,
                    label: "Context folded",
                    value: String(count) + " lines hidden; use Show All Context to reveal"
                )
            }
        }
        return DiffAccessibilityNode(
            kind: .hunk,
            label: "Hunk " + String(index + 1) + ", " + range + heading,
            children: children
        )
    }

    private static func fileValue(_ file: DiffPresentationFile) -> String? {
        var parts: [String] = []
        if let additions = file.header.stats.additions,
           let deletions = file.header.stats.deletions {
            parts.append("+" + String(additions) + " −" + String(deletions))
        }
        if let state = DiffPresentationBuilder.fileStateText(file.state) {
            parts.append(state)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func lineLabel(_ line: DiffLine) -> String {
        let status: String
        switch line.kind {
        case .context: status = "Context"
        case .addition: status = "Added"
        case .deletion: status = "Removed"
        }
        let number = line.newLineNumber ?? line.oldLineNumber
        return number.map { status + " line " + String($0) } ?? status + " line"
    }

}
