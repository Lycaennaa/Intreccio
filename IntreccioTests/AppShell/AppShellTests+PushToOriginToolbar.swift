import AppKit
@testable import Intreccio
import XCTest

extension AppShellTests {
    @MainActor
    func testPushToOriginToolbarShowsRepositoryCountAndAction() throws {
        let directory = try makeTestDirectory()
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [])
        )
        addTeardownBlock { _ = await coordinator.shutdown() }
        let windowController = MainWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(windowController.window)
        defer { window.close() }

        let toolbar = try XCTUnwrap(window.toolbar)
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "PushToOrigin" })
        let button = try XCTUnwrap(item.view as? NSButton)

        XCTAssertEqual(button.title, "Push to Origin (0)")
        XCTAssertEqual(button.action, #selector(PushToOriginToolbarController.pushToOrigin(_:)))
        XCTAssertTrue(button.target is PushToOriginToolbarController)
        XCTAssertFalse(button.isEnabled)
    }
}
