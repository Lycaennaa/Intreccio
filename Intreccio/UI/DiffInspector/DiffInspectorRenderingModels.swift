import Foundation

nonisolated enum DiffRenderStyle: Sendable, Equatable {
    case base
    case muted
    case header
    case hunk
    case addition
    case deletion
    case keyword
    case string
    case comment
    case warning
}

nonisolated struct DiffRenderRun: Sendable {
    let range: NSRange
    let style: DiffRenderStyle
    let backgroundStyle: DiffRenderStyle?

    init(range: NSRange, style: DiffRenderStyle, backgroundStyle: DiffRenderStyle? = nil) {
        self.range = range
        self.style = style
        self.backgroundStyle = backgroundStyle
    }
}
nonisolated struct DiffHunkDisplayTarget: Sendable, Equatable {
    let range: NSRange
    let fileIndex: Int
    let hunkIndex: Int
    let label: String
}

nonisolated struct DiffLineDisplayTarget: Sendable, Equatable {
    let range: NSRange
    let fileIndex: Int
    let hunkIndex: Int
    let lineIndex: Int
    let kind: DiffLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

nonisolated struct DiffFoldedContextDisplayTarget: Sendable, Equatable {
    let range: NSRange
    let fileIndex: Int
    let hunkIndex: Int
    let count: Int
}

nonisolated struct DiffTextNavigation: Sendable, Equatable {
    let hunks: [DiffHunkDisplayTarget]
    let lines: [DiffLineDisplayTarget]
    let foldedContexts: [DiffFoldedContextDisplayTarget]

    static let empty = DiffTextNavigation(hunks: [], lines: [], foldedContexts: [])
}

nonisolated struct DiffTextLayout: Sendable {
    let text: String
    let runs: [DiffRenderRun]
    let navigation: DiffTextNavigation

    init(text: String, runs: [DiffRenderRun], navigation: DiffTextNavigation = .empty) {
        self.text = text
        self.runs = runs
        self.navigation = navigation
    }
}

nonisolated struct DiffAttributedRender: @unchecked Sendable {
    let value: NSAttributedString
}

nonisolated enum DiffSummaryMode: Sendable, Equatable {
    case unstaged
    case staged
    case changes
    case history

    var title: String {
        switch self {
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        case .changes: "Changes"
        case .history: "History"
        }
    }
}

nonisolated func diffFallbackReasonLabel(_ reason: DiffFallbackReason) -> String {
    switch reason {
    case .byteLimit: "byte limit"
    case .lineLimit: "line limit"
    case .selectionLimit: "selection limit"
    case .malformed: "malformed output"
    case .truncated: "truncated output"
    }
}

nonisolated func diffOversizedReasonLabel(_ reason: DiffFileOversizedReason) -> String {
    switch reason {
    case .byteLimit: "byte limit"
    case .lineLimit: "line limit"
    case .estimatedRenderSizeLimit: "render-size limit"
    }
}

nonisolated enum DiffSummaryNotice: Sendable, Equatable {
    case unavailable(count: Int)
    case oversized(count: Int, reason: DiffFileOversizedReason?)
    case limited(DiffFallbackReason)
    case metadataTruncated(omittedBytes: Int, omittedLines: Int?)
    case metadataUnavailable
    case renderLimited

    var fullText: String {
        switch self {
        case .unavailable(let count): "Unavailable: \(count)"
        case .oversized(let count, let reason): "Oversized: \(count)\(reason.map { " (\(diffOversizedReasonLabel($0)))" } ?? " (multiple limits)")"
        case .limited(let reason): "Limited: \(diffFallbackReasonLabel(reason))"
        case .metadataTruncated(let omittedBytes, let omittedLines):
            "Metadata truncated: \(omittedBytes) bytes\(omittedLines.map { ", \($0) lines" } ?? "")"
        case .metadataUnavailable: "Metadata unavailable"
        case .renderLimited: "Display limited by render-size budget"
        }
    }

    var compactText: String {
        switch self {
        case .unavailable(let count): "\(count) unavailable"
        case .oversized(let count, let reason): "\(count) oversized\(reason.map { " (\(diffOversizedReasonLabel($0)))" } ?? " (multiple limits)")"
        case .limited(let reason): "Limited: \(diffFallbackReasonLabel(reason))"
        case .metadataTruncated: "Metadata truncated"
        case .metadataUnavailable: "Metadata unavailable"
        case .renderLimited: "Display limited"
        }
    }
}

nonisolated struct DiffSummaryModel: Sendable, Equatable {
    let mode: DiffSummaryMode
    let fileCount: Int
    let additions: Int?
    let deletions: Int?
    let notices: [DiffSummaryNotice]

    var fileCountText: String {
        "\(fileCount) \(fileCount == 1 ? "file" : "files")"
    }

    var additionsText: String {
        additions.map { "+\($0)" } ?? "+—"
    }

    var deletionsText: String {
        deletions.map { "−\($0)" } ?? "−—"
    }

    var statusText: String? {
        notices.isEmpty ? nil : notices.map(\.fullText).joined(separator: " · ")
    }

    var compactStatusText: String? {
        notices.isEmpty ? nil : notices.map(\.compactText).joined(separator: " · ")
    }

    var accessibilityText: String {
        var parts = [mode.title, fileCountText, "\(additionsText) additions", "\(deletionsText) deletions"]
        if let statusText, !statusText.isEmpty { parts.append(statusText) }
        return parts.joined(separator: ", ")
    }

    func addingRenderLimitNotice() -> DiffSummaryModel {
        guard !notices.contains(.renderLimited) else { return self }
        return DiffSummaryModel(
            mode: mode,
            fileCount: fileCount,
            additions: additions,
            deletions: deletions,
            notices: notices + [.renderLimited]
        )
    }
}

nonisolated struct DiffFilePickerEntry: Sendable, Equatable {
    let pathTitle: String
    let path: GitPath?
    let id: DiffFileID?
    let statusText: String
    let showsStatusInTitle: Bool
    let countText: String?
    let stateText: String?
    let accessibilityText: String

    var title: String {
        guard showsStatusInTitle, !statusText.isEmpty else { return pathTitle }
        return "\(statusText)  \(pathTitle)"
    }

    init(
        pathTitle: String,
        path: GitPath? = nil,
        id: DiffFileID? = nil,
        statusText: String = "",
        showsStatusInTitle: Bool = true,
        countText: String? = nil,
        stateText: String? = nil,
        accessibilityText: String? = nil
    ) {
        self.pathTitle = pathTitle
        self.path = path
        self.id = id
        self.statusText = statusText
        self.showsStatusInTitle = showsStatusInTitle
        self.countText = countText
        self.stateText = stateText
        let displayTitle = showsStatusInTitle && !statusText.isEmpty
            ? "\(statusText)  \(pathTitle)"
            : pathTitle
        self.accessibilityText = accessibilityText ?? [displayTitle, countText, stateText]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

nonisolated struct DiffFilePickerModel: Sendable, Equatable {
    let entries: [DiffFilePickerEntry]
}

nonisolated struct DiffPreparedRender: @unchecked Sendable {
    let attributed: NSAttributedString
    let picker: DiffFilePickerModel?
    let prefix: String?
    let summary: DiffSummaryModel
    let navigation: DiffTextNavigation
}

nonisolated enum DiffRenderPrefixSource: Sendable {
    case none
    case cached(String)
    case commit(CommitDetails)
    case fallback(DiffFallback)
}

nonisolated struct DiffRenderRequest: Sendable {
    let model: DiffPresentationModel
    let scope: DiffPresentationScope
    let prefix: DiffRenderPrefixSource
    let summaryMode: DiffSummaryMode
    let showWhitespace: Bool
    let foldContext: Bool
    let fontSize: CGFloat
    let needsPicker: Bool

    init(
        model: DiffPresentationModel,
        scope: DiffPresentationScope,
        prefix: DiffRenderPrefixSource,
        summaryMode: DiffSummaryMode = .changes,
        showWhitespace: Bool,
        foldContext: Bool = false,
        fontSize: CGFloat,
        needsPicker: Bool
    ) {
        self.model = model
        self.scope = scope
        self.prefix = prefix
        self.summaryMode = summaryMode
        self.showWhitespace = showWhitespace
        self.foldContext = foldContext
        self.fontSize = fontSize
        self.needsPicker = needsPicker
    }
}

nonisolated enum DiffRenderPhase: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed

    init(_ state: SelectedDiffState) {
        self = switch state {
        case .idle: .idle
        case .loading: .loading
        case .loaded: .loaded
        case .failed: .failed
        }
    }

    init(_ state: SelectedCommitState) {
        self = switch state {
        case .idle: .idle
        case .loading: .loading
        case .loaded: .loaded
        case .failed: .failed
        }
    }
}

nonisolated enum DiffContentIdentity: Sendable, Equatable {
    case changes(repositoryID: UUID, kind: DiffKind, paths: [GitPath], fileID: DiffFileID?)
    case history(repositoryID: UUID, commitObjectID: String, fileID: DiffFileID?)
}
