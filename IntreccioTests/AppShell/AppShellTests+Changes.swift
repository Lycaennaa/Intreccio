import AppKit
@testable import Intreccio
import XCTest

func makeChangesTestRepository(id: UUID = UUID(), path: String) -> RepoDescriptor {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    return RepoDescriptor(
        id: id,
        source: .standalone(id: id),
        url: url,
        canonicalURL: url,
        resourceID: nil,
        relativePath: nil,
        availability: .available
    )
}

func makeChangesTestStatus(paths: [String]) -> RepoStatus {
    var status = RepoStatus()
    status.changes = paths.map {
        FileChange(
            path: $0,
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )
    }
    return status
}

extension AppShellTests {
    @MainActor
    func testRepositoryStatusContentCachesCountsWithoutChangingDisplayedSemantics() {
        func change(
            _ path: String,
            indexState: GitFileState,
            worktreeState: GitFileState,
            kind: FileChangeKind
        ) -> FileChange {
            FileChange(
                path: path,
                originalPath: nil,
                indexState: indexState,
                worktreeState: worktreeState,
                kind: kind,
                submoduleState: nil
            )
        }

        var status = RepoStatus()
        status.branch.behind = 2
        status.changes = [
            change("same.txt", indexState: .added, worktreeState: .unmodified, kind: .ordinary),
            change("same.txt", indexState: .unmodified, worktreeState: .modified, kind: .ordinary),
            change("conflict.txt", indexState: .unmerged, worktreeState: .unmerged, kind: .unmerged),
            change("ignored.txt", indexState: .unmodified, worktreeState: .unmodified, kind: .ignored)
        ]

        let content = RepositoryStatusContent(status: status)
        XCTAssertEqual(content.changeCount, 2)
        XCTAssertEqual(content.stagedCount, 2)
        XCTAssertEqual(content.unstagedCount, 2)
        XCTAssertEqual(content.conflictCount, 1)
        XCTAssertEqual(content.stagedPathCount, 2)
        XCTAssertEqual(
            ChangesViewController.changeSummary(for: status, content: content),
            "2 staged   2 unstaged"
        )

        var state = RepositoryRefreshState(status: status)
        XCTAssertEqual(state.changeCount, 2)
        XCTAssertEqual(state.sidebarBadge, "L2 || U2")

        state.updateStatus(nil, content: nil)
        XCTAssertNil(state.statusContent)
        XCTAssertNil(state.changeCount)
        XCTAssertNil(state.sidebarBadge)
    }

    @MainActor
    func testRepositoryStatusContentInvalidatesWhenStagedPathsChange() {
        func stagedChange(_ path: String) -> FileChange {
            FileChange(
                path: path,
                originalPath: nil,
                indexState: .added,
                worktreeState: .unmodified,
                kind: .ordinary,
                submoduleState: nil
            )
        }

        var status = RepoStatus()
        status.changes = [stagedChange("first.txt")]
        var state = RepositoryRefreshState(status: status)
        XCTAssertEqual(state.statusContent?.stagedPathCount, 1)

        status.changes.append(stagedChange("second.txt"))
        state.status = status
        XCTAssertNil(state.statusContent)

        state.updateStatus(status, content: RepositoryStatusContent(status: status))
        XCTAssertEqual(state.statusContent?.stagedPathCount, 2)
    }

    func testContextMenuTargetsFullSelectionOnlyWhenClickedRowIsSelected() {
        let first = FileChange(
            path: "first.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )
        let second = FileChange(
            path: "second.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )

        XCTAssertEqual(
            ChangesViewController.contextMenuChanges(
                clickedChanges: [first],
                selectedChanges: [first, second],
                clickedRowIsSelected: true
            ),
            [first, second]
        )
        XCTAssertEqual(
            ChangesViewController.contextMenuChanges(
                clickedChanges: [first],
                selectedChanges: [second],
                clickedRowIsSelected: false
            ),
            [first]
        )
    }

    @MainActor
    func testChangeSummaryIncludesStagedAndUnstagedLineStats() {
        var status = RepoStatus()
        status.changes = [
            FileChange(
                path: "staged.txt",
                originalPath: nil,
                indexState: .added,
                worktreeState: .unmodified,
                kind: .ordinary,
                submoduleState: nil
            ),
            FileChange(
                path: "unstaged.txt",
                originalPath: nil,
                indexState: .unmodified,
                worktreeState: .modified,
                kind: .ordinary,
                submoduleState: nil
            )
        ]
        status.stagedLineStats = DiffLineStats(
            additions: 3,
            deletions: 2,
            slocAdditions: 2,
            slocDeletions: 1,
            hasNonCodeFiles: true,
            hasCodeFiles: true
        )
        status.unstagedLineStats = DiffLineStats(
            additions: 4,
            deletions: 1,
            slocAdditions: 3,
            slocDeletions: 0,
            hasNonCodeFiles: true,
            hasCodeFiles: true
        )

        XCTAssertEqual(
            ChangesViewController.changeSummary(for: status),
            "1 staged (+3 -2, +2 SLOC -1 SLOC)   1 unstaged (+4 -1, +3 SLOC -0 SLOC)"
        )
        var codeOnlyStatus = status
        codeOnlyStatus.stagedLineStats = DiffLineStats(
            additions: 3,
            deletions: 2,
            slocAdditions: 3,
            slocDeletions: 2,
            hasCodeFiles: true
        )
        codeOnlyStatus.unstagedLineStats = DiffLineStats(
            additions: 4,
            deletions: 1,
            slocAdditions: 4,
            slocDeletions: 1,
            hasCodeFiles: true
        )
        XCTAssertEqual(
            ChangesViewController.changeSummary(for: codeOnlyStatus),
            "1 staged (+3 -2)   1 unstaged (+4 -1)"
        )
        var nonCodeOnlyStatus = status
        nonCodeOnlyStatus.stagedLineStats = DiffLineStats(
            additions: 3,
            deletions: 2,
            hasNonCodeFiles: true
        )
        nonCodeOnlyStatus.unstagedLineStats = DiffLineStats(
            additions: 4,
            deletions: 1,
            hasNonCodeFiles: true
        )
        XCTAssertEqual(
            ChangesViewController.changeSummary(for: nonCodeOnlyStatus),
            "1 staged (+3 -2)   1 unstaged (+4 -1)"
        )
        var unavailableStatus = status
        unavailableStatus.stagedLineStats = DiffLineStats(
            additions: 3,
            deletions: 2,
            hasNonCodeFiles: true,
            hasCodeFiles: true,
            slocAvailability: .unavailable
        )
        unavailableStatus.unstagedLineStats = DiffLineStats(
            additions: 4,
            deletions: 1,
            hasNonCodeFiles: true,
            hasCodeFiles: true,
            slocAvailability: .unavailable
        )
        XCTAssertEqual(
            ChangesViewController.changeSummary(for: unavailableStatus),
            "1 staged (+3 -2)   1 unstaged (+4 -1)"
        )
    }

}
