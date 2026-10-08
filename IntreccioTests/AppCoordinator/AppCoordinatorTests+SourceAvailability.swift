import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testUnavailableSelectedRepositoryClearsHistoryCommitAndDiffState() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        try "content\n".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(at: repository, arguments: ["add", "--", "file.txt"])
        try runGit(at: repository, arguments: ["commit", "-m", "initial"])
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.setMode(.history)
        coordinator.selectRepository(repositoryID)
        try await waitUntil(description: "history load") { coordinator.selectedHistoryState.commits.count == 1 }
        coordinator.selectCommit(coordinator.selectedHistoryState.commits[0])
        try await waitUntil(description: "commit load") {
            if case .loaded = coordinator.selectedCommitState { return true }
            return false
        }
        var publishedUnavailableWithStaleSelection = false
        let subscriptionID = coordinator.addSnapshotHandler { snapshot in
            let unavailable = snapshot.repositories.first(where: { $0.id == repositoryID })?.availability != .available
            let hasStaleSelection = !snapshot.selectedSession.historyState.commits.isEmpty
                || snapshot.selectedSession.commitState != .idle
                || snapshot.selectedSession.diffState != .idle
            if unavailable, hasStaleSelection { publishedUnavailableWithStaleSelection = true }
        }
        defer { coordinator.removeSnapshotHandler(subscriptionID) }

        try FileManager.default.removeItem(at: repository)
        await coordinator.restoreSources()

        XCTAssertFalse(publishedUnavailableWithStaleSelection)
        XCTAssertFalse(coordinator.selectedRepositoryIsAvailable)
        XCTAssertEqual(
            coordinator.repositories.first(where: { $0.id == repositoryID })?.availability,
            .unavailable(reason: "Repository is missing or access is unavailable.")
        )
        let sidebarController = RepoSidebarViewController(coordinator: coordinator)
        let repositoryMenu = NSMenu()
        sidebarController.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: repositoryMenu, repositoryID: repositoryID)
        )
        let parentMenuItem = try XCTUnwrap(
            repositoryMenu.items.first(where: { $0.title == "Open Parent in Regular App" })
        )
        let parentMenu = try XCTUnwrap(parentMenuItem.submenu)
        let chooseParentItem = try XCTUnwrap(parentMenu.items.first(where: { $0.title == "Choose Application…" }))
         XCTAssertTrue(chooseParentItem.target === sidebarController.applicationController)
        XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(chooseParentItem.action)), "chooseRepositoryApplication:")
         XCTAssertEqual(sidebarController.applicationController.openDirectoryURL(for: repositoryID, parentDirectory: true), directory)
         XCTAssertNil(sidebarController.applicationController.openDirectoryURL(for: repositoryID, parentDirectory: false))
        XCTAssertEqual(coordinator.selectedHistoryState, SelectedHistoryState())
        XCTAssertEqual(coordinator.selectedCommitState, .idle)
        XCTAssertEqual(coordinator.selectedDiffState, .idle)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(coordinator.selectedCommitState, .idle)
    }
}
