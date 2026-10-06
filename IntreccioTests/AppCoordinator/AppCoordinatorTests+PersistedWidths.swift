import AppKit
import Foundation
import XCTest
@testable import Intreccio

extension AppCoordinatorTests {
    func testLoadedStateRestoresPersistedSplitWidths() async throws {
        let directory = try makeTestDirectory()
        let stateStore = StateStore(fileURL: directory.appendingPathComponent("state.json"))
        let frame = NSRect(x: 100, y: 100, width: 1_400, height: 760)
        try await stateStore.save(PersistedState(uiState: PersistedUIState(
            sidebarWidth: 300,
            changesListWidth: 420,
            windowFrame: NSStringFromRect(frame)
        )))
        let coordinator = AppCoordinator(stateStore: stateStore)
        let windowController = MainWindowController(coordinator: coordinator)
        let splitViewController = windowController.contentController

        try await waitUntil(description: "restored persisted window state") { windowController.restoredWindowState }
        windowController.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(splitViewController.splitViewItems[0].viewController.view.frame.width, 300, accuracy: 1)
        XCTAssertEqual(splitViewController.splitViewItems[1].viewController.view.frame.width, 420, accuracy: 1)
    }

    func testLoadedStateDoesNotResetUserAdjustedSplitPosition() async throws {
        let directory = try makeTestDirectory()
        let stateStore = StateStore(fileURL: directory.appendingPathComponent("state.json"))
        try await stateStore.save(PersistedState(uiState: PersistedUIState(sidebarWidth: 300, changesListWidth: 300)))
        let coordinator = AppCoordinator(stateStore: stateStore)
        let windowController = MainWindowController(coordinator: coordinator)
        let splitViewController = windowController.contentController
        let splitView = splitViewController.splitView
        windowController.window?.setContentSize(NSSize(width: 1_400, height: 760))
        windowController.window?.contentView?.layoutSubtreeIfNeeded()
        let listView = splitViewController.splitViewItems[1].viewController.view
        let initialWidth = listView.frame.width
        let sidebarWidth = splitViewController.splitViewItems[0].viewController.view.frame.width
        splitView.setPosition(sidebarWidth + splitView.dividerThickness + initialWidth + 100, ofDividerAt: 1)
        splitView.layoutSubtreeIfNeeded()
        let adjustedWidth = listView.frame.width
        XCTAssertGreaterThan(adjustedWidth, initialWidth + 50)

        try await waitUntil(description: "restored persisted window state") { windowController.restoredWindowState }
        windowController.window?.contentView?.layoutSubtreeIfNeeded()

        let sidebarView = splitViewController.splitViewItems[0].viewController.view
        XCTAssertEqual(sidebarView.frame.width, 300, accuracy: 1)
        XCTAssertEqual(listView.frame.width, adjustedWidth, accuracy: 1)
        let flushed = await coordinator.flushState()
        XCTAssertTrue(flushed)
        let persisted = await stateStore.load()
        let persistedWidth = try XCTUnwrap(persisted.state.uiState.changesListWidth)
        XCTAssertEqual(persisted.state.uiState.sidebarWidth, 300, accuracy: 1)
        XCTAssertEqual(CGFloat(persistedWidth), adjustedWidth, accuracy: 1)
    }

    func testPreLoadWindowResizeDoesNotSuppressPersistedSplitWidths() async throws {
        let directory = try makeTestDirectory()
        let stateStore = StateStore(fileURL: directory.appendingPathComponent("state.json"))
        try await stateStore.save(PersistedState(uiState: PersistedUIState(sidebarWidth: 300, changesListWidth: 420)))
        let coordinator = AppCoordinator(stateStore: stateStore)
        let windowController = MainWindowController(coordinator: coordinator)
        let splitViewController = windowController.contentController
        windowController.window?.setContentSize(NSSize(width: 1_400, height: 700))
        windowController.window?.contentView?.layoutSubtreeIfNeeded()

        try await waitUntil(description: "restored persisted window state") { windowController.restoredWindowState }
        windowController.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(splitViewController.splitViewItems[0].viewController.view.frame.width, 300, accuracy: 1)
        XCTAssertEqual(splitViewController.splitViewItems[1].viewController.view.frame.width, 420, accuracy: 1)
    }

    func testLoadedStatePreservesAdjustedSidebarAndRestoresListWidth() async throws {
        let directory = try makeTestDirectory()
        let stateStore = StateStore(fileURL: directory.appendingPathComponent("state.json"))
        try await stateStore.save(PersistedState(uiState: PersistedUIState(sidebarWidth: 220, changesListWidth: 420)))
        let coordinator = AppCoordinator(stateStore: stateStore)
        let windowController = MainWindowController(coordinator: coordinator)
        let splitViewController = windowController.contentController
        let splitView = splitViewController.splitView
        windowController.window?.setContentSize(NSSize(width: 1_400, height: 760))
        windowController.window?.contentView?.layoutSubtreeIfNeeded()
        let sidebarView = splitViewController.splitViewItems[0].viewController.view
        let initialSidebarWidth = sidebarView.frame.width
        splitView.setPosition(initialSidebarWidth + 80, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        let adjustedSidebarWidth = sidebarView.frame.width
        XCTAssertGreaterThan(adjustedSidebarWidth, initialSidebarWidth + 50)

        try await waitUntil(description: "restored persisted window state") { windowController.restoredWindowState }
        windowController.window?.contentView?.layoutSubtreeIfNeeded()

        let listView = splitViewController.splitViewItems[1].viewController.view
        XCTAssertEqual(sidebarView.frame.width, adjustedSidebarWidth, accuracy: 1)
        XCTAssertEqual(listView.frame.width, 420, accuracy: 1)
        let flushed = await coordinator.flushState()
        XCTAssertTrue(flushed)
        let persisted = await stateStore.load()
        XCTAssertEqual(persisted.state.uiState.sidebarWidth, adjustedSidebarWidth, accuracy: 1)
        XCTAssertEqual(persisted.state.uiState.changesListWidth, 420)
    }
}