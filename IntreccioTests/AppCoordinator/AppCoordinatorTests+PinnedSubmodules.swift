import AppKit
import Foundation
@testable import Intreccio
import XCTest

@MainActor
extension AppCoordinatorTests {
    func testPinnedSubmoduleStaysUnderParentWithoutDuplicate() throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        addTeardownBlock { [coordinator] in _ = await coordinator.shutdown() }
        let sourceID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        let parentURL = directory.appendingPathComponent("parent", isDirectory: true)
        let childURL = parentURL.appendingPathComponent("vendor/child", isDirectory: true)
        var uiState = PersistedUIState()
        uiState.pinnedRepositoryIDs = [childID]
        var grandchildStatus = RepoStatus()
        grandchildStatus.branch = BranchStatus(
            head: "main",
            objectID: "head",
            upstream: "origin/main",
            ahead: 1
        )
        let repositories = [
            makePinnedRepository(id: parentID, sourceID: sourceID, url: parentURL, hasSubmodules: true),
            makePinnedRepository(
                id: childID,
                sourceID: sourceID,
                url: childURL,
                parentID: parentID,
                submodulePath: "vendor/child",
                hasSubmodules: true
            ),
            makePinnedRepository(
                id: grandchildID,
                sourceID: sourceID,
                url: childURL.appendingPathComponent("nested/tool", isDirectory: true),
                parentID: childID,
                submodulePath: "nested/tool"
            )
        ]
        let snapshot = makePinnedSubmoduleSnapshot(
            base: coordinator.snapshot,
            state: PersistedState(uiState: uiState),
            repositories: repositories,
            statuses: [grandchildID: grandchildStatus]
        )
        let controller = RepoSidebarViewController(coordinator: coordinator)
        let nodes = controller.makeNodes(snapshot)
        let parent = try XCTUnwrap(controller.repositoryNodesByID[parentID])
        let child = try XCTUnwrap(controller.repositoryNodesByID[childID])

        XCTAssertEqual(parent.children.map(\.kind), [.repository(childID)])
        XCTAssertEqual(child.children.map(\.kind), [.repository(grandchildID)])
        XCTAssertEqual(countPinnedRepositoryNodes(nodes, id: childID), 1)
        XCTAssertFalse(nodes.contains { $0.kind == .pinnedSection })
    }
    func testStandaloneSubmoduleWarningIsVisibleOnItsRepositoryRow() async throws {
        let directory = try makeTestDirectory()
        let parent = directory.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try runGit(at: parent, arguments: ["init", "-b", "main"])
        let gitModules = """
        [submodule "child"]
            path = ../outside
            url = https://example.invalid/child.git
        """
        try Data(gitModules.utf8).write(to: parent.appendingPathComponent(".gitmodules"))
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        addTeardownBlock { [coordinator] in _ = await coordinator.shutdown() }

        await coordinator.addStandaloneRepository(parent)

        let repository = try XCTUnwrap(coordinator.repositories.first { $0.canonicalURL == parent })
        let snapshot = coordinator.snapshot
        let message = try XCTUnwrap(snapshot.scanMessages[repository.source.id])
        let controller = RepoSidebarViewController(coordinator: coordinator)
        _ = controller.makeNodes(snapshot)
        let node = try XCTUnwrap(controller.repositoryNodesByID[repository.id])

        XCTAssertTrue(message.hasPrefix("Submodule scan warning:"))
        XCTAssertTrue(node.badge?.contains("Warning") == true)
        XCTAssertTrue(node.subtitle?.contains(message) == true)
    }
}

private func makePinnedRepository(
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

@MainActor
private func makePinnedSubmoduleSnapshot(
    base: AppSnapshot,
    state: PersistedState,
    repositories: [RepoDescriptor],
    statuses: [UUID: RepoStatus],
    scanMessages: [UUID: String] = [:]
) -> AppSnapshot {
    AppSnapshot(
        state: state,
        repositories: repositories,
        scanMessages: scanMessages,
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

@MainActor
private func countPinnedRepositoryNodes(
    _ nodes: [RepoSidebarViewController.Node],
    id: UUID
) -> Int {
    nodes.reduce(into: 0) { count, node in
        if node.kind == .repository(id) { count += 1 }
        count += countPinnedRepositoryNodes(node.children, id: id)
    }
}
