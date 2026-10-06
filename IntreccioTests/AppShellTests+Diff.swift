import AppKit
import XCTest
@testable import Intreccio

extension AppShellTests {
    @MainActor
    func testDiffInspectorPlainTextIsVisibleOnBlackBackground() async throws {
        let controller = DiffInspectorViewController()
        controller.loadView()
        controller.view.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()
        let commit = Commit(
            objectID: String(repeating: "a", count: 40),
            parentIDs: [],
            authorName: "Fixture User",
            authorEmail: "fixture@example.com",
            authoredAt: Date(timeIntervalSince1970: 0),
            subject: "Visible commit subject",
            body: "Visible commit body"
        )
        controller.render(
            mode: .history,
            hasRepository: true,
            hasSelection: false,
            state: .idle,
            commitState: .loaded(CommitDetails(commit: commit, patch: Data(), diff: .empty, comparisonBasis: "empty tree"))
        )
        let textView = try XCTUnwrap(findTextView(in: controller.view))
        try await waitUntil { !textView.isHidden && textView.string.contains("Visible commit subject") }
        let foregroundColor = try XCTUnwrap(textView.textStorage?.attribute(
            NSAttributedString.Key(kCTForegroundColorAttributeName as String),
            at: 0,
            effectiveRange: nil
        ))

        XCTAssertFalse(textView.isHidden)
        XCTAssertGreaterThan(textView.bounds.width, 0)
        XCTAssertGreaterThan(textView.bounds.height, 0)
        XCTAssertTrue(textView.string.contains("Visible commit subject"))
        XCTAssertTrue(textView.string.contains("Visible commit body"))
        XCTAssertFalse(String(describing: foregroundColor).isEmpty)
        XCTAssertEqual(textView.backgroundColor, .black)
    }

    @MainActor
    func testDiffInspectorWrapsAndFiltersMultiFileDiff() async throws {
        let controller = DiffInspectorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()
        func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
            (view as? NSSegmentedControl).map { [$0] } ?? []
                + view.subviews.flatMap { segmentedControls(in: $0) }
        }
        XCTAssertTrue(segmentedControls(in: controller.view).isEmpty)
        XCTAssertEqual(controller.kind, .uncommitted)
        let longPath = "Sources/" + String(repeating: "VeryLongDirectory/", count: 40) + "Second.swift"
        let diff = GitDiff(
            files: [
                makeDiffFile(path: "Sources/First\n====\n.swift", line: "let first = 1"),
                makeDiffFile(path: longPath, line: "let second = 2"),
            ],
            fallback: nil,
            sourceByteCount: 100,
            sourceLineCount: 10
        )

        controller.render(mode: .changes, hasRepository: true, hasSelection: true, state: .loaded(diff), commitState: .idle)

        let textView = try XCTUnwrap(findTextView(in: controller.view))
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let picker = try XCTUnwrap(findPopUpButton(in: controller.view))
        let wrapButton = try XCTUnwrap(findButton(titled: "Word wrap", in: controller.view))
        XCTAssertTrue(try XCTUnwrap(textView.textContainer).widthTracksTextView)
        XCTAssertFalse(scrollView.hasHorizontalScroller)

        try await waitUntil {
            !picker.isHidden
                && picker.numberOfItems == 3
                && textView.string.contains("Sources/First\\n====\\n.swift")
                && textView.string.contains(longPath)
                && textView.string.contains("================================================================")
        }
        XCTAssertEqual(
            picker.itemArray.map(\.title),
            ["All files (2)", "M  Sources/First\\n====\\n.swift", "M  \(longPath)"]
        )
        XCTAssertEqual(
            picker.itemArray.map(\.toolTip),
            ["All files (2)", "M  Sources/First\\n====\\n.swift", "M  \(longPath)"]
        )
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(picker.frame.width, 200)
        XCTAssertLessThanOrEqual(picker.frame.maxX, controller.view.bounds.maxX)
        XCTAssertFalse(textView.string.contains("Sources/First\n====\n.swift"))

        picker.selectItem(at: 1)
        NSApplication.shared.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker)
        try await waitUntil {
            textView.string.contains("Sources/First\\n====\\n.swift") && !textView.string.contains(longPath)
        }
        XCTAssertEqual(picker.toolTip, "M  Sources/First\\n====\\n.swift")

        wrapButton.performClick(nil)
        XCTAssertFalse(try XCTUnwrap(textView.textContainer).widthTracksTextView)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
    }

    @MainActor
    func testDiffInspectorPreservesScrollDuringSameSelectionRefresh() async throws {
        let controller = DiffInspectorViewController()
        controller.loadView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 700, height: 500))
        controller.view.frame = try XCTUnwrap(window.contentView).bounds
        window.contentView?.layoutSubtreeIfNeeded()
        let repositoryID = UUID()
        let path = "Sources/Scrollable.swift"

        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .loaded(makeScrollableDiff(path: path, marker: "before")),
            commitState: .idle,
            diffGeneration: 1,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(path)]
        )

        let textView = try XCTUnwrap(findTextView(in: controller.view))
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertGreaterThan(
            scrollView.contentSize.height,
            100,
            "controllerFrame=\(controller.view.frame) scrollFrame=\(scrollView.frame) clipBounds=\(scrollView.contentView.bounds)"
        )
        try await waitUntil {
            textView.string.contains("before")
                && textView.frame.height > scrollView.contentSize.height + 800
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let originalOrigin = scrollView.contentView.bounds.origin
        XCTAssertGreaterThan(originalOrigin.y, 500)

        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .loading,
            commitState: .idle,
            diffGeneration: 2,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(path)]
        )
        XCTAssertFalse(textView.isHidden)
        XCTAssertTrue(textView.string.contains("before"))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, originalOrigin.y, accuracy: 1)

        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .loaded(makeScrollableDiff(path: path, marker: "after")),
            commitState: .idle,
            diffGeneration: 2,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(path)]
        )
        try await waitUntil { textView.string.contains("after") }
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, originalOrigin.y, accuracy: 1)

        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .failed(.message("permission denied", title: "Could not load diff", recoverySuggestion: "Retry.")),
            commitState: .idle,
            diffGeneration: 3,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(path)]
        )
        XCTAssertFalse(textView.isHidden)
        XCTAssertTrue(textView.string.contains("after"))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, originalOrigin.y, accuracy: 1)

        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .loaded(makeScrollableDiff(path: path, marker: "short", lineCount: 5)),
            commitState: .idle,
            diffGeneration: 4,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(path)]
        )
        try await waitUntil { textView.string.contains("short") }
        XCTAssertGreaterThan(textView.visibleRect.height, 0)

        let otherPath = "Sources/Other.swift"
        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .loaded(makeScrollableDiff(path: otherPath, marker: "other")),
            commitState: .idle,
            diffGeneration: 5,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(otherPath)]
        )
        try await waitUntil { textView.string.contains("other") }
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 1)

        let firstPath = "Sources/First.swift"
        let secondPath = "Sources/Second.swift"
        let firstDiff = makeScrollableDiff(path: firstPath, marker: "first")
        let secondDiff = makeScrollableDiff(path: secondPath, marker: "second")
        let multiFileDiff = GitDiff(
            files: firstDiff.files + secondDiff.files,
            fallback: nil,
            sourceByteCount: firstDiff.sourceByteCount + secondDiff.sourceByteCount,
            sourceLineCount: firstDiff.sourceLineCount + secondDiff.sourceLineCount
        )
        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .loaded(multiFileDiff),
            commitState: .idle,
            diffGeneration: 6,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(firstPath), GitPath(secondPath)]
        )
        let picker = try XCTUnwrap(findPopUpButton(in: controller.view))
        try await waitUntil { picker.numberOfItems == 3 && textView.string.contains("first") && textView.string.contains("second") }
        picker.selectItem(at: 1)
        NSApplication.shared.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker)
        try await waitUntil { textView.string.contains("first") && !textView.string.contains("second") }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let filteredOrigin = scrollView.contentView.bounds.origin

        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .loaded(secondDiff),
            commitState: .idle,
            diffGeneration: 7,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(firstPath), GitPath(secondPath)]
        )
        try await waitUntil { textView.string.contains("second") && !textView.string.contains("first") }
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, filteredOrigin.y, accuracy: 1)
    }

    @MainActor
    func testHistoryDiffUsesColorRendererAndFilePicker() async throws {
        let controller = DiffInspectorViewController()
        controller.loadView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()
        let diff = GitDiff(
            files: [
                makeDiffFile(path: "Sources/First.swift", line: "let first = 1"),
                makeDiffFile(path: "Sources/Second.swift", line: "let second = 2"),
            ],
            fallback: nil,
            sourceByteCount: 100,
            sourceLineCount: 10
        )
        let commit = Commit(
            objectID: String(repeating: "b", count: 40),
            parentIDs: [String(repeating: "a", count: 40)],
            authorName: "Fixture User",
            authorEmail: "fixture@example.com",
            authoredAt: Date(timeIntervalSince1970: 0),
            subject: "Colored history diff",
            body: ""
        )

        controller.render(
            mode: .history,
            hasRepository: true,
            hasSelection: false,
            state: .idle,
            commitState: .loaded(CommitDetails(commit: commit, patch: Data(), diff: diff, comparisonBasis: "first parent"))
        )

        let textView = try XCTUnwrap(findTextView(in: controller.view))
        let picker = try XCTUnwrap(findPopUpButton(in: controller.view))
        try await waitUntil {
            !picker.isHidden
                && picker.numberOfItems == 3
                && textView.string.contains("Colored history diff")
                && textView.string.contains("Sources/First.swift")
                && textView.string.contains("Sources/Second.swift")
                && textView.string.contains("================================================================")
        }
        let textStorage = try XCTUnwrap(textView.textStorage)
        var colors: Set<String> = []
        textStorage.enumerateAttribute(
            NSAttributedString.Key(kCTForegroundColorAttributeName as String),
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, _, _ in
            if let value { colors.insert(String(describing: value)) }
        }
        XCTAssertGreaterThan(colors.count, 1)

        picker.selectItem(at: 2)
        NSApplication.shared.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker)
        try await waitUntil {
            textView.string.contains("Colored history diff")
                && !textView.string.contains(" MODIFIED  Sources/First.swift")
                && textView.string.contains(" MODIFIED  Sources/Second.swift")
        }
    }

    func testDiffFilePickerPreparesMaximumSelectionOffMain() async throws {
        let files = (0..<4_096).map { index in
            DiffFile(path: "Sources/File\(index).bin", originalPath: nil, change: .modified, content: .binary(byteCount: 1))
        }
        let diff = GitDiff(files: files, fallback: nil, sourceByteCount: 0, sourceLineCount: 0)
        let presentationModel = DiffPresentationModel(
            diff: diff,
            snapshotID: DiffSnapshotID(repositoryID: UUID(), revision: UUID())
        )
        let model = await Task.detached {
            DiffPresentationBuilder.filePicker(for: presentationModel)
        }.value

        XCTAssertEqual(model?.entries.count, 4_097)
        XCTAssertEqual(model?.entries.first?.title, "All files (4096)")
        XCTAssertEqual(model?.entries.last?.title, "M  Sources/File4095.bin")
    }

    @MainActor
    func testCancellingLargeCommitRenderSuppressesLatePublication() async throws {
        let controller = DiffInspectorViewController()
        controller.loadView()
        let textView = try XCTUnwrap(findTextView(in: controller.view))
        let commit = Commit(
            objectID: String(repeating: "c", count: 40),
            parentIDs: [],
            authorName: "Fixture User",
            authorEmail: "fixture@example.com",
            authoredAt: Date(timeIntervalSince1970: 0),
            subject: "Large commit",
            body: String(repeating: " ", count: 2 * 1_024 * 1_024) + "body"
        )
        controller.render(
            mode: .history,
            hasRepository: true,
            hasSelection: false,
            state: .idle,
            commitState: .loaded(CommitDetails(commit: commit, patch: Data(), diff: .empty, comparisonBasis: "empty tree"))
        )

        let renderTask = controller.cancelRendering()
        await renderTask?.value
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(textView.isHidden)
        XCTAssertTrue(textView.string.isEmpty)
    }


    @MainActor
    func testDiffInspectorRetainsInteractionStateWhileRefreshing() async throws {
        let controller = DiffInspectorViewController()
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()
        let repositoryID = UUID()
        let path = "Sources/Retained.swift"
        let diff = makeScrollableDiff(path: path, marker: "retained", lineCount: 200)

        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .loaded(diff),
            commitState: .idle,
            diffGeneration: 1,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(path)]
        )
        let textView = try XCTUnwrap(findTextView(in: controller.view))
        try await waitUntil { textView.string.contains("retained") && !textView.isHidden }
        controller.searchField.stringValue = "retained"
        controller.searchChanged(controller.searchField)
        let retainedNavigation = controller.navigation

        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .loading,
            commitState: .idle,
            diffGeneration: 2,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(path)]
        )
        XCTAssertFalse(textView.isHidden)
        XCTAssertEqual(controller.navigation, retainedNavigation)
        XCTAssertEqual(controller.searchResultsLabel.stringValue, "1 of 201")
        XCTAssertFalse(controller.copyRawButton.isEnabled)

        controller.render(
            mode: .changes,
            hasRepository: true,
            hasSelection: true,
            state: .failed(.message("read failed", title: "Could not load diff", recoverySuggestion: "Retry.")),
            commitState: .idle,
            diffGeneration: 2,
            repositoryID: repositoryID,
            selectedPaths: [GitPath(path)]
        )
        XCTAssertFalse(textView.isHidden)
        XCTAssertEqual(controller.navigation, retainedNavigation)
        XCTAssertFalse(controller.openFileButton.isEnabled)
        XCTAssertTrue(controller.copyErrorButton.isHidden == false)
    }
}
