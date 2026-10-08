import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testSelectingCurrentModeDoesNotRepublish() {
        let coordinator = makeCoordinator(stateFile: URL(fileURLWithPath: "/unused"))
        var publishCount = 0
        let subscriptionID = coordinator.addSnapshotHandler { _ in publishCount += 1 }
        defer { coordinator.removeSnapshotHandler(subscriptionID) }

        coordinator.setMode(.changes)

        XCTAssertEqual(publishCount, 0)
    }

    func testWindowCanSwitchBetweenChangesAndHistoryRepeatedly() throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        let windowController = MainWindowController(coordinator: coordinator)

        for _ in 0..<10 {
            windowController.commandRouter.showHistory(nil)
            windowController.window?.contentView?.layoutSubtreeIfNeeded()
            windowController.commandRouter.showChanges(nil)
            windowController.window?.contentView?.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(coordinator.state.uiState.mode, .changes)
    }

    func testCommandRouterValidatesModeAndRefreshCommands() throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        let windowController = MainWindowController(coordinator: coordinator)
        let router = windowController.commandRouter
        let changesItem = NSMenuItem()
        changesItem.action = #selector(MainWindowCommandRouter.showChanges(_:))
        let historyItem = NSMenuItem()
        historyItem.action = #selector(MainWindowCommandRouter.showHistory(_:))
        let refreshItem = NSMenuItem()
        refreshItem.action = #selector(MainWindowCommandRouter.refresh(_:))

        XCTAssertTrue(router.validateMenuItem(changesItem))
        XCTAssertTrue(router.validateMenuItem(historyItem))
        XCTAssertEqual(changesItem.state, .on)
        XCTAssertEqual(historyItem.state, .off)
        XCTAssertFalse(router.validateMenuItem(refreshItem))

        router.showHistory(nil)

        XCTAssertTrue(router.validateMenuItem(changesItem))
        XCTAssertTrue(router.validateMenuItem(historyItem))
        XCTAssertEqual(changesItem.state, .off)
        XCTAssertEqual(historyItem.state, .on)
    }
}
