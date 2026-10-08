import AppKit
@testable import Intreccio
import XCTest

@MainActor
private func descendantViews(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendantViews(of: $0) }
}

@MainActor
final class SettingsViewSmokeTests: XCTestCase {
    func testLoadSettingsViewAndSwitchTabsDoesNotThrow() throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = AppCoordinator(stateStore: StateStore(fileURL: stateFile))
        // Seed state resembling a real user so previews and lists have data.
        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        coordinator.state.watchRoots = [
            WatchRoot(
                id: UUID(),
                displayName: "Projects",
                bookmarkData: Data(),
                lastResolvedPath: NSHomeDirectory(),
                resourceID: nil,
                exclusions: ["legacy-repo"]
            )
        ]
        coordinator.state.standaloneRepos = [
            StandaloneRepository(
                id: UUID(),
                displayName: "dotfiles",
                bookmarkData: Data(),
                lastResolvedPath: NSHomeDirectory() + "/.test-tmp",
                resourceID: nil
            )
        ]
        if FileManager.default.fileExists(atPath: textEditURL.path) {
            coordinator.state.uiState.savedOpenApplicationURLs = [textEditURL]
            coordinator.state.uiState.excludedOpenApplicationURLs = [textEditURL]
        }

        let controller = SettingsViewController(coordinator: coordinator) {}
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView?.addSubview(container)
        container.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.view.subviews.count, 1, "overlay should host the card")
        XCTAssertEqual(controller.children.count, 4)
        XCTAssertTrue(controller.sectionControllerForTesting(.diff) is DiffSettingsViewController)
        XCTAssertTrue(controller.sectionControllerForTesting(.fileWatching) is FileWatchingSettingsViewController)
        XCTAssertTrue(controller.sectionControllerForTesting(.openInApp) is OpenApplicationSettingsViewController)
        let repositorySettings = try XCTUnwrap(
            controller.sectionControllerForTesting(.foldersAndRepositories)
                as? RepositorySourcesSettingsViewController
        )
        let addSourcesPopup = try XCTUnwrap(
            descendantViews(of: repositorySettings.view)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == "AddSources" }
        )
        let popupMenuItems = addSourcesPopup.menu?.items ?? []
        let sourceActions = popupMenuItems.dropFirst().filter { $0.action != nil }
        XCTAssertEqual(sourceActions.map(\.title), [
            "Add Root Folder…",
            "Add Repository…",
            "Create Local Repository…",
            "Clone Repository…"
        ])
        XCTAssertTrue(sourceActions.allSatisfy { $0.target === repositorySettings })

        for tab in SettingsViewController.Tab.allCases {
            let button = NSButton(title: tab.title, target: nil, action: nil)
            button.identifier = NSUserInterfaceItemIdentifier(tab.title)
            controller.selectTab(button)
            container.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.selectedTabForTesting, tab)
        }

        controller.refresh(from: coordinator.snapshot)

        controller.startEventHandling()
        XCTAssertEqual(coordinator.snapshotHandlerCountForTesting, 1)
        coordinator.setDiffFontSize(14)
        coordinator.setShowWhitespaceInDiff(true)
        let diffController = try XCTUnwrap(
            controller.sectionControllerForTesting(.diff) as? DiffSettingsViewController
        )
        XCTAssertEqual(diffController.selectedFontSizeForTesting, 14)
        XCTAssertTrue(diffController.showsWhitespaceForTesting)
        controller.close()
        XCTAssertEqual(coordinator.snapshotHandlerCountForTesting, 0)
    }
}
