import AppKit
import CoreText
@testable import Intreccio
import XCTest

final class DiffInspectorRenderingTests: XCTestCase {
    func testTextLayoutBuilderPreservesTokenStylesAndVisibleWhitespace() throws {
        let file = DiffFile(
            path: "Sources/Example.swift",
            originalPath: nil,
            change: .modified,
            content: .text([
                DiffHunk(
                    oldRange: DiffRange(start: 0, count: 0),
                    newRange: DiffRange(start: 1, count: 1),
                    heading: "top",
                    lines: [
                        DiffLine(
                            kind: .addition,
                            text: "let\tvalue = \"yes\" // note",
                            oldLineNumber: nil,
                            newLineNumber: 1,
                            hasTrailingNewline: true,
                            tokens: [
                                DiffToken(text: "let", kind: .keyword),
                                DiffToken(text: "\t", kind: .plain),
                                DiffToken(text: "value", kind: .plain),
                                DiffToken(text: " = ", kind: .plain),
                                DiffToken(text: "\"yes\"", kind: .string),
                                DiffToken(text: " // note", kind: .comment)
                            ]
                        )
                    ]
                )
            ])
        )

        let layout = try XCTUnwrap(DiffTextLayoutBuilder.make([file], showWhitespace: true))

        XCTAssertTrue(layout.text.contains("let→···value·=·\"yes\"·//·note\n"))
        XCTAssertTrue(layout.runs.contains { $0.style == .header })
        XCTAssertTrue(layout.runs.contains { $0.style == .hunk })
        XCTAssertTrue(layout.runs.contains { $0.style == .keyword })
        XCTAssertTrue(layout.runs.contains { $0.style == .string })
        XCTAssertTrue(layout.runs.contains { $0.style == .comment })
        XCTAssertTrue(layout.runs.contains { $0.backgroundStyle == .addition })
        XCTAssertTrue(layout.runs.allSatisfy { NSMaxRange($0.range) <= layout.text.utf16.count })
    }

    func testAttributedStringBuilderReusesColorForRepeatedStyleRuns() throws {
        let layout = DiffTextLayout(
            text: "let value let",
            runs: [
                DiffRenderRun(range: NSRange(location: 0, length: 3), style: .keyword),
                DiffRenderRun(range: NSRange(location: 10, length: 3), style: .keyword)
            ]
        )
        let rendered = try XCTUnwrap(DiffAttributedStringBuilder.make(layout))
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let firstColor = rendered.value.attribute(colorKey, at: 0, effectiveRange: nil) as! CGColor
        let secondColor = rendered.value.attribute(colorKey, at: 10, effectiveRange: nil) as! CGColor

        XCTAssertTrue(firstColor === secondColor)
    }

    @MainActor
    func testLargeFilePickerLazilyKeepsEveryPathAndSelection() throws {
        let files = (0..<4_096).map { index in
            DiffFile(
                path: "Sources/File\(index).bin",
                originalPath: nil,
                change: .modified,
                content: .binary(byteCount: 1)
            )
        }
        let presentationModel = DiffPresentationModel(
            diff: GitDiff(files: files, fallback: nil, sourceByteCount: 0, sourceLineCount: 0),
            snapshotID: DiffSnapshotID(repositoryID: UUID(), revision: UUID())
        )
        let model = try XCTUnwrap(DiffPresentationBuilder.filePicker(for: presentationModel))
        let controller = DiffInspectorViewController()
        controller.loadView()
        controller.selectedFileID = model.entries.last?.id

        controller.applyFilePicker(model, mode: .changes, generation: 1)

        XCTAssertEqual(controller.filePickerEntries.dropFirst().map(\.title), files.map { "M  \($0.path)" })
        XCTAssertEqual(controller.filePicker.numberOfItems, files.count + 1)
        XCTAssertLessThan(controller.filePicker.menu?.items.count ?? .max, files.count + 1)
        XCTAssertEqual(controller.filePicker.indexOfSelectedItem, files.count)
        XCTAssertEqual(controller.selectedFileID, model.entries.last?.id)
        XCTAssertEqual(controller.filePicker.titleOfSelectedItem, "M  Sources/File4095.bin")
    }

    func testPresentationBuilderEscapesControlCharactersInFallbackPaths() {
        let fallback = DiffFallback(
            reason: .selectionLimit(maximumFiles: 4, maximumBytes: 128),
            files: [DiffFileSummary(path: "Sources/line\nbreak.swift", originalPath: nil, change: .added)]
        )

        XCTAssertEqual(
            DiffPresentationBuilder.diffFallbackText(fallback),
            "Selection exceeds the safe pathspec limit (4 files or 128 bytes).\n\nSources/line\\nbreak.swift"
        )
    }

    func testFocusedFallbackRendersOnlySelectedSummary() throws {
        let visible = DiffFile(path: "visible.txt", originalPath: nil, change: .modified, content: .text([]))
        let firstMissing = DiffFileSummary(path: "first-missing.txt", originalPath: nil, change: .modified)
        let secondMissing = DiffFileSummary(path: "second-missing.txt", originalPath: nil, change: .modified)
        let diff = GitDiff(
            files: [visible],
            fallback: DiffFallback(reason: .byteLimit(10), files: [firstMissing, secondMissing]),
            sourceByteCount: 11,
            sourceLineCount: 1,
            rawPatch: .mixed(GitRawOutput(bytes: Data("tracked".utf8)))
        )
        let model = DiffPresentationModel(diff: diff, repositoryID: UUID())
        let selectedID = try XCTUnwrap(model.files[1].id)
        let request = DiffRenderRequest(
            model: model,
            scope: .focused(selectedID),
            prefix: .none,
            showWhitespace: false,
            fontSize: 12,
            needsPicker: false
        )

        let rendered = try XCTUnwrap(DiffRenderPreparationBuilder.make(request))
        XCTAssertTrue(rendered.attributed.string.contains("first-missing.txt"))
        XCTAssertFalse(rendered.attributed.string.contains("second-missing.txt"))
    }

    @MainActor
    func testControllerPublishesRepositoryPromptAsViewState() {
        let controller = DiffInspectorViewController()
        controller.loadView()

        controller.render(
            mode: .changes,
            hasRepository: false,
            hasSelection: true,
            state: .idle,
            commitState: .idle
        )

        XCTAssertEqual(controller.stateLabel.stringValue, "Select a repository")
        XCTAssertTrue(controller.stateLabel.isHidden == false)
        XCTAssertTrue(controller.textView.isHidden)
        XCTAssertTrue(controller.textView.string.isEmpty)
        XCTAssertTrue(controller.filePicker.isHidden)
    }
    func testSummaryAndNavigatorExposeStatsAndLimitedFileReasons() throws {
        let textFile = DiffFile(
            path: "added.swift",
            originalPath: nil,
            change: .added,
            content: .text([DiffHunk(
                oldRange: DiffRange(start: 0, count: 0),
                newRange: DiffRange(start: 1, count: 1),
                heading: nil,
                lines: [DiffLine(
                    kind: .addition,
                    text: "let added = true",
                    oldLineNumber: nil,
                    newLineNumber: 1,
                    hasTrailingNewline: true,
                    tokens: []
                )]
            )])
        )
        let oversizedFile = DiffFile(
            path: "large.swift",
            originalPath: nil,
            change: .modified,
            content: .oversized(reason: .lineLimit(maximumLines: 10), byteCount: 11)
        )
        let diff = GitDiff(
            files: [textFile, oversizedFile],
            fallback: DiffFallback(
                reason: .byteLimit(100),
                files: [DiffFileSummary(path: "missing.swift", originalPath: nil, change: .modified)]
            ),
            sourceByteCount: 101,
            sourceLineCount: 11
        )
        let model = DiffPresentationModel(diff: diff, repositoryID: UUID())

        let summary = DiffPresentationBuilder.summary(for: model, mode: .staged)
        XCTAssertEqual(summary.mode, .staged)
        XCTAssertEqual(summary.fileCount, 3)
        XCTAssertNil(summary.additions)
        XCTAssertTrue(summary.notices.contains(.oversized(count: 1, reason: .lineLimit(maximumLines: 10))))
        XCTAssertTrue(summary.notices.contains(.limited(.byteLimit(100))))
        XCTAssertTrue(try XCTUnwrap(summary.statusText).contains("Limited: byte limit"))

        let picker = try XCTUnwrap(DiffPresentationBuilder.filePicker(for: model))
        XCTAssertEqual(picker.entries.count, 4)
        XCTAssertEqual(picker.entries[1].statusText, "A")
        XCTAssertEqual(picker.entries[1].countText, "+1 −0")
        XCTAssertEqual(picker.entries[2].stateText, "Oversized: line limit (11 bytes)")
        XCTAssertEqual(picker.entries[3].stateText, "Limited: byte limit")
        XCTAssertTrue(picker.entries[2].accessibilityText.contains("Oversized"))
    }

    @MainActor
    func testSummaryBarUsesCompactStatusAtBreakpoint() {
        let summary = DiffSummaryModel(
            mode: .unstaged,
            fileCount: 2,
            additions: 4,
            deletions: 1,
            notices: [.unavailable(count: 1)]
        )
        let bar = DiffSummaryBar(frame: NSRect(x: 0, y: 0, width: 959, height: 30))
        bar.apply(summary)
        bar.layoutSubtreeIfNeeded()

        XCTAssertTrue(bar.isCompactLayout)
        XCTAssertEqual(bar.statusLabel.stringValue, "1 unavailable")

        bar.setFrameSize(NSSize(width: 960, height: 30))
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(bar.isCompactLayout)
        XCTAssertEqual(bar.statusLabel.stringValue, "Unavailable: 1")
    }

    @MainActor
    func testSummaryBarKeepsCoreFieldsReadableWithManyNotices() {
        let summary = DiffSummaryModel(
            mode: .history,
            fileCount: 4,
            additions: 12,
            deletions: 8,
            notices: [
                .unavailable(count: 1),
                .oversized(count: 1, reason: .lineLimit(maximumLines: 10)),
                .limited(.byteLimit(100)),
                .metadataTruncated(omittedBytes: 1_000, omittedLines: 20),
                .renderLimited
            ]
        )
        let bar = DiffSummaryBar(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        bar.apply(summary)
        bar.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(bar.modeLabel.frame.width, 1)
        XCTAssertGreaterThan(bar.fileCountLabel.frame.width, 1)
        XCTAssertGreaterThan(bar.additionsLabel.frame.width, 1)
        XCTAssertGreaterThan(bar.deletionsLabel.frame.width, 1)
        XCTAssertEqual(bar.modeLabel.stringValue, "History")
        XCTAssertEqual(bar.fileCountLabel.stringValue, "4 files")
    }

    func testOversizedReasonSurvivesSingletonRenderAndUnavailableMetadataUsesPatchFiles() throws {
        let oversizedFile = DiffFile(
            path: "large.swift",
            originalPath: nil,
            change: .modified,
            content: .oversized(reason: .lineLimit(maximumLines: 10), byteCount: 11)
        )
        let diff = GitDiff(
            files: [oversizedFile],
            fallback: nil,
            sourceByteCount: 11,
            sourceLineCount: 1
        )
        let model = DiffPresentationModel(diff: diff, repositoryID: UUID())
        let request = DiffRenderRequest(
            model: model,
            scope: .allFiles,
            prefix: .none,
            summaryMode: .unstaged,
            showWhitespace: false,
            fontSize: 12,
            needsPicker: true
        )

        let prepared = try XCTUnwrap(DiffRenderPreparationBuilder.make(request))
        XCTAssertTrue(prepared.attributed.string.contains("line limit"))
        XCTAssertTrue(try XCTUnwrap(prepared.summary.statusText).contains("line limit"))
        XCTAssertEqual(prepared.picker?.entries.count, 0)

        let commit = Commit(
            objectID: String(repeating: "b", count: 40),
            parentIDs: [],
            authorName: "Fixture User",
            authorEmail: "fixture@example.com",
            authoredAt: Date(timeIntervalSince1970: 0),
            subject: "Unavailable summaries",
            body: ""
        )
        let metadata = CommitDetailsMetadata(
            body: .complete(""),
            changedFiles: DiffSummaryMetadata(files: [], completeness: .unavailable, omittedFileCount: nil)
        )
        let details = CommitDetails(
            commit: commit,
            rawPatch: GitRawOutput(bytes: Data()),
            diff: diff,
            comparisonBasis: "empty tree",
            metadata: metadata
        )
        let prefix = try XCTUnwrap(DiffPresentationBuilder.commitPrefix(details))
        XCTAssertTrue(prefix.contains("Changed files (1)"))
        XCTAssertTrue(prefix.contains("large.swift"))
        XCTAssertTrue(prefix.contains("Changed-file metadata unavailable"))
    }
    func testCommitPrefixBoundsLargeChangedFileSummary() throws {
        let commit = Commit(
            objectID: String(repeating: "a", count: 40),
            parentIDs: [],
            authorName: "Fixture User",
            authorEmail: "fixture@example.com",
            authoredAt: Date(timeIntervalSince1970: 0),
            subject: "Large summary",
            body: ""
        )
        let summaries = (0..<5_000).map { index in
            DiffFileSummary(path: "Sources/File\(index).swift", originalPath: nil, change: .modified)
        }
        let metadata = CommitDetailsMetadata(
            body: .complete(""),
            changedFiles: DiffSummaryMetadata(files: summaries)
        )
        let details = CommitDetails(
            commit: commit,
            rawPatch: GitRawOutput(bytes: Data()),
            diff: .empty,
            comparisonBasis: "empty tree",
            metadata: metadata
        )

        let prefix = try XCTUnwrap(DiffPresentationBuilder.commitPrefix(details))
        XCTAssertTrue(prefix.contains("Changed files (4096)"))
        XCTAssertTrue(prefix.contains("[904 changed-file summaries omitted]"))
        XCTAssertLessThanOrEqual(prefix.utf8.count, HistoryMetadataLimits.default.maximumSummaryBytes + 1_024)
    }
    func testSearchMatcherReturnsOnlyDisplayedRanges() {
        let matches = DiffSearchMatcher.matches(
            in: "Visible line\ncontext folded; use Show All Context\nVisible again",
            query: "visible"
        )

        XCTAssertEqual(matches, [
            NSRange(location: 0, length: 7),
            NSRange(location: 50, length: 7)
        ])
    }

    func testFileNavigatorCyclesOnlyActualFiles() {
        XCTAssertEqual(DiffFileNavigator.targetIndex(selectedIndex: 1, entryCount: 3, offset: -1), 2)
        XCTAssertEqual(DiffFileNavigator.targetIndex(selectedIndex: 2, entryCount: 3, offset: 1), 1)
        XCTAssertEqual(DiffFileNavigator.targetIndex(selectedIndex: 0, entryCount: 3, offset: 1), 1)
        XCTAssertEqual(DiffFileNavigator.targetIndex(selectedIndex: 0, entryCount: 3, offset: -1), 2)
        XCTAssertNil(DiffFileNavigator.targetIndex(selectedIndex: 1, entryCount: 2, offset: 1))
    }

    func testContextFoldingKeepsNavigationTargetsAndRevealText() throws {
        let contextLines = (0..<6).map { index in
            DiffLine(
                kind: .context,
                text: "context" + String(index),
                oldLineNumber: index + 1,
                newLineNumber: index + 1,
                hasTrailingNewline: true,
                tokens: []
            )
        }
        let addition = DiffLine(
            kind: .addition,
            text: "added",
            oldLineNumber: nil,
            newLineNumber: 7,
            hasTrailingNewline: true,
            tokens: []
        )
        let file = DiffFile(
            path: "folded.swift",
            originalPath: nil,
            change: .modified,
            content: .text([DiffHunk(
                oldRange: DiffRange(start: 1, count: 7),
                newRange: DiffRange(start: 1, count: 7),
                heading: nil,
                lines: contextLines + [addition]
            )])
        )

        let folded = try XCTUnwrap(DiffTextLayoutBuilder.make(
            [file],
            showWhitespace: false,
            foldContext: true
        ))
        XCTAssertEqual(folded.navigation.hunks.count, 1)
        XCTAssertEqual(folded.navigation.lines.count, 3)
        XCTAssertEqual(folded.navigation.foldedContexts.map(\.count), [4])
        XCTAssertTrue(folded.text.contains("4 context lines folded"))

        let revealed = try XCTUnwrap(DiffTextLayoutBuilder.make(
            [file],
            showWhitespace: false,
            foldContext: false
        ))
        XCTAssertTrue(revealed.navigation.foldedContexts.isEmpty)
        XCTAssertEqual(revealed.navigation.lines.count, 7)
        XCTAssertFalse(revealed.text.contains("context lines folded"))
    }

    func testAccessibilityModelExposesFileHunkLineAndFoldedState() throws {
        let hunk = DiffHunk(
            oldRange: DiffRange(start: 1, count: 5),
            newRange: DiffRange(start: 1, count: 5),
            heading: "function",
            lines: [
                DiffLine(kind: .context, text: "one", oldLineNumber: 1, newLineNumber: 1, hasTrailingNewline: true, tokens: []),
                DiffLine(kind: .context, text: "two", oldLineNumber: 2, newLineNumber: 2, hasTrailingNewline: true, tokens: []),
                DiffLine(kind: .context, text: "three", oldLineNumber: 3, newLineNumber: 3, hasTrailingNewline: true, tokens: []),
                DiffLine(kind: .context, text: "four", oldLineNumber: 4, newLineNumber: 4, hasTrailingNewline: true, tokens: []),
                DiffLine(kind: .addition, text: "five", oldLineNumber: nil, newLineNumber: 5, hasTrailingNewline: true, tokens: [])
            ]
        )
        let model = DiffPresentationModel(
            diff: GitDiff(files: [DiffFile(path: "accessible.swift", originalPath: nil, change: .modified, content: .text([hunk]))], fallback: nil, sourceByteCount: 0, sourceLineCount: 0),
            repositoryID: UUID()
        )

        let root = DiffAccessibilityBuilder.make(for: model, foldContext: true)
        XCTAssertEqual(root.kind, DiffAccessibilityNodeKind.root)
        let fileNode = try XCTUnwrap(root.children.first)
        XCTAssertEqual(fileNode.kind, DiffAccessibilityNodeKind.file)
        let hunkNode = try XCTUnwrap(fileNode.children.first)
        XCTAssertEqual(hunkNode.kind, DiffAccessibilityNodeKind.hunk)
        XCTAssertTrue(hunkNode.children.contains { node in node.kind == DiffAccessibilityNodeKind.line })
        XCTAssertTrue(hunkNode.children.contains { node in node.kind == DiffAccessibilityNodeKind.foldedContext })
    }

    func testLimitedAccessibilityRetainsAggregateFallbackReason() throws {
        let visibleFile = DiffFile(path: "visible.swift", originalPath: nil, change: .modified, content: .text([]))
        let omittedSummary = DiffFileSummary(path: "omitted.swift", originalPath: nil, change: .modified)
        let diff = GitDiff(
            files: [visibleFile],
            fallback: DiffFallback(reason: .byteLimit(100), files: [omittedSummary]),
            sourceByteCount: 101,
            sourceLineCount: 1
        )
        let model = DiffPresentationModel(diff: diff, repositoryID: UUID())

        let root = DiffAccessibilityBuilder.make(
            for: model,
            scope: .allFiles,
            foldContext: false,
            renderLimited: true
        )
        let omittedNode = try XCTUnwrap(root.children.last)
        XCTAssertTrue(omittedNode.children.contains { $0.label == "Diff fallback" })
        XCTAssertTrue(omittedNode.children.contains { $0.label == "Diff display limited" })
    }
    func testRawCopyAvailabilityDistinguishesExactAndNonExactSources() {
        let complete = GitRawOutput(bytes: Data([0, 1, 2]))
        let incomplete = GitRawOutput(bytes: Data([0]), completeness: .truncated(limit: 1))

        XCTAssertEqual(DiffRawCopyAvailability(.git(complete)), .exact)
        XCTAssertEqual(DiffRawCopyAvailability(.git(incomplete)), .incomplete)
        XCTAssertEqual(DiffRawCopyAvailability(.synthetic), .synthetic)
        XCTAssertEqual(DiffRawCopyAvailability(.mixed(complete)), .mixed)
        XCTAssertEqual(DiffRawCopyAvailability(.mixed(incomplete)), .mixedIncomplete)
        XCTAssertFalse(DiffRawCopyAvailability(.synthetic).failureMessage.isEmpty)
        XCTAssertTrue(DiffRawCopyAvailability(.mixed(incomplete)).failureMessage.contains("truncated"))
        XCTAssertFalse(DiffFileUnavailableReason.invalidPath.isRetryable)
        XCTAssertTrue(DiffFileUnavailableReason.changedDuringRead.isRetryable)
    }

    @MainActor
    func testControllerCopiesDisplayedTextAndCompleteRawBytesSeparately() {
        let raw = Data([0, 255, 1])
        let file = DiffFile(path: "copy.swift", originalPath: nil, change: .modified, content: .text([]))
        let model = DiffPresentationModel(
            diff: GitDiff(files: [file], fallback: nil, sourceByteCount: raw.count, sourceLineCount: 1, rawPatch: .git(GitRawOutput(bytes: raw))),
            repositoryID: UUID()
        )
        let controller = DiffInspectorViewController()
        controller.loadView()
        controller.currentPresentationModel = model
        controller.textView.string = "displayed diff"
        controller.textView.isHidden = false

        controller.copyDisplayedDiff(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "displayed diff")
        controller.copyRawPatch(nil)
        XCTAssertEqual(
            NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("public.data")),
            raw
        )

        var action: DiffFileAction?
        controller.onFileAction = { action = $0 }
        controller.openSelectedFile(controller.openFileButton)
        XCTAssertEqual(action, .open(GitPath("copy.swift")))

        guard let displayedItem = controller.textView.menu?.items.first(where: { $0.title == "Copy Displayed Diff" }) else {
            XCTFail("Expected displayed-copy context menu item.")
            return
        }
        XCTAssertTrue(controller.validateMenuItem(displayedItem))
        controller.displayedFailure = .message("failure", title: "Failed", recoverySuggestion: "Retry")
        controller.copyDisplayedDiff(nil)
        XCTAssertTrue(controller.copyStatusLabel.stringValue.contains("unavailable"))
        XCTAssertFalse(controller.validateMenuItem(displayedItem))
    }
}
