import AppKit
@testable import Intreccio
import XCTest

private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in
        [item] + (item.submenu.map { allMenuItems(in: $0) } ?? [])
    }
}

@MainActor
private func allDescendantViews(in view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { allDescendantViews(in: $0) }
}

@MainActor
private final class ContextMenuTestDelegate: NSObject, NSMenuDelegate {
    private weak var original: NSMenuDelegate?

    init(original: NSMenuDelegate?) {
        self.original = original
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        original?.menuNeedsUpdate?(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.cancelTracking()
    }
}
@MainActor
private func rightClickMenu(for tableView: NSTableView, row: Int = 0, in window: NSWindow) throws -> NSMenu {
    let menu = try XCTUnwrap(tableView.menu)
    let rowRect = tableView.rect(ofRow: row)
    let contentView = try XCTUnwrap(window.contentView)
    let contentPoint = tableView.convert(
        NSPoint(x: rowRect.midX, y: rowRect.midY),
        to: contentView
    )
    let screenPoint = window.convertToScreen(NSRect(origin: contentPoint, size: .zero)).origin
    let event = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: screenPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )
    let originalDelegate = menu.delegate
    let cancellationDelegate = ContextMenuTestDelegate(original: originalDelegate)
    menu.delegate = cancellationDelegate
    defer { menu.delegate = originalDelegate }
    tableView.rightMouseDown(with: event)
    return menu
}
extension AppShellTests {
    @MainActor
    func testTemplateWasReplacedByThreeColumnBlackAppKitShell() throws {
        let directory = try makeTestDirectory()
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json"))
        )
        let windowController = MainWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(windowController.window)
        let contentController = windowController.contentController
        let toolbar = try XCTUnwrap(window.toolbar)
        let toolbarActions = toolbar.items.compactMap(\.action)
        let addSourcesItem = try XCTUnwrap(
            toolbar.items.first { $0.itemIdentifier.rawValue == "AddSources" } as? NSMenuToolbarItem
        )
        let addSourcesMenuItems = try XCTUnwrap(addSourcesItem.menu).items
        let previousMainMenu = NSApp.mainMenu
        defer {
            NSApp.mainMenu = previousMainMenu
            window.close()
        }

        AppDelegate().configureMainMenu(target: windowController.commandRouter)
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let menuItems = allMenuItems(in: mainMenu)

        XCTAssertTrue(window.contentViewController === contentController)
        XCTAssertEqual(contentController.splitViewItems.count, 3)
        XCTAssertEqual(window.backgroundColor, .black)
        XCTAssertTrue(window.isOpaque)
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(toolbar.items.filter { $0 is NSMenuToolbarItem }.count, 3)
        XCTAssertTrue(toolbarActions.contains(#selector(MainWindowCommandRouter.showDownloads(_:))))
        let toolbarItemIDs = toolbar.items.map(\.itemIdentifier.rawValue)
        let downloadsIndex = try XCTUnwrap(toolbarItemIDs.firstIndex(of: "Downloads"))
        let settingsIndex = try XCTUnwrap(toolbarItemIDs.firstIndex(of: "Settings"))
        XCTAssertEqual(downloadsIndex + 1, settingsIndex)
        let sourceMenuContracts: [(title: String, action: Selector)] = [
            ("Add Root Folder…", #selector(MainWindowCommandRouter.addFolder(_:))),
            ("Add Repository…", #selector(MainWindowCommandRouter.addRepository(_:))),
            ("Create Local Repository…", #selector(MainWindowCommandRouter.createLocalRepository(_:))),
            ("Clone Repository…", #selector(MainWindowCommandRouter.cloneRepository(_:)))
        ]
        XCTAssertEqual(addSourcesMenuItems.count, sourceMenuContracts.count)
        for contract in sourceMenuContracts {
            let item = try XCTUnwrap(
                addSourcesMenuItems.first { $0.title == contract.title },
                "Missing toolbar add action: \(contract.title)"
            )
            XCTAssertEqual(item.action, contract.action)
            XCTAssertTrue(item.target === windowController.commandRouter)
        }

        let refreshToolbarItem = try XCTUnwrap(
            toolbar.items.first { $0.itemIdentifier.rawValue == "RefreshActions" } as? NSMenuToolbarItem
        )
        let refreshMenuItems = try XCTUnwrap(refreshToolbarItem.menu).items
        let refreshMenuContracts: [(title: String, action: Selector)] = [
            ("Refresh Repository", #selector(MainWindowCommandRouter.refresh(_:))),
            ("Rescan All Sources", #selector(MainWindowCommandRouter.rescan(_:)))
        ]
        XCTAssertEqual(refreshMenuItems.map(\.title), refreshMenuContracts.map(\.title))
        for (item, contract) in zip(refreshMenuItems, refreshMenuContracts) {
            XCTAssertEqual(item.action, contract.action)
            XCTAssertTrue(item.target === windowController.commandRouter)
        }

        let viewToolbarItem = try XCTUnwrap(
            toolbar.items.first { $0.itemIdentifier.rawValue == "ViewMode" } as? NSMenuToolbarItem
        )
        let viewMenuItems = try XCTUnwrap(viewToolbarItem.menu).items
        let viewMenuContracts: [(title: String, action: Selector)] = [
            ("Changes", #selector(MainWindowCommandRouter.showChanges(_:))),
            ("History", #selector(MainWindowCommandRouter.showHistory(_:)))
        ]
        XCTAssertEqual(viewMenuItems.map(\.title), viewMenuContracts.map(\.title))
        for (item, contract) in zip(viewMenuItems, viewMenuContracts) {
            XCTAssertEqual(item.action, contract.action)
            XCTAssertTrue(item.target === windowController.commandRouter)
        }
        let expectedAnimation: NSWindow.AnimationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .none
            : .documentWindow
        XCTAssertEqual(window.animationBehavior, expectedAnimation)
        let menuContracts: [(title: String, action: Selector)] = [
            ("Add Root Folder…", #selector(MainWindowCommandRouter.addFolder(_:))),
            ("Stage Selected", #selector(MainWindowCommandRouter.stageSelected(_:))),
            ("Unstage Selected", #selector(MainWindowCommandRouter.unstageSelected(_:))),
            ("Stash All Changes", #selector(MainWindowCommandRouter.stashChanges(_:))),
            ("Restore Latest Stash", #selector(MainWindowCommandRouter.restoreLatestStash(_:))),
            ("Focus Search", #selector(MainWindowCommandRouter.focusSearch(_:))),
            ("Create Local Repository…", #selector(MainWindowCommandRouter.createLocalRepository(_:))),
            ("Clone Repository…", #selector(MainWindowCommandRouter.cloneRepository(_:))),
            ("Downloads", #selector(MainWindowCommandRouter.showDownloads(_:)))
        ]
        for contract in menuContracts {
            let item = try XCTUnwrap(
                menuItems.first { $0.title == contract.title },
                "Missing runtime menu item: \(contract.title)"
            )
            XCTAssertEqual(item.action, contract.action)
            XCTAssertTrue(item.target === windowController.commandRouter)
        }

        let contentView = try XCTUnwrap(window.contentView)
        XCTAssertFalse(allDescendantViews(in: contentView).contains { $0 is NSVisualEffectView })
    }

    @MainActor
    func testDiscardChangesPresentsWarningDestructiveConfirmationAtRuntime() throws {
        let directory = try makeTestDirectory()
        let repositoryID = UUID()
        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID
        var status = RepoStatus()
        let change = FileChange(
            path: "tracked.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )
        status.changes = [change]
        coordinator.runtime.handleRefreshEvent(
            .completed(RefreshKey(repositoryID: repositoryID, kind: .status), 1, status)
        )

        let controller = ChangesViewController(coordinator: coordinator)
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 500))
        controller.view.frame = try XCTUnwrap(window.contentView).bounds
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.sheets.first { window.endSheet(sheet) }
            window.orderOut(nil)
        }

        controller.reload()
        window.contentView?.layoutSubtreeIfNeeded()
        let outlineView = try XCTUnwrap(
            allDescendantViews(in: controller.view).compactMap { $0 as? NSOutlineView }.first
        )
        let changeRow = try XCTUnwrap((0..<outlineView.numberOfRows).first { row in
            guard let node = outlineView.item(atRow: row) as? ChangesViewController.Node else { return false }
            if case .changes = node.kind { return true }
            return false
        })
        outlineView.selectRowIndexes(IndexSet(integer: changeRow), byExtendingSelection: false)

        let menu = try rightClickMenu(for: outlineView, row: changeRow, in: window)
        controller.menuNeedsUpdate(menu)
        let discardItem = try XCTUnwrap(menu.items.first { $0.title == "Discard Changes…" })
        XCTAssertTrue(discardItem.isEnabled)
        controller.mutationController.discardChange(discardItem)

        let sheet = try XCTUnwrap(window.sheets.first)
        let sheetContentView = try XCTUnwrap(sheet.contentView)
        sheetContentView.layoutSubtreeIfNeeded()
        let alertViews = allDescendantViews(in: sheetContentView)
        let textValues = alertViews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(textValues.contains { $0.contains("Discard changes to this file?") })
        XCTAssertTrue(textValues.contains { $0.contains("This cannot be undone.") })
        let discardButton = try XCTUnwrap(
            alertViews.compactMap { $0 as? NSButton }.first { $0.title == "Discard Changes" }
        )
        XCTAssertTrue(discardButton.hasDestructiveAction)
        let alertHasIcon = alertViews.contains { view in
            guard let imageView = view as? NSImageView else { return false }
            return imageView.image != nil
        }
        XCTAssertTrue(alertHasIcon)
    }

    @MainActor
    func testHistoryContextMenuProvidesAmendActionAtRuntime() throws {
        let directory = try makeTestDirectory()
        let repositoryID = UUID()
        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID
        coordinator.state.uiState.mode = .history
        let commit = Commit(
            objectID: String(repeating: "a", count: 40),
            parentIDs: [],
            authorName: "Fixture User",
            authorEmail: "fixture@example.com",
            authoredAt: Date(timeIntervalSince1970: 0),
            subject: "Fixture commit",
            body: ""
        )
        coordinator.selectedHistoryState = SelectedHistoryState(
            scope: .mixed,
            commits: [commit],
            tips: HistoryTips(localObjectID: commit.objectID, upstreamObjectID: nil),
            phase: .idle,
            reachedEnd: true,
            reachedLimit: false
        )
        coordinator.publish()

        let controller = HistoryViewController(coordinator: coordinator)
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 500))
        controller.view.frame = try XCTUnwrap(window.contentView).bounds
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        controller.reload()
        window.contentView?.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(
            allDescendantViews(in: controller.view).compactMap { $0 as? NSTableView }.first
        )
        XCTAssertEqual(tableView.numberOfRows, 1)
        let menu = try rightClickMenu(for: tableView, in: window)
        controller.menuNeedsUpdate(menu)

        let amendItem = try XCTUnwrap(menu.items.first { $0.title == "Amend Commit" })
        XCTAssertTrue(amendItem.isEnabled)
        XCTAssertTrue(amendItem.target === controller)
        XCTAssertEqual(amendItem.action.map(NSStringFromSelector), "amendCommit:")
    }

    @MainActor
    func testHistoryContentSwitchRestoresDiffInspector() throws {
        let directory = try makeTestDirectory()
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json"))
        )
        coordinator.setMode(.history)
        let windowController = MainWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(windowController.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let contentController = windowController.contentController
        contentController.refresh(coordinator.snapshot)
        let detailController = try XCTUnwrap(contentController.splitViewItems.last?.viewController)
        let header = try XCTUnwrap(
            allDescendantViews(in: contentController.view).compactMap { $0 as? HistoryHeaderView }.first
        )
        XCTAssertTrue(detailController.children.first is DiffInspectorViewController)

        header.contentControl.selectedSegment = 1
        let contentAction = try XCTUnwrap(header.contentControl.action)
        XCTAssertTrue(
            NSApplication.shared.sendAction(
                contentAction,
                to: header.contentControl.target,
                from: header.contentControl
            )
        )
        XCTAssertTrue(detailController.children.first is BranchFileInspectorViewController)

        header.contentControl.selectedSegment = 0
        XCTAssertTrue(
            NSApplication.shared.sendAction(
                contentAction,
                to: header.contentControl.target,
                from: header.contentControl
            )
        )
        XCTAssertTrue(detailController.children.first is DiffInspectorViewController)
    }

    @MainActor
    func testQuitDuringMutationPresentsWaitAndCancelActionsAtRuntime() throws {
        let directory = try makeTestDirectory()
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json"))
        )
        let windowController = MainWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(windowController.window)
        window.makeKeyAndOrderFront(nil)
        let appDelegate = AppDelegate()
        appDelegate.mainWindowController = windowController
        let activeMutation = Task<Void, Never> { }
        coordinator.mutationTask = activeMutation
        defer {
            activeMutation.cancel()
            coordinator.mutationTask = nil
            if let sheet = window.sheets.first { window.endSheet(sheet) }
            window.orderOut(nil)
        }

        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApp), .terminateLater)
        let sheet = try XCTUnwrap(window.sheets.first)
        let sheetContentView = try XCTUnwrap(sheet.contentView)
        sheetContentView.layoutSubtreeIfNeeded()
        let buttonTitles = allDescendantViews(in: sheetContentView)
            .compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(buttonTitles.contains("Wait and Quit"))
        XCTAssertTrue(buttonTitles.contains("Cancel Quit"))
    }
    @MainActor
    func testCommitComposerUsesSummaryAndDescriptionFields() throws {
        let coordinator = AppCoordinator()
        coordinator.setCommitMessage("Add commit title field\n\nOptional details")
        let controller = ChangesViewController(coordinator: coordinator)
        controller.loadView()
        controller.reload()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()

        let summary = try XCTUnwrap(findTextView(containing: "Add commit title field", in: controller.view))
        let description = try XCTUnwrap(findTextView(containing: "Optional details", in: controller.view))
        let summaryScrollView = try XCTUnwrap(summary.enclosingScrollView)
        let overflowLabel = try XCTUnwrap(findTextField(value: "Scroll for more", in: controller.view))
        let singleLineHeight = summaryScrollView.frame.height
        XCTAssertEqual(summary.string, "Add commit title field")
        XCTAssertEqual(description.string, "Optional details")
        XCTAssertTrue(summaryScrollView.hasVerticalScroller)
        XCTAssertTrue(overflowLabel.isHidden)
        XCTAssertFalse(description.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(description.isAutomaticSpellingCorrectionEnabled)
        summary.isEditable = true

        summary.string = "Updated title"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: summary))
        XCTAssertEqual(coordinator.commitMessage, "Updated title\n\nOptional details")

        description.string = "Updated details"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: description))
        XCTAssertEqual(coordinator.commitMessage, "Updated title\n\nUpdated details")

        summary.setSelectedRange(NSRange(location: 0, length: (summary.string as NSString).length))
        summary.insertText("Pasted title\r\nwith newline", replacementRange: summary.selectedRange())
        XCTAssertEqual(summary.string, "Pasted title with newline")
        XCTAssertEqual(coordinator.commitMessage, "Pasted title with newline\n\nUpdated details")

        summary.string = "ab"
        summary.undoManager?.removeAllActions()
        summary.setSelectedRange(NSRange(location: 1, length: 0))
        summary.insertText("\r\n", replacementRange: summary.selectedRange())
        XCTAssertEqual(summary.string, "a b")
        XCTAssertEqual(summary.selectedRange(), NSRange(location: 2, length: 0))
        summary.undoManager?.undo()
        XCTAssertEqual(summary.string, "ab")

        summary.string = String(repeating: "Long commit summary ", count: 8)
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: summary))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(summaryScrollView.frame.height, singleLineHeight)
        XCTAssertLessThan(summaryScrollView.frame.height, 80)
        XCTAssertGreaterThan(summary.frame.height, summaryScrollView.contentSize.height)
        XCTAssertFalse(overflowLabel.isHidden)

        window.setContentSize(NSSize(width: 1_000, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThan(summaryScrollView.frame.height, 50)
        XCTAssertTrue(overflowLabel.isHidden)

        summary.setSelectedRange(NSRange(location: 0, length: (summary.string as NSString).length))
        summary.insertText(String(repeating: "x", count: 10_000), replacementRange: summary.selectedRange())
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual((summary.string as NSString).length, 4_096)
        XCTAssertTrue(overflowLabel.stringValue.contains("4,096 character limit reached"))
        XCTAssertLessThan(summaryScrollView.frame.height, 80)

        summary.selectAll(nil)
        summary.insertText("new", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(summary.string, "new")

        summary.string = String(repeating: "x", count: 4_095)
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: summary))
        summary.setSelectedRange(NSRange(location: 4_095, length: 0))
        summary.insertText("😀", replacementRange: summary.selectedRange())
        XCTAssertEqual((summary.string as NSString).length, 4_095)
        XCTAssertTrue(overflowLabel.stringValue.contains("4,096 character limit reached"))
    }

    @MainActor
    func testChangeFilenameReexpandsWhenCellWidens() throws {
        let cell = ChangesViewController.makeChangeCell(
            title: "Sources/Features/Repository/LongFileName.swift",
            badgeText: ".M"
        )
        cell.frame = NSRect(x: 0, y: 0, width: 150, height: 24)
        cell.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(cell.textField)
        let narrowWidth = label.frame.width

        cell.frame.size.width = 500
        cell.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(label.frame.width, narrowWidth)
        XCTAssertGreaterThanOrEqual(label.frame.width, label.intrinsicContentSize.width)
    }

}
