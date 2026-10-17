import AppKit
import Foundation
@testable import Intreccio
import XCTest

@MainActor
extension AppCoordinatorTests {
    func testSidebarShowsDistinctSubmoduleStatusAndCollapsedActivityCount() throws {
        let directory = try makeTestDirectory()
        let parentID = UUID()
        let childID = UUID()
        let coordinator = makeActiveSubmoduleCoordinator(
            directory: directory,
            parentID: parentID,
            childID: childID
        )
        addTeardownBlock { [coordinator] in _ = await coordinator.shutdown() }
        let snapshot = coordinator.snapshot
        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 500),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        defer { window.orderOut(nil) }

        controller.rebuildTree(snapshot, cacheKey: controller.makeTreeCacheKey(snapshot))
        window.contentView?.layoutSubtreeIfNeeded()
        let parentNode = try XCTUnwrap(controller.repositoryNodesByID[parentID])
        let childNode = try XCTUnwrap(controller.repositoryNodesByID[childID])
        XCTAssertEqual(parentNode.children.map(\.title), ["child"])
        XCTAssertEqual(parentNode.badge, "L1 · 1 submodule")
        XCTAssertEqual(childNode.badge, "Changes 1 · Ahead 2 · Behind 1 · Parent commit differs")
        XCTAssertTrue(controller.outlineView(controller.outlineView, isItemExpandable: parentNode))

        controller.outlineView.expandItem(parentNode)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(parentNode.badge, "L1")
        let childRow = try XCTUnwrap(controller.row(for: childID))
        XCTAssertEqual(controller.outlineView.level(forRow: childRow), 1)
        let childCell = try XCTUnwrap(
            controller.outlineView.view(atColumn: 0, row: childRow, makeIfNecessary: true) as? NSTableCellView
        )
        XCTAssertEqual(childCell.textField?.stringValue, "child")
        XCTAssertEqual(
            childCell.subviews.compactMap { $0 as? NSTextField }.first?.stringValue,
            childNode.badge
        )
    }

    func testSubmoduleStatusUpdatesRefreshTreeVisibility() async throws {
        let directory = try makeTestDirectory()
        let sourceID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let parentURL = directory.appendingPathComponent("main", isDirectory: true)
        let parent = makeSidebarRepository(
            id: parentID,
            sourceID: sourceID,
            url: parentURL,
            hasSubmodules: true
        )
        let child = makeSidebarRepository(
            id: childID,
            sourceID: sourceID,
            url: parentURL.appendingPathComponent("vendor/child", isDirectory: true),
            parentID: parentID,
            submodulePath: "vendor/child"
        )
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [parent, child])
        )
        addTeardownBlock { [coordinator] in _ = await coordinator.shutdown() }
        coordinator.publish()
        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        XCTAssertTrue(try XCTUnwrap(controller.repositoryNodesByID[parentID]).children.isEmpty)

        var dirtyStatus = RepoStatus()
        dirtyStatus.changes = [FileChange(
            path: "local.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )]
        let refreshKey = RefreshKey(repositoryID: childID, kind: .status)
        coordinator.runtime.handleRefreshEvent(.completed(refreshKey, 1, dirtyStatus))
        let changedSnapshot = coordinator.snapshot
        XCTAssertEqual(changedSnapshot.sidebarUpdate, .submoduleActivity)
        controller.reload(changedSnapshot)
        XCTAssertEqual(try XCTUnwrap(controller.repositoryNodesByID[parentID]).children.map(\.kind), [
            .repository(childID)
        ])

        coordinator.runtime.handleRefreshEvent(.completed(refreshKey, 2, RepoStatus()))
        controller.reload(coordinator.snapshot)
        XCTAssertTrue(try XCTUnwrap(controller.repositoryNodesByID[parentID]).children.isEmpty)
    }

    func testCleanSubmoduleVisibilityIsPerParentAndInheritedRecursively() throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        let sourceID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        let otherParentID = UUID()
        let otherChildID = UUID()
        let parentURL = directory.appendingPathComponent("main", isDirectory: true)
        let childURL = parentURL.appendingPathComponent("vendor/child", isDirectory: true)
        let repositories = [
            makeSidebarRepository(id: parentID, sourceID: sourceID, url: parentURL, hasSubmodules: true),
            makeSidebarRepository(
                id: childID,
                sourceID: sourceID,
                url: childURL,
                parentID: parentID,
                submodulePath: "vendor/child",
                hasSubmodules: true
            ),
            makeSidebarRepository(
                id: grandchildID,
                sourceID: sourceID,
                url: childURL.appendingPathComponent("nested/tool", isDirectory: true),
                parentID: childID,
                submodulePath: "nested/tool"
            ),
            makeSidebarRepository(
                id: otherParentID,
                sourceID: sourceID,
                url: directory.appendingPathComponent("other", isDirectory: true),
                hasSubmodules: true
            ),
            makeSidebarRepository(
                id: otherChildID,
                sourceID: sourceID,
                url: directory.appendingPathComponent("other/vendor/child", isDirectory: true),
                parentID: otherParentID,
                submodulePath: "vendor/child"
            )
        ]
        var uiState = PersistedUIState()
        uiState.showCleanSubmoduleRepositoryIDs = [parentID]
        let snapshot = makeSidebarSnapshot(
            base: coordinator.snapshot,
            state: PersistedState(uiState: uiState),
            repositories: repositories,
            statuses: [:]
        )
        let controller = RepoSidebarViewController(coordinator: coordinator)
        _ = controller.makeNodes(snapshot)
        let parent = try XCTUnwrap(controller.repositoryNodesByID[parentID])
        let child = try XCTUnwrap(controller.repositoryNodesByID[childID])
        let otherParent = try XCTUnwrap(controller.repositoryNodesByID[otherParentID])

        XCTAssertEqual(parent.children.map(\.kind), [.repository(childID)])
        XCTAssertEqual(child.children.map(\.kind), [.repository(grandchildID)])
        XCTAssertTrue(otherParent.children.isEmpty)
    }

    func testSidebarKeepsCleanAncestorForActiveNestedSubmodule() throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        let sourceID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        let parentURL = directory.appendingPathComponent("Parent", isDirectory: true)
        let childURL = parentURL.appendingPathComponent("vendor/child", isDirectory: true)
        let parent = makeSidebarRepository(
            id: parentID,
            sourceID: sourceID,
            url: parentURL,
            hasSubmodules: true
        )
        let child = makeSidebarRepository(
            id: childID,
            sourceID: sourceID,
            url: childURL,
            parentID: parentID,
            submodulePath: "vendor/child",
            hasSubmodules: true
        )
        let grandchild = makeSidebarRepository(
            id: grandchildID,
            sourceID: sourceID,
            url: childURL.appendingPathComponent("nested/tool", isDirectory: true),
            parentID: childID,
            submodulePath: "nested/tool"
        )
        var grandchildStatus = RepoStatus()
        grandchildStatus.branch = BranchStatus(
            head: "main",
            objectID: "grandchild-head",
            upstream: "origin/main",
            ahead: 1
        )
        let snapshot = makeSidebarSnapshot(
            base: coordinator.snapshot,
            state: PersistedState(),
            repositories: [parent, child, grandchild],
            statuses: [
                parentID: RepoStatus(),
                childID: RepoStatus(),
                grandchildID: grandchildStatus
            ]
        )
        let controller = RepoSidebarViewController(coordinator: coordinator)
        _ = controller.makeNodes(snapshot)

        let parentNode = try XCTUnwrap(controller.repositoryNodesByID[parentID])
        let childNode = try XCTUnwrap(controller.repositoryNodesByID[childID])
        let grandchildNode = try XCTUnwrap(controller.repositoryNodesByID[grandchildID])
        XCTAssertEqual(parentNode.children.map(\.kind), [.repository(childID)])
        XCTAssertEqual(childNode.children.map(\.kind), [.repository(grandchildID)])
        XCTAssertEqual(parentNode.badge, "L0 · 1 submodule")
        XCTAssertEqual(childNode.badge, "1 submodule")
        XCTAssertEqual(grandchildNode.badge, "Ahead 1")
    }

    func testSubmoduleVisibilityMenuSettingPersistsForItsParent() async throws {
        let directory = try makeTestDirectory()
        let fixture = try makeSubmoduleFixture(in: directory)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        await coordinator.addStandaloneRepository(fixture.parent)
        let parent = try XCTUnwrap(coordinator.repositories.first { $0.canonicalURL == fixture.parent })
        let child = try XCTUnwrap(coordinator.repositories.first { $0.canonicalURL == fixture.child })
        XCTAssertEqual(child.submoduleParentRepositoryID, parent.id)
        coordinator.runtime.enqueueStatusRefreshes(
            for: [parent.id, child.id],
            refreshUpstream: false
        )
        try await waitUntil(description: "clean submodule statuses") {
            guard let parentStatus = coordinator.repositoryRefreshStates[parent.id],
                  let childStatus = coordinator.repositoryRefreshStates[child.id] else { return false }
            return parentStatus.phase == .idle
                && parentStatus.status?.isClean == true
                && childStatus.phase == .idle
                && childStatus.status?.isClean == true
        }

        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        XCTAssertTrue(try XCTUnwrap(controller.repositoryNodesByID[parent.id]).children.isEmpty)
        XCTAssertNil(controller.repositoryNodesByID[child.id])
        let menu = NSMenu()
        controller.menuController.populateRepositoryMenu(repositoryMenuContext(menu, repositoryID: parent.id))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Show All Initialized Submodules" })
        XCTAssertEqual(item.state, .off)
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(item.action),
            to: item.target,
            from: item
        ))
        XCTAssertTrue(coordinator.state.uiState.showCleanSubmoduleRepositoryIDs.contains(parent.id))
        controller.reload()
        XCTAssertEqual(
            try XCTUnwrap(controller.repositoryNodesByID[parent.id]).children.map(\.kind),
            [.repository(child.id)]
        )
        let childMenu = NSMenu()
        controller.menuController.populateRepositoryMenu(
            repositoryMenuContext(childMenu, repositoryID: child.id)
        )
        XCTAssertTrue(childMenu.items.contains { $0.title == "Copy Path" })
        XCTAssertFalse(childMenu.items.contains { $0.title == "Remove Repo…" })
        XCTAssertFalse(childMenu.items.contains { $0.title == "Re-authorize…" })

        let stateFlushed = await coordinator.flushState()
        XCTAssertTrue(stateFlushed)
        let loaded = await StateStore(fileURL: stateFile).load()
        XCTAssertTrue(loaded.state.uiState.showCleanSubmoduleRepositoryIDs.contains(parent.id))
    }

    func testNewlyInitializedSubmoduleIsDiscoveredFromItsGitMarkerEvent() async throws {
        let directory = try makeTestDirectory()
        let fixture = try makeSubmoduleFixture(in: directory)
        try runGit(at: fixture.parent, arguments: [
            "submodule", "deinit", "--force", "--", "vendor/child"
        ])
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(fixture.parent)
        let parent = try XCTUnwrap(coordinator.repositories.first { $0.canonicalURL == fixture.parent })
        XCTAssertNil(coordinator.repositories.first { $0.canonicalURL == fixture.child })

        try runGit(at: fixture.parent, arguments: [
            "-c", "protocol.file.allow=always", "submodule", "update", "--init", "--", "vendor/child"
        ])
        let gitMarkerPath = fixture.child.appendingPathComponent(".git").path
        await coordinator.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [gitMarkerPath],
                sourceRescanPaths: [gitMarkerPath],
                requiresFullRescan: false
            ),
            repositoryID: parent.id
        )

        try await waitUntil(description: "initialized submodule source rescan") {
            guard let child = coordinator.repositories.first(where: { $0.canonicalURL == fixture.child }) else {
                return false
            }
            return child.submoduleParentRepositoryID == parent.id
        }
    }

    private func makeSubmoduleFixture(in directory: URL) throws -> (parent: URL, child: URL) {
        let parent = directory.appendingPathComponent("Parent", isDirectory: true)
        let childSource = directory.appendingPathComponent("ChildSource", isDirectory: true)
        try initializeCommittedRepository(at: parent, fileName: "README.md")
        try initializeCommittedRepository(at: childSource, fileName: "child.txt")
        try runGit(at: parent, arguments: [
            "-c", "protocol.file.allow=always", "submodule", "add", "--",
            childSource.path, "vendor/child"
        ])
        try runGit(at: parent, arguments: ["commit", "-m", "Add submodule"])
        return (
            parent,
            parent.appendingPathComponent("vendor/child", isDirectory: true)
        )
    }

    private func initializeCommittedRepository(at url: URL, fileName: String) throws {
        try initializeRepository(at: url)
        try runGit(at: url, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: url, arguments: ["config", "user.email", "fixture@example.com"])
        try Data("initial\n".utf8).write(to: url.appendingPathComponent(fileName))
        try runGit(at: url, arguments: ["add", fileName])
        try runGit(at: url, arguments: ["commit", "-m", "Initial commit"])
    }

    private func makeActiveSubmoduleCoordinator(
        directory: URL,
        parentID: UUID,
        childID: UUID
    ) -> AppCoordinator {
        let sourceID = UUID()
        let parentURL = directory.appendingPathComponent("main", isDirectory: true)
        let parent = makeSidebarRepository(
            id: parentID,
            sourceID: sourceID,
            url: parentURL,
            hasSubmodules: true
        )
        let child = makeSidebarRepository(
            id: childID,
            sourceID: sourceID,
            url: parentURL.appendingPathComponent("vendor/child", isDirectory: true),
            parentID: parentID,
            submodulePath: "vendor/child"
        )
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [parent, child])
        )
        var parentStatus = RepoStatus()
        parentStatus.changes = [FileChange(
            path: "vendor/child",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: "SC.."
        )]
        var childStatus = RepoStatus()
        childStatus.branch = BranchStatus(
            head: "main",
            objectID: "child-head",
            upstream: "origin/main",
            ahead: 2,
            behind: 1
        )
        childStatus.changes = [FileChange(
            path: "local.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .unmodified,
            kind: .untracked,
            submoduleState: nil
        )]
        coordinator.runtime.handleRefreshEvent(
            .completed(RefreshKey(repositoryID: parentID, kind: .status), 1, parentStatus)
        )
        coordinator.runtime.handleRefreshEvent(
            .completed(RefreshKey(repositoryID: childID, kind: .status), 1, childStatus)
        )
        return coordinator
    }

    private func makeSidebarRepository(
        id: UUID,
        sourceID: UUID,
        url: URL,
        parentID: UUID? = nil,
        submodulePath: String? = nil,
        hasSubmodules: Bool = false
    ) -> RepoDescriptor {
        RepoDescriptor(
            id: id,
            source: .standalone(id: sourceID),
            url: url,
            canonicalURL: url,
            resourceID: nil,
            relativePath: submodulePath,
            availability: .available,
            submoduleParentRepositoryID: parentID,
            submodulePath: submodulePath,
            hasSubmodules: hasSubmodules
        )
    }

    private func makeSidebarSnapshot(
        base: AppSnapshot,
        state: PersistedState,
        repositories: [RepoDescriptor],
        statuses: [UUID: RepoStatus]
    ) -> AppSnapshot {
        AppSnapshot(
            state: state,
            repositories: repositories,
            scanMessages: [:],
            runtime: RepositoryRuntimeSnapshot(
                refreshStates: statuses.mapValues { RepositoryRefreshState(status: $0) },
                githubURLs: [:],
                activeRepositoryEventWatcherIDs: [],
                coveredRepositoryIDs: []
            ),
            selectedSession: base.selectedSession,
            mutationState: base.mutationState,
            commitMessage: base.commitMessage,
            usesDefaultCommitMessage: base.usesDefaultCommitMessage,
            amendSession: base.amendSession,
            errorMessage: nil,
            stateSaveErrorMessage: nil,
            statusMessage: nil,
            hasLoadedState: true,
            hasStarted: true
        )
    }

    private func repositoryMenuContext(_ menu: NSMenu, repositoryID: UUID) -> RepoSidebarMenuContext {
        RepoSidebarMenuContext(
            menu: menu,
            node: RepoSidebarViewController.Node(
                title: "Parent",
                kind: .repository(repositoryID)
            ),
            repositoryIDs: [repositoryID],
            presentingWindow: nil
        )
    }
}
