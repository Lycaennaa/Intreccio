import AppKit
import XCTest
@testable import Intreccio

extension AppShellTests {
    @MainActor
    func testMutationControlsWireMutationAndPresentationActions() {
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [])
        )
        let mutationController = ChangesMutationController(coordinator: coordinator)
        _ = mutationController.makeControlsView(commitView: NSView())
        let controls = mutationController.controlsController

        XCTAssertTrue(controls.stageButton.target === mutationController)
        XCTAssertEqual(controls.stageButton.action.map(NSStringFromSelector), "stageSelected:")
        XCTAssertTrue(controls.rebaseButton.target === mutationController)
        XCTAssertEqual(controls.rebaseButton.action.map(NSStringFromSelector), "rebaseOnUpstream:")
        XCTAssertTrue(controls.pushButton.target === mutationController)
        XCTAssertEqual(controls.pushButton.action.map(NSStringFromSelector), "pushToUpstream:")
        XCTAssertTrue(controls.disclosureButton.target === controls)
        XCTAssertEqual(controls.disclosureButton.action.map(NSStringFromSelector), "toggleMutationDetails:")
        XCTAssertTrue(controls.copyErrorButton.target === controls)
        XCTAssertEqual(controls.copyErrorButton.action.map(NSStringFromSelector), "copyMutationDetails:")
    }

    @MainActor
    func testMutationControlsRenderExplicitConfiguration() {
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [])
        )
        let mutationController = ChangesMutationController(coordinator: coordinator)
        _ = mutationController.makeControlsView(commitView: NSView())
        let controls = mutationController.controlsController
        let failure = OperationFailure(
            title: "Stage failed",
            recoverySuggestion: "Retry the operation.",
            details: "git returned an error"
        )

        controls.render(
            ChangesMutationControlsController.Configuration(
                canStageSelected: true,
                canStageAll: false,
                canUnstageSelected: true,
                canUnstageAll: false,
                canStash: true,
                canRestoreStash: false,
                canPush: false,
                pushButtonTitle: "Push 2 to origin/main",
                rebaseButtonTitle: "Rebase on origin/main",
                rebaseLabel: "Rebase paused with 1 conflicted file.",
                rebaseInProgress: true,
                rebaseCanStart: false,
                rebaseCanContinue: false,
                rebaseCanAbort: true,
                mutationState: .failed(failure)
            )
        )

        XCTAssertTrue(controls.stageButton.isEnabled)
        XCTAssertFalse(controls.stageAllButton.isEnabled)
        XCTAssertTrue(controls.unstageButton.isEnabled)
        XCTAssertTrue(controls.stashButton.isEnabled)
        XCTAssertFalse(controls.restoreStashButton.isEnabled)
        XCTAssertFalse(controls.pushButton.isEnabled)
        XCTAssertEqual(controls.pushButton.title, "Push 2 to origin/main")
        XCTAssertEqual(controls.rebaseButton.title, "Rebase on origin/main")
        XCTAssertTrue(controls.rebaseButton.isHidden)
        XCTAssertFalse(controls.continueRebaseButton.isHidden)
        XCTAssertTrue(controls.abortRebaseButton.isEnabled)
        XCTAssertEqual(controls.rebaseLabel.stringValue, "Rebase paused with 1 conflicted file.")
        XCTAssertEqual(controls.mutationLabel.stringValue, "Stage failed Retry the operation.")
        XCTAssertEqual(controls.mutationDetails.stringValue, "git returned an error")
        XCTAssertFalse(controls.disclosureButton.isHidden)
        XCTAssertFalse(controls.copyErrorButton.isHidden)
    }
}