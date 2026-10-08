@testable import Intreccio
import XCTest

@MainActor
final class SettingsPanelPresentationTests: XCTestCase {
    func testPresenterMaintainsSingletonLayoutAndRestoresMainWindowFrame() async throws {
        let directory = try makeTestDirectory()
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json"))
        )
        let windowController = MainWindowController(coordinator: coordinator)
        let presenter = windowController.settingsPresenter
        let window = try XCTUnwrap(windowController.window)
        window.setFrame(NSRect(x: 120, y: 100, width: 1_000, height: 700), display: false)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        presenter.present()
        try await waitUntil(description: "Settings presentation readiness") {
            presenter.presentedPanel != nil
        }
        let panel = try XCTUnwrap(presenter.presentedPanel)
        let openingFrame = window.frame
        let expectedPanelFrame = window.contentRect(forFrameRect: openingFrame)

        presenter.present()

        XCTAssertTrue(presenter.presentedPanel === panel)
        XCTAssertEqual(window.childWindows?.filter { $0 === panel }.count, 1)
        XCTAssertEqual(panel.frame, expectedPanelFrame)
        XCTAssertEqual(panel.contentView?.subviews.first?.frame.size, expectedPanelFrame.size)

        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let resizedPanelFrame = window.contentRect(forFrameRect: window.frame)
        XCTAssertEqual(panel.frame, resizedPanelFrame)

        presenter.dismiss()

        XCTAssertNil(presenter.presentedPanel)
        XCTAssertFalse(window.childWindows?.contains { $0 === panel } ?? false)
        XCTAssertEqual(window.frame, openingFrame)
    }
}
