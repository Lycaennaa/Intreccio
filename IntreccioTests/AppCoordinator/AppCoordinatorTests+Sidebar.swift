import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testSelectingCurrentRepositoryDoesNotRepublish() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.selectRepository(repositoryID)
        var publishCount = 0
        let subscriptionID = coordinator.addSnapshotHandler { _ in publishCount += 1 }
        defer { coordinator.removeSnapshotHandler(subscriptionID) }

        coordinator.selectRepository(repositoryID)

        XCTAssertEqual(publishCount, 0)
    }

    @MainActor
    func testWindowTitleTracksSelectedRepository() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        let windowController = MainWindowController(coordinator: coordinator)

        XCTAssertEqual(windowController.window?.title, "Intreccio")

        coordinator.selectRepository(repositoryID)
        XCTAssertEqual(windowController.window?.title, "Repo")

        coordinator.selectRepository(nil)
        XCTAssertEqual(windowController.window?.title, "Intreccio")
    }

    func testPinnedRepositoryPersistsAndIsRemovedWhenRepositoryIsExcluded() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        await coordinator.addWatchRoot(directory)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)

        coordinator.setRepositoryPinned(repositoryID, pinned: true)
        XCTAssertEqual(coordinator.setQuickOpenFilePaths(["README.md"], for: repositoryID), .updated)

        XCTAssertTrue(coordinator.state.uiState.pinnedRepositoryIDs.contains(repositoryID))
        let flushed = await coordinator.flushState()
        let pinnedState = await StateStore(fileURL: stateFile).load()
        XCTAssertTrue(flushed)
        XCTAssertTrue(pinnedState.state.uiState.pinnedRepositoryIDs.contains(repositoryID))
        XCTAssertEqual(pinnedState.state.uiState.quickOpenFileAssignments, [
            PersistedQuickOpenFileAssignment(repositoryID: repositoryID, paths: ["README.md"])
        ])

        await coordinator.excludeRepository(repositoryID)

        let excludedState = await StateStore(fileURL: stateFile).load()
        XCTAssertFalse(coordinator.state.uiState.pinnedRepositoryIDs.contains(repositoryID))
        XCTAssertFalse(excludedState.state.uiState.pinnedRepositoryIDs.contains(repositoryID))
        XCTAssertTrue(excludedState.state.uiState.quickOpenFileAssignments.isEmpty)
    }

    func testRemoveRepoMenuUsesSourceSpecificActions() async throws {
        let directory = try makeTestDirectory()
        let watchedRepository = directory.appendingPathComponent("Watched", isDirectory: true)
        let unavailableRepository = directory.appendingPathComponent("Unavailable", isDirectory: true)
        let standaloneRepository = directory.appendingPathComponent("Standalone", isDirectory: true)
        try initializeRepository(at: watchedRepository)
        try initializeRepository(at: unavailableRepository)
        try initializeRepository(at: standaloneRepository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(watchedRepository)
        await coordinator.addWatchRoot(unavailableRepository)
        await coordinator.addStandaloneRepository(standaloneRepository)
        let watchedID = try XCTUnwrap(coordinator.repositories.first(where: {
            $0.canonicalURL == watchedRepository
        })?.id)
        let unavailableID = try XCTUnwrap(coordinator.repositories.first(where: {
            $0.canonicalURL == unavailableRepository
        })?.id)
        let standaloneID = try XCTUnwrap(coordinator.repositories.first(where: {
            $0.canonicalURL == standaloneRepository
        })?.id)
        try FileManager.default.removeItem(at: unavailableRepository)
        await coordinator.restoreSources()
        let controller = RepoSidebarViewController(coordinator: coordinator)

        let assertRemoveRepoItem: (NSMenu, String, UUID) throws -> Void = { menu, actionName, representedID in
            let item = try XCTUnwrap(menu.items.first(where: { $0.title == "Remove Repo…" }))
            XCTAssertTrue(item.target === controller.menuController)
            XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(item.action)), actionName)
            XCTAssertEqual(item.representedObject as? UUID, representedID)
        }

        let watched = try XCTUnwrap(coordinator.repositories.first(where: { $0.id == watchedID }))
        guard case .available = watched.availability else {
            XCTFail("Expected watched repository to be available")
            return
        }
        let watchedMenu = NSMenu()
        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: watchedMenu, repositoryID: watchedID)
        )
        try assertRemoveRepoItem(watchedMenu, "excludeRepository:", watchedID)

        let unavailable = try XCTUnwrap(coordinator.repositories.first(where: { $0.id == unavailableID }))
        guard case .unavailable = unavailable.availability else {
            XCTFail("Expected watched repository to be unavailable")
            return
        }
        let unavailableMenu = NSMenu()
        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: unavailableMenu, repositoryID: unavailableID)
        )
        try assertRemoveRepoItem(unavailableMenu, "excludeRepository:", unavailableID)

        let standaloneMenu = NSMenu()
        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: standaloneMenu, repositoryID: standaloneID)
        )
        let standalone = try XCTUnwrap(coordinator.repositories.first(where: { $0.id == standaloneID }))
        try assertRemoveRepoItem(standaloneMenu, "removeSource:", standalone.source.id)

        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)
        let rootMenu = NSMenu()
        controller.menuController.populateMenu(with: RepoSidebarMenuContext(
            menu: rootMenu,
            node: RepoSidebarViewController.Node(title: "Root", kind: .root(sourceID)),
            repositoryIDs: [],
            presentingWindow: nil
        ))
        try assertRemoveRepoItem(rootMenu, "removeSource:", sourceID)
    }

    func testQuickOpenMutationRejectsOverCapacityWithoutEvictingExistingPaths() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        let existingPaths = (0..<(PersistedUIState.maxQuickOpenFilesPerRepository - 1)).map {
            "file-\($0).txt"
        }

        XCTAssertEqual(coordinator.setQuickOpenFilePaths(existingPaths, for: repositoryID), .updated)
        XCTAssertEqual(
            coordinator.setQuickOpenFilePaths(["../invalid"], for: repositoryID),
            .invalidInput
        )
        XCTAssertEqual(coordinator.quickOpenFilePaths(for: repositoryID), existingPaths)
        XCTAssertEqual(
            coordinator.setQuickOpenFilePaths(existingPaths + ["new-a.txt", "new-b.txt"], for: repositoryID),
            .capacityExceeded
        )
        XCTAssertEqual(coordinator.quickOpenFilePaths(for: repositoryID), existingPaths)
    }

    func testSidebarPinMenuMovesRepositoryIntoPinnedSectionWithoutDuplication() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller

        let pinMenu = NSMenu()
        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: pinMenu, repositoryID: repositoryID, presentingWindow: window)
        )
        XCTAssertEqual(
            pinMenu.items.prefix(4).map(\.title),
            ["Open in AI Tool", "Open in Regular App", "Open Parent in Regular App", "Refetch Upstream"]
        )
         XCTAssertEqual(controller.applicationController.openDirectoryURL(for: repositoryID, parentDirectory: false), repository)
         XCTAssertEqual(controller.applicationController.openDirectoryURL(for: repositoryID, parentDirectory: true), directory)
        for title in ["Open in Regular App", "Open Parent in Regular App"] {
            let menuItem = try XCTUnwrap(pinMenu.items.first(where: { $0.title == title }))
            let submenu = try XCTUnwrap(menuItem.submenu)
            let chooseItem = try XCTUnwrap(submenu.items.first(where: { $0.title == "Choose Application…" }))
             XCTAssertTrue(chooseItem.target === controller.applicationController)
            XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(chooseItem.action)), "chooseRepositoryApplication:")
            for applicationItem in submenu.items where !applicationItem.isSeparatorItem
                && applicationItem !== chooseItem
                 && applicationItem.title != "Remove from List"
                  && applicationItem.title != "Remove All from List"
                  && applicationItem.title != "Remove Selected…" {
                 XCTAssertTrue(applicationItem.target === controller.applicationController)
                XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(applicationItem.action)), "openRepositoryWithApplication:")
            }
        }
         let openItem = try XCTUnwrap(pinMenu.items.first(where: { $0.title == "Open" }))
         let openMenu = try XCTUnwrap(openItem.submenu)
         let assignItem = try XCTUnwrap(openMenu.items.first(where: { $0.title == "Assign Files…" }))
          XCTAssertTrue(assignItem.target === controller.menuController.quickOpenController)
         XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(assignItem.action)), "chooseRepositoryFiles:")
         let assignmentTarget = try XCTUnwrap(
              assignItem.representedObject as? RepoSidebarQuickOpenController.QuickOpenFileAssignmentTarget
         )
         XCTAssertEqual(assignmentTarget.repositoryID, repositoryID)
         XCTAssertEqual(assignmentTarget.repositoryURL, repository)
         XCTAssertEqual(assignmentTarget.repositoryResourceID, try XCTUnwrap(ResourceIdentity.read(from: repository)))

        let copyPathItem = try XCTUnwrap(pinMenu.items.first(where: { $0.title == "Copy Path" }))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(copyPathItem.action), to: copyPathItem.target, from: copyPathItem))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), repository.path)
        let pinItem = try XCTUnwrap(pinMenu.items.first(where: { $0.title == "Pin" }))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(pinItem.action), to: pinItem.target, from: pinItem))
        controller.reload()
        window.contentView?.layoutSubtreeIfNeeded()

        let outlineView = try XCTUnwrap(findOutlineView(in: controller.view))
        let titles = (0..<outlineView.numberOfRows).compactMap { row in
            (outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        }
        XCTAssertEqual(Array(titles.prefix(2)), ["Pinned", "Repo"])
        XCTAssertEqual(titles.filter { $0 == "Repo" }.count, 1)

        let unpinMenu = NSMenu()
        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: unpinMenu, repositoryID: repositoryID, presentingWindow: window)
        )
        let unpinItem = try XCTUnwrap(unpinMenu.items.first(where: { $0.title == "Unpin" }))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(unpinItem.action), to: unpinItem.target, from: unpinItem))
        controller.reload()

        XCTAssertFalse(coordinator.state.uiState.pinnedRepositoryIDs.contains(repositoryID))
        XCTAssertFalse((0..<outlineView.numberOfRows).contains { row in
            (outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == "Pinned"
        })
    }

    func testSidebarQuickOpenMenuSupportsMultipleFilesAndOpenWithApplications() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let docs = repository.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("todo".utf8).write(to: repository.appendingPathComponent("todo.txt"))
        try Data("notes".utf8).write(to: docs.appendingPathComponent("notes.txt"))

        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        XCTAssertEqual(coordinator.setQuickOpenFilePaths(["todo.txt", "docs/notes.txt"], for: repositoryID), .updated)

        let controller = RepoSidebarViewController(coordinator: coordinator)
        let menu = NSMenu()
        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: menu, repositoryID: repositoryID)
        )

        let openMenu = try XCTUnwrap(menu.items.first(where: { $0.title == "Open" })?.submenu)
        for path in ["todo.txt", "docs/notes.txt"] {
            let fileMenu = try XCTUnwrap(openMenu.items.first(where: { $0.title == path })?.submenu)
            let openWithItem = try XCTUnwrap(fileMenu.items.first(where: { $0.title == "Open With" }))
            let openWithMenu = try XCTUnwrap(openWithItem.submenu)
            let chooseItem = try XCTUnwrap(openWithMenu.items.first(where: { $0.title == "Choose Application…" }))
             XCTAssertTrue(chooseItem.target === controller.menuController.quickOpenController)
            XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(chooseItem.action)), "chooseRepositoryFileApplication:")

            let openDefaultItem = try XCTUnwrap(fileMenu.items.first(where: { $0.title == "Open" }))
             XCTAssertTrue(openDefaultItem.target === controller.menuController.quickOpenController)
            XCTAssertEqual(
                NSStringFromSelector(try XCTUnwrap(openDefaultItem.action)),
                "openRepositoryFileWithDefaultApplication:"
            )
            let target = try XCTUnwrap(
                openDefaultItem.representedObject as? RepoSidebarQuickOpenController.OpenFileTarget
            )
            XCTAssertEqual(target.repositoryID, repositoryID)
            XCTAssertEqual(target.relativePath, path)
        }

        let removeMenu = try XCTUnwrap(openMenu.items.first(where: { $0.title == "Remove File" })?.submenu)
        XCTAssertEqual(removeMenu.items.map(\.title), ["todo.txt", "docs/notes.txt"])
        let removeNotes = try XCTUnwrap(removeMenu.items.first(where: { $0.title == "docs/notes.txt" }))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(removeNotes.action), to: removeNotes.target, from: removeNotes))
        XCTAssertEqual(coordinator.quickOpenFilePaths(for: repositoryID), ["todo.txt"])
    }

    func testStaleChooseApplicationShowsOpenError() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let sourceID = try XCTUnwrap(coordinator.repositories.first?.source.id)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.sheets.first { window.endSheet(sheet) }
            window.orderOut(nil)
        }

        let menu = NSMenu()
        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: menu, repositoryID: repositoryID, presentingWindow: window)
        )
        let parentMenu = try XCTUnwrap(menu.items.first(where: { $0.title == "Open Parent in Regular App" })?.submenu)
        let chooseItem = try XCTUnwrap(parentMenu.items.first(where: { $0.title == "Choose Application…" }))

        await coordinator.removeSource(sourceID)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(chooseItem.action), to: chooseItem.target, from: chooseItem))
        try await waitUntil(description: "stale repository open error") { !window.sheets.isEmpty }
    }

    func testSidebarShowsNestedWatchRootFolders() async throws {
        let directory = try makeTestDirectory()
        let rootRepository = directory.appendingPathComponent("Root", isDirectory: true)
        let active = directory.appendingPathComponent("repos/Active", isDirectory: true)
        let inactive = directory.appendingPathComponent("external/not active/repos/Inactive", isDirectory: true)
        let direct = directory.appendingPathComponent("external/not active/Direct", isDirectory: true)
        let deep = directory.appendingPathComponent("external/not active/other/Deep", isDirectory: true)
        try initializeRepository(at: rootRepository)
        try initializeRepository(at: active)
        try initializeRepository(at: inactive)
        try initializeRepository(at: direct)
        try initializeRepository(at: deep)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)

        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()

        let outlineView = try XCTUnwrap(findOutlineView(in: controller.view))
        XCTAssertEqual(outlineView.indentationPerLevel, 14)
        let rootCell = try XCTUnwrap(outlineView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let folderIcon = rootCell.subviews
            .compactMap { $0 as? NSStackView }
            .flatMap(\.arrangedSubviews)
            .compactMap { $0 as? NSImageView }
            .first
        XCTAssertNotNil(folderIcon?.image)
        XCTAssertTrue((0..<outlineView.numberOfRows).allSatisfy { outlineView.level(forRow: $0) == 0 })
        let titles = (0..<outlineView.numberOfRows).compactMap { row in
            (outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        }

        XCTAssertTrue(Set(["Root", "repos", "external", "not active", "other", "Active", "Inactive", "Direct", "Deep"]).isSubset(of: Set(titles)))
        XCTAssertEqual(titles.filter { $0 == "Active" }.count, 1)
        XCTAssertEqual(titles.filter { $0 == "Inactive" }.count, 1)
        XCTAssertEqual(titles.filter { $0 == "Direct" }.count, 1)
        XCTAssertEqual(titles.filter { $0 == "Deep" }.count, 1)

        XCTAssertEqual(
            Array(controller.roots.dropFirst().map(\.title)),
            ["Root", "external", "not active", "Direct", "other", "Deep", "repos", "Inactive", "repos", "Active"]
        )
        XCTAssertTrue(controller.roots.dropFirst().allSatisfy { node in
            if case .repository = node.kind { return true }
            if case .root = node.kind { return false }
            return true
        })
    }

    func testSidebarShowsContainingFolderForRepositoryWatchRoots() async throws {
        let directory = try makeTestDirectory()
        let usageRepository = directory.appendingPathComponent("UsageExtenderCodex/codex", isDirectory: true)
        let externalRepository = directory.appendingPathComponent("External/filen-desktop", isDirectory: true)
        try initializeRepository(at: usageRepository)
        try initializeRepository(at: externalRepository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(usageRepository)
        await coordinator.addWatchRoot(externalRepository)

        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()

        XCTAssertEqual(controller.roots.map(\.title), ["UsageExtenderCodex", "codex", "External", "filen-desktop"])
    }

    func testSidebarRefetchUpstreamRefreshesMenuRepositoryWithoutSelection() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        try await waitUntil(description: "initial repository refresh") {
            coordinator.repositoryRefreshStates[repositoryID]?.phase == .idle
                && coordinator.repositoryRefreshStates[repositoryID]?.status != nil
        }
        let initialGeneration = try XCTUnwrap(coordinator.repositoryRefreshStates[repositoryID]?.statusGeneration)
        XCTAssertNil(coordinator.state.uiState.selectedRepoID)

        let controller = RepoSidebarViewController(coordinator: coordinator)
        let menu = NSMenu()
        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: menu, repositoryID: repositoryID)
        )
        let refetchItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Refetch Upstream" }))

        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(refetchItem.action), to: refetchItem.target, from: refetchItem))
        try await waitUntil(description: "context menu upstream refetch") {
            (coordinator.repositoryRefreshStates[repositoryID]?.statusGeneration ?? 0) > initialGeneration
                && coordinator.repositoryRefreshStates[repositoryID]?.phase == .idle
        }
        XCTAssertNil(coordinator.state.uiState.selectedRepoID)
    }

    func testRestoreAndRemovalCannotResurrectDeletedSource() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let sourceID = try XCTUnwrap(coordinator.state.watchRoots.first?.id)

        async let restore: Void = coordinator.restoreSources()
        async let remove: Void = coordinator.removeSource(sourceID)
        _ = await (restore, remove)

        XCTAssertTrue(coordinator.state.watchRoots.isEmpty)
        XCTAssertTrue(coordinator.repositories.isEmpty)
    }

    func testSidebarSupportsMultiSelectionAndAppliesMenuActionsToAllRepositories() async throws {
        let directory = try makeTestDirectory()
        let first = directory.appendingPathComponent("First", isDirectory: true)
        let second = directory.appendingPathComponent("Second", isDirectory: true)
        try initializeRepository(at: first)
        try initializeRepository(at: second)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(first)
        await coordinator.addStandaloneRepository(second)
        let firstID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == first })?.id)
        let secondID = try XCTUnwrap(coordinator.repositories.first(where: { $0.canonicalURL == second })?.id)

        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        controller.reload()
        let firstRow = try XCTUnwrap(controller.row(for: firstID))
        let secondRow = try XCTUnwrap(controller.row(for: secondID))
        XCTAssertTrue(controller.outlineView.allowsMultipleSelection)
        controller.outlineView.selectRowIndexes(
            IndexSet([firstRow, secondRow]),
            byExtendingSelection: false
        )
        XCTAssertEqual(
            Set(controller.repositoryIDs(in: controller.outlineView.selectedRowIndexes)),
            Set([firstID, secondID])
        )

        let menu = NSMenu()
        let context = RepoSidebarMenuContext(
            menu: menu,
            node: RepoSidebarViewController.Node(title: "First", kind: .repository(firstID)),
            repositoryIDs: [firstID, secondID],
            presentingWindow: nil
        )
        controller.menuController.populateMenu(with: context)
        await controller.menuController.waitForJustMenuDiscovery()
        let copyItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy Paths" }))
        let copyTarget = try XCTUnwrap(
            copyItem.representedObject as? RepoSidebarMenuController.RepositorySelectionTarget
        )
        XCTAssertEqual(copyTarget.repositoryIDs, [firstID, secondID])
        let githubItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Open on GitHub" }))
        let githubTarget = try XCTUnwrap(
            githubItem.representedObject as? RepoSidebarGitHubMenuController.RepositorySelectionTarget
        )
        XCTAssertEqual(githubTarget.repositoryIDs, [firstID, secondID])
        let openItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Open" }))
        XCTAssertEqual(openItem.submenu?.items.count, 2)
        let justItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Just" }))
        XCTAssertEqual(justItem.submenu?.items.map(\.title), ["Create in All", "What Is This?"])
        let createAllItem = try XCTUnwrap(justItem.submenu?.items.first)
        XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(createAllItem.action)), "createJustfiles:")
        let createAllTarget = try XCTUnwrap(
            createAllItem.representedObject as? RepoSidebarJustMenuController.CreateAllTarget
        )
        XCTAssertEqual(createAllTarget.repositoryIDs, [firstID, secondID])
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(copyItem.action), to: copyItem.target, from: copyItem))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "\(first.path)\n\(second.path)")

        let pinItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Pin" }))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(pinItem.action), to: pinItem.target, from: pinItem))
        XCTAssertEqual(coordinator.state.uiState.pinnedRepositoryIDs, Set([firstID, secondID]))

        controller.reload()
        XCTAssertEqual(
            Set(controller.repositoryIDs(in: controller.outlineView.selectedRowIndexes)),
            Set([firstID, secondID])
        )
    }

}
