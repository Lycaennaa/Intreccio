import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testToolbarItemsStayBesideWindowTitle() throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        let windowController = MainWindowController(coordinator: coordinator)
        let items = try XCTUnwrap(windowController.window?.toolbar).items
        let customItems = items.filter { $0.itemIdentifier != .toggleSidebar }

        XCTAssertFalse(customItems.isEmpty)
        XCTAssertTrue(customItems.allSatisfy(\.isNavigational))
        XCTAssertTrue(customItems.filter { $0.action != nil }.allSatisfy { $0.target === windowController.commandRouter })
        XCTAssertFalse(items.map(\.itemIdentifier).contains(.flexibleSpace))
    }
    @MainActor
    func testShowingSettingsPreservesMainWindowSize() async throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        let windowController = MainWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(windowController.window)
        window.setContentSize(NSSize(width: 1_200, height: 760))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let originalFrame = window.frame

        windowController.settingsPresenter.present()
        try await waitUntil(description: "settings test coordinator startup") { windowController.restoredWindowState }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        let settingsPanel = try XCTUnwrap(windowController.settingsPresenter.presentedPanel)
        let settingsFrame = window.contentRect(forFrameRect: window.frame)
        XCTAssertEqual(window.frame.size.width, originalFrame.size.width, accuracy: 1)
        XCTAssertEqual(window.frame.size.height, originalFrame.size.height, accuracy: 1)
        XCTAssertEqual(settingsPanel.frame.origin.x, settingsFrame.origin.x, accuracy: 1)
        XCTAssertEqual(settingsPanel.frame.origin.y, settingsFrame.origin.y, accuracy: 1)
        XCTAssertEqual(settingsPanel.frame.size.width, settingsFrame.size.width, accuracy: 1)
        XCTAssertEqual(settingsPanel.frame.size.height, settingsFrame.size.height, accuracy: 1)
        XCTAssertTrue(window.isVisible)
        window.setContentSize(NSSize(width: 1_200, height: 200))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThanOrEqual(window.contentView?.bounds.height ?? 0, 460)
        let resizedSettingsFrame = window.contentRect(forFrameRect: window.frame)
        XCTAssertEqual(settingsPanel.frame.size.width, resizedSettingsFrame.size.width, accuracy: 1)
        XCTAssertEqual(settingsPanel.frame.size.height, resizedSettingsFrame.size.height, accuracy: 1)

        windowController.settingsPresenter.dismiss()

        XCTAssertFalse(window.childWindows?.contains { $0 === settingsPanel } ?? false)
        XCTAssertEqual(window.frame.size.width, originalFrame.size.width, accuracy: 1)
        XCTAssertEqual(window.frame.size.height, originalFrame.size.height, accuracy: 1)
        window.orderOut(nil)
    }

    func testSplitViewItemsUseDraggableHoldingPriorities() throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        let windowController = MainWindowController(coordinator: coordinator)
        let splitViewController = windowController.contentController

        XCTAssertEqual(splitViewController.splitView.autosaveName, "MainWindowSplitView")
        for item in splitViewController.splitViewItems {
            XCTAssertLessThan(item.holdingPriority, .dragThatCannotResizeWindow)
        }
    }
}
