import AppKit
import XCTest
@testable import Intreccio

extension AppShellTests {
    @MainActor
    func testCommitCompositionControllerSplitsSummaryAndDescription() {
        let components = ChangesCommitController.commitMessageComponents("Subject\n\nBody")

        XCTAssertEqual(components.summary, "Subject")
        XCTAssertEqual(components.description, "Body")
    }

    @MainActor
    func testChangesTreeSkipsReloadForPhaseOnlyStatusEvents() throws {
        let repositoryID = UUID()
        let repository = makeChangesTestRepository(id: repositoryID, path: "changes-tree-phase-repository")
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID
        let controller = ChangesViewController(coordinator: coordinator)
        controller.loadView()
        let key = RefreshKey(repositoryID: repositoryID, kind: .status)
        var status = RepoStatus()
        status.changes = [
            FileChange(
                path: "shared.txt",
                originalPath: nil,
                indexState: .added,
                worktreeState: .unmodified,
                kind: .ordinary,
                submoduleState: nil
            )
        ]

        coordinator.runtime.handleRefreshEvent(.completed(key, 1, status))
        controller.reload(coordinator.snapshot)
        XCTAssertEqual(controller.commitCompositionController.commitButton.title, "Commit 1 Staged")
#if DEBUG
        XCTAssertEqual(controller.commitCompositionController.stagedPathFallbackBuildCountForTesting, 0)
#endif

        let initialRoot = try XCTUnwrap(controller.roots.first)
        let child = try XCTUnwrap(initialRoot.children.first)
        let childRow = controller.outlineView.row(forItem: child)
        XCTAssertGreaterThanOrEqual(childRow, 0)
        controller.outlineView.selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
        let selectedPaths = controller.selectedGitPaths
        let wasExpanded = controller.outlineView.isItemExpanded(initialRoot)

        let phaseEvents: [(RefreshSchedulerEvent, String?)] = [
            (.queued(key, 2), "Line counts queued"),
            (.running(key, 3), "Calculating line counts"),
            (.completed(key, 4, status), nil),
        ]
        for (event, phaseText) in phaseEvents {
            coordinator.runtime.handleRefreshEvent(event)
            controller.reload(coordinator.snapshot)
            XCTAssertEqual(controller.commitCompositionController.commitButton.title, "Commit 1 Staged")
#if DEBUG
            XCTAssertEqual(controller.commitCompositionController.stagedPathFallbackBuildCountForTesting, 0)
#endif

            if let phaseText {
                XCTAssertTrue(controller.summaryLabel.stringValue.contains(phaseText))
            }
            XCTAssertTrue(controller.roots.first === initialRoot)
            XCTAssertEqual(controller.selectedGitPaths, selectedPaths)
            XCTAssertEqual(controller.outlineView.isItemExpanded(initialRoot), wasExpanded)
        }

        XCTAssertEqual(coordinator.repositoryRefreshStates[repositoryID]?.statusContentGeneration, 1)
#if DEBUG
        XCTAssertEqual(coordinator.runtime.statusContentBuildCountForTesting, 1)
#endif
#if DEBUG
        XCTAssertEqual(controller.treeBuildCountForTesting, 1)
        XCTAssertEqual(controller.outlineReloadCountForTesting, 1)
#endif

        var changedStatus = status
        changedStatus.changes.append(
            FileChange(
                path: "new.txt",
                originalPath: nil,
                indexState: .added,
                worktreeState: .unmodified,
                kind: .ordinary,
                submoduleState: nil
            )
        )
        coordinator.runtime.handleRefreshEvent(.completed(key, 5, changedStatus))
        controller.reload(coordinator.snapshot)
        XCTAssertEqual(controller.commitCompositionController.commitButton.title, "Commit 2 Staged")
#if DEBUG
        XCTAssertEqual(controller.commitCompositionController.stagedPathFallbackBuildCountForTesting, 0)
#endif


        XCTAssertFalse(controller.roots.first === initialRoot)
        XCTAssertEqual(controller.selectedGitPaths, selectedPaths)
        XCTAssertEqual(coordinator.repositoryRefreshStates[repositoryID]?.statusContentGeneration, 2)
#if DEBUG
        XCTAssertEqual(coordinator.runtime.statusContentBuildCountForTesting, 2)
#endif
#if DEBUG
        XCTAssertEqual(controller.treeBuildCountForTesting, 2)
        XCTAssertEqual(controller.outlineReloadCountForTesting, 2)
#endif
    }

    @MainActor
    func testChangesTreeRestoresLossySelectionByRawPathBytes() throws {
        let repositoryID = UUID()
        let repository = makeChangesTestRepository(id: repositoryID, path: "changes-tree-lossy-repository")
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID
        let controller = ChangesViewController(coordinator: coordinator)
        controller.loadView()
        let key = RefreshKey(repositoryID: repositoryID, kind: .status)
        let firstLossyPath = GitPath(bytes: Data([0x62, 0x61, 0x64, 0xFF, 0x2E, 0x74, 0x78, 0x74]))
        let secondLossyPath = GitPath(bytes: Data([0x62, 0x61, 0x64, 0xFE, 0x2E, 0x74, 0x78, 0x74]))
        var status = RepoStatus()
        status.changes = [firstLossyPath, secondLossyPath].map { path in
            FileChange(
                gitPath: path,
                originalGitPath: nil,
                indexState: .added,
                worktreeState: .unmodified,
                kind: .ordinary,
                submoduleState: nil
            )
        }

        coordinator.runtime.handleRefreshEvent(.completed(key, 1, status))
        controller.reload(coordinator.snapshot)
        let root = try XCTUnwrap(controller.roots.first)
        XCTAssertEqual(root.children.count, 2)
        var selectedRows = IndexSet()
        for child in root.children {
            selectedRows.insert(controller.outlineView.row(forItem: child))
        }
        controller.outlineView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        let selectedPaths = controller.selectedGitPaths

        coordinator.runtime.handleRefreshEvent(.completed(key, 2, status))
        controller.reload(coordinator.snapshot)

        XCTAssertEqual(selectedPaths, controller.selectedGitPaths)
        XCTAssertEqual(Set(controller.selectedGitPaths.map(\.displayString)), Set([firstLossyPath.displayString, secondLossyPath.displayString]))
    }

    @MainActor
    func testCommitCompositionUsesCachedStagedPathCountDuringAmend() {
        let coordinator = AppCoordinator()
        coordinator.commitMessage = "Amended subject\n\nAmended body"
        coordinator.usesDefaultCommitMessage = false
        coordinator.amendSession = AppCoordinator.AmendSession(
            repositoryID: UUID(),
            commit: Commit(
                objectID: "head",
                parentIDs: [],
                authorName: "Author",
                authorEmail: "author@example.com",
                authoredAt: Date(),
                subject: "Original subject",
                body: ""
            ),
            previousMessage: "Saved draft",
            previousUsesDefaultMessage: false
        )
        coordinator.publish()

        let status = RepoStatus(changes: [
            FileChange(
                path: "staged.txt",
                originalPath: nil,
                indexState: .added,
                worktreeState: .unmodified,
                kind: .ordinary,
                submoduleState: nil
            )
        ])
        let controller = ChangesCommitController(coordinator: coordinator)
        _ = controller.view
        controller.configure(
            status: status,
            snapshot: coordinator.snapshot,
            statusContent: RepositoryStatusContent(status: status)
        )

        XCTAssertEqual(controller.commitButton.title, "Amend Last Commit")
        XCTAssertTrue(controller.commitButton.isEnabled)
        XCTAssertEqual(controller.summaryTextView.string, "Amended subject")
        XCTAssertEqual(controller.descriptionTextView.string, "Amended body")
#if DEBUG
        XCTAssertEqual(controller.stagedPathFallbackBuildCountForTesting, 0)
#endif
    }
    @MainActor
    func testChangesTreeCacheSeparatesRepositoriesAndIgnoresStaleStatus() throws {
        let firstID = UUID()
        let secondID = UUID()
        let repositories = [
            makeChangesTestRepository(id: firstID, path: "changes-tree-first-repository"),
            makeChangesTestRepository(id: secondID, path: "changes-tree-second-repository"),
        ]
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: repositories)
        )
        coordinator.state.uiState.selectedRepoID = firstID
        let controller = ChangesViewController(coordinator: coordinator)
        controller.loadView()
        let firstKey = RefreshKey(repositoryID: firstID, kind: .status)
        let secondKey = RefreshKey(repositoryID: secondID, kind: .status)
        let status = makeChangesTestStatus(paths: ["shared.txt"])

        coordinator.runtime.handleRefreshEvent(.completed(firstKey, 4, status))
        controller.reload(coordinator.snapshot)
        let firstRoot = try XCTUnwrap(controller.roots.first)

        coordinator.state.uiState.selectedRepoID = secondID
        coordinator.runtime.handleRefreshEvent(.completed(secondKey, 1, status))
        controller.reload(coordinator.snapshot)
        let secondRoot = try XCTUnwrap(controller.roots.first)

        XCTAssertFalse(secondRoot === firstRoot)
        XCTAssertEqual(coordinator.repositoryRefreshStates[firstID]?.statusContentGeneration, 1)
        XCTAssertEqual(coordinator.repositoryRefreshStates[secondID]?.statusContentGeneration, 1)
#if DEBUG
        XCTAssertEqual(coordinator.runtime.statusContentBuildCountForTesting, 2)
#endif
#if DEBUG
        XCTAssertEqual(controller.treeBuildCountForTesting, 2)
        XCTAssertEqual(controller.outlineReloadCountForTesting, 2)
#endif

        let staleStatus = makeChangesTestStatus(paths: ["stale.txt"])
        coordinator.runtime.handleRefreshEvent(.completed(firstKey, 3, staleStatus))
        controller.reload(coordinator.snapshot)

        XCTAssertTrue(controller.roots.first === secondRoot)
        XCTAssertEqual(controller.roots.first?.children.first?.title, "shared.txt")
        XCTAssertEqual(coordinator.repositoryRefreshStates[firstID]?.statusGeneration, 4)
#if DEBUG
        XCTAssertEqual(coordinator.runtime.statusContentBuildCountForTesting, 2)
#endif
#if DEBUG
        XCTAssertEqual(controller.treeBuildCountForTesting, 2)
        XCTAssertEqual(controller.outlineReloadCountForTesting, 2)
#endif
    }
}