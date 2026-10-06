import AppKit
import Foundation
import XCTest
@testable import Intreccio

extension AppCoordinatorTests {
    func testSidebarMenuUpdateRequiresCurrentTypedContext() throws {
        let coordinator = makeCoordinator(stateFile: URL(fileURLWithPath: "/unused"))
        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        let menu = try XCTUnwrap(controller.outlineView.menu)
        XCTAssertTrue(menu.delegate === controller)

        let staleMenu = NSMenu()
        staleMenu.addItem(NSMenuItem(title: "Stale", action: nil, keyEquivalent: ""))
        controller.menuNeedsUpdate(staleMenu)
        XCTAssertTrue(staleMenu.items.isEmpty)

        menu.addItem(NSMenuItem(title: "Missing Node", action: nil, keyEquivalent: ""))
        controller.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.isEmpty)
    }

    func makeRepositoryMenuContext(
        for menu: NSMenu,
        repositoryID: UUID,
        presentingWindow: NSWindow? = nil
    ) -> RepoSidebarMenuContext {
        RepoSidebarMenuContext(
            menu: menu,
            node: RepoSidebarViewController.Node(title: "Repository", kind: .repository(repositoryID)),
            repositoryIDs: [repositoryID],
            presentingWindow: presentingWindow
        )
    }
}