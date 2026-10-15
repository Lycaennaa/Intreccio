import AppKit
@testable import Intreccio
import XCTest

extension AppShellTests {
    func testMutationAvailabilityBelongsToMutationPolicy() {
        var status = RepoStatus()
        status.branch.head = "main"
        status.branch.upstream = "origin/main"
        status.branch.behind = 1

        let availability = ChangesMutationPolicy.rebaseControlAvailability(
            status: status,
            mutationRunning: false
        )

        XCTAssertTrue(availability.canStart)
        XCTAssertFalse(availability.canContinue)
        XCTAssertFalse(availability.canAbort)
    }
    func testPushPolicyAllowsOnlyAheadCurrentBranchesWithoutDivergence() {
        var status = RepoStatus()
        status.branch.head = "main"
        status.branch.upstream = "origin/main"
        status.branch.ahead = 2
        status.pushAccess = .allowed
        status.changes = [FileChange(
            path: "dirty.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )]
        func availability() -> PushControlAvailability {
            ChangesMutationPolicy.pushControlAvailability(status: status, mutationRunning: false)
        }

        XCTAssertEqual(availability(), .ready)
        status.pushAccess = .denied
        XCTAssertEqual(availability(), .writeAccessDenied)
        status.pushAccess = .unavailable
        XCTAssertEqual(availability(), .writeAccessUnavailable)
        status.pushAccess = .allowed
        status.branch.behind = 1
        XCTAssertEqual(availability(), .behindUpstream)
        status.branch.behind = 0
        status.isRebaseInProgress = true
        XCTAssertEqual(availability(), .rebaseInProgress)
    }

    @MainActor
    func testMutationContextTracksCurrentSelectionAndClearsMissingStatus() {
        let repositoryID = UUID()
        let change = FileChange(
            path: "current.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )
        var status = RepoStatus()
        status.changes = [change]
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [])
        )
        let controller = ChangesMutationController(coordinator: coordinator)

        controller.updateContext(
            selectedChanges: [change],
            status: status,
            repositoryID: repositoryID,
            window: nil
        )

        XCTAssertEqual(controller.currentContext?.repositoryID, repositoryID)
        XCTAssertEqual(controller.currentContext?.selectedChanges, [change])
        XCTAssertEqual(controller.currentContext?.status, status)

        controller.updateContext(
            selectedChanges: [change],
            status: nil,
            repositoryID: repositoryID,
            window: nil
        )
        XCTAssertNil(controller.currentContext)
    }

    @MainActor
    func testMutationContextValidationDistinguishesMissingStaleAndCurrent() {
        let repositoryID = UUID()
        let status = RepoStatus()
        let context = ChangesMutationController.MutationContext(
            selectedChanges: [],
            status: status,
            repositoryID: repositoryID,
            window: nil
        )

        XCTAssertEqual(
            ChangesMutationController.contextValidation(
                currentContext: nil,
                repositoryID: repositoryID,
                status: status
            ),
            .missing
        )
        XCTAssertEqual(
            ChangesMutationController.contextValidation(
                currentContext: context,
                repositoryID: repositoryID,
                status: status
            ),
            .current
        )
        XCTAssertEqual(
            ChangesMutationController.contextValidation(
                currentContext: context,
                repositoryID: UUID(),
                status: status
            ),
            .stale
        )
        var changedStatus = status
        changedStatus.hasStash = true
        XCTAssertEqual(
            ChangesMutationController.contextValidation(
                currentContext: context,
                repositoryID: repositoryID,
                status: changedStatus
            ),
            .stale
        )
    }

    @MainActor
    func testMissingMutationContextIsReportedInsteadOfSilentlyIgnoringAction() {
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [])
        )
        let controller = ChangesMutationController(coordinator: coordinator)
        _ = controller.makeControlsView(commitView: NSView())

        controller.stageAll(nil)

        XCTAssertEqual(
            controller.controlsController.mutationLabel.stringValue,
            "Stage All unavailable: Changes data is not loaded."
        )
        XCTAssertFalse(controller.controlsController.mutationLabel.isHidden)
    }

    func testStageableChangesExtractsValidActionSelection() {
        let unstaged = FileChange(
            path: "unstaged.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )
        let staged = FileChange(
            path: "staged.txt",
            originalPath: nil,
            indexState: .added,
            worktreeState: .unmodified,
            kind: .ordinary,
            submoduleState: nil
        )
        let conflict = FileChange(
            path: "conflict.txt",
            originalPath: nil,
            indexState: .unmerged,
            worktreeState: .unmerged,
            kind: .unmerged,
            submoduleState: nil
        )

        XCTAssertEqual(ChangesMutationPolicy.stageableChanges([unstaged]), [unstaged])
        XCTAssertNil(ChangesMutationPolicy.stageableChanges([staged]))
        XCTAssertNil(ChangesMutationPolicy.stageableChanges([conflict]))
        XCTAssertNil(ChangesMutationPolicy.stageableChanges([]))
    }
    func testStageFolderIncludesRenameSourcesInsideFolder() {
        let rename = FileChange(
            path: "new/name.txt",
            originalPath: "old/name.txt",
            indexState: .unmodified,
            worktreeState: .renamed,
            kind: .renamed,
            submoduleState: nil
        )
        let unrelated = FileChange(
            path: "other.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )

        XCTAssertEqual(ChangesMutationPolicy.changes([rename, unrelated], inFolder: "old"), [rename])

        let copy = FileChange(
            path: "copy.txt",
            originalPath: "source.txt",
            indexState: .copied,
            worktreeState: .unmodified,
            kind: .copied,
            submoduleState: nil
        )
        XCTAssertEqual(GitService.discardAffectedPaths(for: [rename]), ["new/name.txt", "old/name.txt"])
        XCTAssertEqual(GitService.discardAffectedPaths(for: [copy]), ["copy.txt"])
    }

    func testRebaseControlsRequireCleanBehindBranchAndResolvedConflicts() {
        var status = RepoStatus()
        status.branch.head = "main"
        status.branch.upstream = "origin/main"
        status.branch.behind = 1

        var availability = ChangesMutationPolicy.rebaseControlAvailability(
            status: status,
            mutationRunning: false
        )
        XCTAssertTrue(availability.canStart)
        XCTAssertFalse(availability.canContinue)
        XCTAssertFalse(availability.canAbort)

        status.changes = [FileChange(
            path: "dirty.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )]
        availability = ChangesMutationPolicy.rebaseControlAvailability(status: status, mutationRunning: false)
        XCTAssertFalse(availability.canStart)

        status.isRebaseInProgress = true
        status.changes[0] = FileChange(
            path: "conflict.txt",
            originalPath: nil,
            indexState: .unmerged,
            worktreeState: .unmerged,
            kind: .unmerged,
            submoduleState: nil
        )
        availability = ChangesMutationPolicy.rebaseControlAvailability(status: status, mutationRunning: false)
        XCTAssertFalse(availability.canStart)
        XCTAssertFalse(availability.canContinue)
        XCTAssertTrue(availability.canAbort)

        status.changes = []
        availability = ChangesMutationPolicy.rebaseControlAvailability(status: status, mutationRunning: false)
        XCTAssertTrue(availability.canContinue)
        XCTAssertTrue(availability.canAbort)
    }

    func testStashControlsRequireSafeRepositoryState() {
        var status = RepoStatus()
        status.branch.objectID = String(repeating: "a", count: 40)

        var availability = ChangesMutationPolicy.stashControlAvailability(status: status, mutationRunning: false)
        XCTAssertFalse(availability.canStash)
        XCTAssertFalse(availability.canRestore)

        status.changes = [FileChange(
            path: "dirty.txt",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )]
        availability = ChangesMutationPolicy.stashControlAvailability(status: status, mutationRunning: false)
        XCTAssertTrue(availability.canStash)
        XCTAssertFalse(availability.canRestore)

        status.hasStash = true
        availability = ChangesMutationPolicy.stashControlAvailability(status: status, mutationRunning: false)
        XCTAssertTrue(availability.canStash)
        XCTAssertFalse(availability.canRestore)

        status.changes = []
        availability = ChangesMutationPolicy.stashControlAvailability(status: status, mutationRunning: false)
        XCTAssertFalse(availability.canStash)
        XCTAssertTrue(availability.canRestore)

        status.branch.objectID = nil
        availability = ChangesMutationPolicy.stashControlAvailability(status: status, mutationRunning: false)
        XCTAssertFalse(availability.canStash)
        XCTAssertFalse(availability.canRestore)

        status.branch.objectID = String(repeating: "a", count: 40)
        status.isRebaseInProgress = true
        availability = ChangesMutationPolicy.stashControlAvailability(status: status, mutationRunning: false)
        XCTAssertFalse(availability.canStash)
        XCTAssertFalse(availability.canRestore)
    }
}
