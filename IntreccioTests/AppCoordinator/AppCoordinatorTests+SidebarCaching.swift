import AppKit
import Foundation
import XCTest
@testable import Intreccio

extension AppCoordinatorTests {
    func testSidebarTreeCacheUpdatesBadgesWithoutRebuilding() throws {
        let directory = try makeTestDirectory()
        let sourceID = UUID()
        let repositoryID = UUID()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        let source = RepositorySource.watchRoot(
            id: sourceID,
            name: "Workspace",
            path: directory.path
        )
        let repository = RepoDescriptor(
            id: repositoryID,
            source: source,
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.watchRoots = [
            WatchRoot(
                id: sourceID,
                displayName: "Workspace",
                bookmarkData: Data(),
                lastResolvedPath: directory.path,
                resourceID: nil,
                exclusions: []
            )
        ]
        coordinator.publish()

        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        let initialRoot = try XCTUnwrap(controller.roots.first)
        let repositoryNode = try XCTUnwrap(controller.roots.first { $0.title == "Repo" })
        XCTAssertNil(repositoryNode.badge)
#if DEBUG
        XCTAssertEqual(controller.treeBuildCountForTesting, 1)
        XCTAssertEqual(controller.outlineReloadCountForTesting, 1)
#endif

        let key = RefreshKey(repositoryID: repositoryID, kind: .status)
        coordinator.runtime.handleRefreshEvent(.queued(key, 1))
        controller.reload(coordinator.snapshot)
        XCTAssertTrue(controller.roots.first === initialRoot)
        XCTAssertEqual(repositoryNode.badge, "Queued")

        coordinator.runtime.handleRefreshEvent(.running(key, 2))
        controller.reload(coordinator.snapshot)
        XCTAssertTrue(controller.roots.first === initialRoot)
        XCTAssertEqual(repositoryNode.badge, "Refreshing")

        var status = RepoStatus()
        status.changes = [
            FileChange(
                path: "changed.txt",
                originalPath: nil,
                indexState: .modified,
                worktreeState: .unmodified,
                kind: .ordinary,
                submoduleState: nil
            )
        ]
        coordinator.runtime.handleRefreshEvent(.completed(key, 3, status))
        controller.reload(coordinator.snapshot)

        XCTAssertTrue(controller.roots.first === initialRoot)
        XCTAssertEqual(repositoryNode.badge, "L1")
#if DEBUG
        XCTAssertEqual(controller.treeBuildCountForTesting, 1)
        XCTAssertEqual(controller.outlineReloadCountForTesting, 1)
#endif
    }

    func testSidebarBadgeSnapshotTargetsOnlyChangedRepository() throws {
        let directory = try makeTestDirectory()
        let sourceID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let source = RepositorySource.watchRoot(
            id: sourceID,
            name: "Workspace",
            path: directory.path
        )
        func repository(id: UUID, name: String) -> RepoDescriptor {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            return RepoDescriptor(
                id: id,
                source: source,
                url: url,
                canonicalURL: url,
                resourceID: nil,
                relativePath: name,
                availability: .available
            )
        }
        let first = repository(id: firstID, name: "First")
        let second = repository(id: secondID, name: "Second")
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [first, second])
        )
        coordinator.state.watchRoots = [
            WatchRoot(
                id: sourceID,
                displayName: "Workspace",
                bookmarkData: Data(),
                lastResolvedPath: directory.path,
                resourceID: nil,
                exclusions: []
            )
        ]
        coordinator.publish()

        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        let initialRoot = try XCTUnwrap(controller.roots.first)
        let firstNode = try XCTUnwrap(controller.repositoryNodesByID[firstID])
        let secondNode = try XCTUnwrap(controller.repositoryNodesByID[secondID])
#if DEBUG
        XCTAssertEqual(controller.badgeUpdateCountForTesting, 0)
#endif

        let key = RefreshKey(repositoryID: firstID, kind: .status)
        coordinator.runtime.handleRefreshEvent(.queued(key, 1))
        controller.reload(coordinator.snapshot)

        XCTAssertTrue(controller.roots.first === initialRoot)
        XCTAssertEqual(firstNode.badge, "Queued")
        XCTAssertNil(secondNode.badge)
#if DEBUG
        XCTAssertEqual(controller.badgeUpdateCountForTesting, 1)
        XCTAssertEqual(controller.treeBuildCountForTesting, 1)
        XCTAssertEqual(controller.outlineReloadCountForTesting, 1)
#endif

        coordinator.setSearchText("First")
        controller.reload(coordinator.snapshot)

        XCTAssertFalse(controller.roots.first === initialRoot)
#if DEBUG
        XCTAssertEqual(controller.treeBuildCountForTesting, 2)
        XCTAssertEqual(controller.outlineReloadCountForTesting, 2)
#endif
    }
}