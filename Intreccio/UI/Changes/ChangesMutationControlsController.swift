import AppKit

@MainActor
final class ChangesMutationControlsController: NSObject {
    struct Configuration {
        let canStageSelected: Bool
        let canStageAll: Bool
        let canUnstageSelected: Bool
        let canUnstageAll: Bool
        let canStash: Bool
        let canRestoreStash: Bool
        let rebaseButtonTitle: String
        let rebaseLabel: String
        let rebaseInProgress: Bool
        let rebaseCanStart: Bool
        let rebaseCanContinue: Bool
        let rebaseCanAbort: Bool
        let mutationState: RepositoryMutationState
    }

    let stageButton = NSButton(title: "Stage Selected", target: nil, action: nil)
    let stageAllButton = NSButton(title: "Stage All", target: nil, action: nil)
    let unstageButton = NSButton(title: "Unstage Selected", target: nil, action: nil)
    let unstageAllButton = NSButton(title: "Unstage All", target: nil, action: nil)
    let stashButton = NSButton(title: "Stash All Changes", target: nil, action: nil)
    let restoreStashButton = NSButton(title: "Restore Latest Stash", target: nil, action: nil)
    let rebaseLabel = NSTextField(wrappingLabelWithString: "")
    let rebaseButton = NSButton(title: "Rebase on Upstream", target: nil, action: nil)
    let continueRebaseButton = NSButton(title: "Continue Rebase", target: nil, action: nil)
    let abortRebaseButton = NSButton(title: "Abort Rebase", target: nil, action: nil)
    let mutationLabel = NSTextField(wrappingLabelWithString: "")
    let mutationDetails = NSTextField(wrappingLabelWithString: "")
    let disclosureButton = NSButton(title: "Show Details", target: nil, action: nil)
    let copyErrorButton = NSButton(title: "Copy Details", target: nil, action: nil)

    private weak var mutationController: ChangesMutationController?
    private var hasBuiltControls = false
    private(set) var controlsView: NSView?

    var canStageSelected: Bool { hasBuiltControls && stageButton.isEnabled }
    var canStageAll: Bool { hasBuiltControls && stageAllButton.isEnabled }
    var canUnstageSelected: Bool { hasBuiltControls && unstageButton.isEnabled }
    var canUnstageAll: Bool { hasBuiltControls && unstageAllButton.isEnabled }
    var canStash: Bool { hasBuiltControls && stashButton.isEnabled }
    var canRestoreStash: Bool { hasBuiltControls && restoreStashButton.isEnabled }

    init(mutationController: ChangesMutationController) {
        self.mutationController = mutationController
        super.init()
    }

    func makeView(commitView: NSView) -> NSView {
        if let controlsView { return controlsView }

        stageButton.target = mutationController
        stageButton.action = #selector(ChangesMutationController.stageSelected(_:))
        stageAllButton.target = mutationController
        stageAllButton.action = #selector(ChangesMutationController.stageAll(_:))
        unstageButton.target = mutationController
        unstageButton.action = #selector(ChangesMutationController.unstageSelected(_:))
        unstageAllButton.target = mutationController
        unstageAllButton.action = #selector(ChangesMutationController.unstageAll(_:))
        stashButton.target = mutationController
        stashButton.action = #selector(ChangesMutationController.stashChanges(_:))
        restoreStashButton.target = mutationController
        restoreStashButton.action = #selector(ChangesMutationController.restoreLatestStash(_:))
        rebaseButton.target = mutationController
        rebaseButton.action = #selector(ChangesMutationController.rebaseOnUpstream(_:))
        continueRebaseButton.target = mutationController
        continueRebaseButton.action = #selector(ChangesMutationController.continueRebase(_:))
        abortRebaseButton.target = mutationController
        abortRebaseButton.action = #selector(ChangesMutationController.abortRebase(_:))

        rebaseLabel.maximumNumberOfLines = 4
        rebaseLabel.textColor = .secondaryLabelColor
        rebaseLabel.font = .preferredFont(forTextStyle: .caption2)
        rebaseLabel.setAccessibilityLabel("Rebase status")
        rebaseButton.setAccessibilityHelp("Replay local commits on the configured upstream branch.")
        continueRebaseButton.setAccessibilityHelp("Continue after all rebase conflicts are resolved and staged.")
        abortRebaseButton.setAccessibilityHelp("Abort the rebase and restore the pre-rebase branch state.")
        stashButton.setAccessibilityHelp("Save all staged, unstaged, and untracked changes, then clean the working tree.")
        restoreStashButton.setAccessibilityHelp("Restore staged, unstaged, and untracked changes from the latest stash.")

        let stageRow = NSStackView(views: [stageButton, stageAllButton])
        stageRow.distribution = .fillEqually
        stageRow.spacing = 6
        let unstageRow = NSStackView(views: [unstageButton, unstageAllButton])
        unstageRow.distribution = .fillEqually
        unstageRow.spacing = 6
        let stashRow = NSStackView(views: [stashButton, restoreStashButton])
        stashRow.distribution = .fillEqually
        stashRow.spacing = 6
        let rebaseRow = NSStackView(views: [continueRebaseButton, abortRebaseButton])
        rebaseRow.distribution = .fillEqually
        rebaseRow.spacing = 6

        mutationLabel.maximumNumberOfLines = 4
        mutationLabel.isSelectable = true
        mutationLabel.textColor = .systemRed
        mutationLabel.font = .preferredFont(forTextStyle: .caption2)
        mutationDetails.isSelectable = true
        mutationDetails.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        mutationDetails.textColor = .secondaryLabelColor
        mutationDetails.isHidden = true
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleMutationDetails(_:))
        disclosureButton.bezelStyle = .inline
        copyErrorButton.target = self
        copyErrorButton.action = #selector(copyMutationDetails(_:))
        copyErrorButton.bezelStyle = .inline
        let errorActions = NSStackView(views: [disclosureButton, copyErrorButton])
        errorActions.orientation = .horizontal
        errorActions.spacing = 8
        let presentationView = NSStackView(views: [mutationLabel, errorActions, mutationDetails])
        presentationView.orientation = .vertical
        presentationView.alignment = .leading
        presentationView.spacing = 6

        let controls = NSStackView(
            views: [
                rebaseLabel,
                rebaseButton,
                rebaseRow,
                stashRow,
                stageRow,
                unstageRow,
                commitView,
                presentationView,
            ]
        )
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6
        for child in [rebaseButton, rebaseRow, stashRow, stageRow, unstageRow, commitView, presentationView] {
            child.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }
        commitView.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        controlsView = controls
        hasBuiltControls = true
        return controls
    }

    func render(_ configuration: Configuration) {
        guard hasBuiltControls else { return }
        stageButton.isEnabled = configuration.canStageSelected
        stageAllButton.isEnabled = configuration.canStageAll
        unstageButton.isEnabled = configuration.canUnstageSelected
        unstageAllButton.isEnabled = configuration.canUnstageAll
        stashButton.isEnabled = configuration.canStash
        restoreStashButton.isEnabled = configuration.canRestoreStash

        rebaseButton.title = configuration.rebaseButtonTitle
        rebaseButton.isHidden = configuration.rebaseInProgress
        rebaseButton.isEnabled = configuration.rebaseCanStart
        continueRebaseButton.isHidden = !configuration.rebaseInProgress
        continueRebaseButton.isEnabled = configuration.rebaseCanContinue
        abortRebaseButton.isHidden = !configuration.rebaseInProgress
        abortRebaseButton.isEnabled = configuration.rebaseCanAbort
        rebaseLabel.stringValue = configuration.rebaseLabel
        rebaseLabel.isHidden = configuration.rebaseLabel.isEmpty

        switch configuration.mutationState {
        case .idle:
            mutationLabel.stringValue = ""
            mutationDetails.stringValue = ""
        case .running:
            mutationLabel.stringValue = "Running Git operation…"
            mutationDetails.stringValue = ""
        case .failed(let failure):
            mutationLabel.stringValue = failure.title + " " + failure.recoverySuggestion
            mutationDetails.stringValue = failure.details
        }
        mutationLabel.isHidden = mutationLabel.stringValue.isEmpty
        let hasDetails = !mutationDetails.stringValue.isEmpty
        disclosureButton.isHidden = !hasDetails
        copyErrorButton.isHidden = !hasDetails
        if !hasDetails {
            mutationDetails.isHidden = true
            disclosureButton.title = "Show Details"
        }
    }

    func showContextFailure(action: String, reason: String) {
        mutationLabel.stringValue = "\(action) unavailable: \(reason)"
        mutationLabel.isHidden = false
        mutationDetails.stringValue = ""
        mutationDetails.isHidden = true
        disclosureButton.isHidden = true
        copyErrorButton.isHidden = true
    }

    @objc private func toggleMutationDetails(_ sender: Any?) {
        mutationDetails.isHidden.toggle()
        disclosureButton.title = mutationDetails.isHidden ? "Show Details" : "Hide Details"
    }

    @objc private func copyMutationDetails(_ sender: Any?) {
        guard case .failed(let failure) = mutationController?.mutationState else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(failure.copyText, forType: .string)
    }
}