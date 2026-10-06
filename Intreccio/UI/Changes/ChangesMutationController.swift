import AppKit

@MainActor
final class ChangesMutationController: NSObject {
    final class IgnoreAction {
        let selectedGitPath: GitPath
        let targetGitPath: GitPath
        let isDirectory: Bool

        var selectedPath: String { selectedGitPath.decodedString }
        var targetPath: String { targetGitPath.decodedString }

        convenience init(selectedPath: String, targetPath: String, isDirectory: Bool) {
            self.init(
                selectedGitPath: GitPath(selectedPath),
                targetGitPath: GitPath(targetPath),
                isDirectory: isDirectory
            )
        }

        init(selectedGitPath: GitPath, targetGitPath: GitPath, isDirectory: Bool) {
            self.selectedGitPath = selectedGitPath
            self.targetGitPath = targetGitPath
            self.isDirectory = isDirectory
        }
    }


    final class MutationContext {
        let selectedChanges: [FileChange]
        let status: RepoStatus
        let repositoryID: UUID
        weak var window: NSWindow?

        init(selectedChanges: [FileChange], status: RepoStatus, repositoryID: UUID, window: NSWindow?) {
            self.selectedChanges = selectedChanges
            self.status = status
            self.repositoryID = repositoryID
            self.window = window
        }
    }

    enum ContextValidation: Equatable {
        case missing
        case stale
        case current
    }

    private let coordinator: AppCoordinator
    private(set) lazy var controlsController = ChangesMutationControlsController(mutationController: self)
    private(set) var currentContext: MutationContext?

    var mutationState: RepositoryMutationState { coordinator.mutationState }
    var canStageSelected: Bool { controlsController.canStageSelected }
    var canStageAll: Bool { controlsController.canStageAll }
    var canUnstageSelected: Bool { controlsController.canUnstageSelected }
    var canUnstageAll: Bool { controlsController.canUnstageAll }
    var canStash: Bool { controlsController.canStash }
    var canRestoreStash: Bool { controlsController.canRestoreStash }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func updateContext(
        selectedChanges: [FileChange],
        status: RepoStatus?,
        repositoryID: UUID?,
        window: NSWindow?
    ) {
        guard let status, let repositoryID else {
            currentContext = nil
            return
        }
        currentContext = MutationContext(
            selectedChanges: selectedChanges,
            status: status,
            repositoryID: repositoryID,
            window: window
        )
    }

    static func contextValidation(
        currentContext: MutationContext?,
        repositoryID: UUID?,
        status: RepoStatus?
    ) -> ContextValidation {
        guard let currentContext else { return .missing }
        guard let status,
              currentContext.repositoryID == repositoryID,
              currentContext.status == status else { return .stale }
        return .current
    }

    func makeControlsView(commitView: NSView) -> NSView {
        controlsController.makeView(commitView: commitView)
    }

    func configure(
        status: RepoStatus?,
        snapshot: AppSnapshot,
        selectedChanges: [FileChange],
        statusContent: RepositoryStatusContent? = nil
    ) {
        let running = snapshot.mutationState == .running
        let content = statusContent ?? status.map { RepositoryStatusContent(status: $0) }
        let rebaseAvailability = ChangesMutationPolicy.rebaseControlAvailability(
            status: status,
            mutationRunning: running,
            conflictCount: content?.conflictCount
        )
        let stashAvailability = ChangesMutationPolicy.stashControlAvailability(
            status: status,
            mutationRunning: running,
            conflictCount: content?.conflictCount
        )
        let rebaseInProgress = status?.isRebaseInProgress == true
        let rebaseLabel: String
        if rebaseInProgress {
            let conflictCount = content?.conflictCount ?? 0
            rebaseLabel = conflictCount == 0
                ? "Rebase paused. Continue to replay remaining commits, or abort to restore the original branch."
                : "Rebase paused with \(conflictCount) conflicted file\(conflictCount == 1 ? "" : "s"). Resolve and stage with Git, refresh, then continue or abort."
        } else {
            rebaseLabel = ""
        }

        controlsController.render(
            ChangesMutationControlsController.Configuration(
                canStageSelected: ChangesMutationPolicy.canStage(
                    changes: selectedChanges,
                    status: status,
                    mutationRunning: running
                ),
                canStageAll: ChangesMutationPolicy.canStageAll(
                    status: status,
                    content: content,
                    mutationRunning: running
                ),
                canUnstageSelected: ChangesMutationPolicy.canUnstage(
                    changes: selectedChanges,
                    status: status,
                    mutationRunning: running
                ),
                canUnstageAll: ChangesMutationPolicy.canUnstageAll(
                    status: status,
                    content: content,
                    mutationRunning: running
                ),
                canStash: stashAvailability.canStash,
                canRestoreStash: stashAvailability.canRestore,
                rebaseButtonTitle: status?.branch.upstream.map { "Rebase on \($0)" } ?? "Rebase on Upstream",
                rebaseLabel: rebaseLabel,
                rebaseInProgress: rebaseInProgress,
                rebaseCanStart: rebaseAvailability.canStart,
                rebaseCanContinue: rebaseAvailability.canContinue,
                rebaseCanAbort: rebaseAvailability.canAbort,
                mutationState: snapshot.mutationState
            )
        )

    }

    private enum ContextFailure {
        case missing
        case stale
        case windowUnavailable
    }

    private func requireCurrentContext(
        for action: String,
        requiresWindow: Bool = false
    ) -> MutationContext? {
        guard let currentContext else {
            reportContextFailure(.missing, action: action)
            return nil
        }
        guard coordinator.state.uiState.mode == .changes,
              Self.contextValidation(
                  currentContext: currentContext,
                  repositoryID: coordinator.state.uiState.selectedRepoID,
                  status: coordinator.selectedStatus
              ) == .current else {
            reportContextFailure(.stale, action: action)
            return nil
        }
        if requiresWindow, currentContext.window == nil {
            reportContextFailure(.windowUnavailable, action: action)
            return nil
        }
        return currentContext
    }

    private func isCurrentContext(_ expected: MutationContext) -> Bool {
        guard let currentContext,
              currentContext.repositoryID == expected.repositoryID,
              currentContext.status == expected.status,
              coordinator.state.uiState.mode == .changes else { return false }
        return Self.contextValidation(
            currentContext: currentContext,
            repositoryID: coordinator.state.uiState.selectedRepoID,
            status: coordinator.selectedStatus
        ) == .current
    }

    private func reportContextFailure(_ failure: ContextFailure, action: String) {
        let reason = switch failure {
        case .missing: "Changes data is not loaded."
        case .stale: "Changes data is stale. Refresh and try again."
        case .windowUnavailable: "The Changes window is not ready."
        }
        controlsController.showContextFailure(action: action, reason: reason)
    }


    @objc func stageSelected(_ sender: Any?) {
        guard let context = requireCurrentContext(for: "Stage Selected"),
              canStageSelected,
              ChangesMutationPolicy.canStage(
                  changes: context.selectedChanges,
                  status: context.status,
                  mutationRunning: coordinator.mutationState == .running
              ) else { return }
        coordinator.stage(changes: context.selectedChanges)
    }

    @objc func stageAll(_ sender: Any?) {
        guard let context = requireCurrentContext(for: "Stage All"),
              canStageAll,
              ChangesMutationPolicy.canStageAll(
                  status: context.status,
                  content: nil,
                  mutationRunning: coordinator.mutationState == .running
              ) else { return }
        coordinator.stageAll()
    }

    @objc func unstageSelected(_ sender: Any?) {
        guard let context = requireCurrentContext(for: "Unstage Selected"),
              canUnstageSelected,
              ChangesMutationPolicy.canUnstage(
                  changes: context.selectedChanges,
                  status: context.status,
                  mutationRunning: coordinator.mutationState == .running
              ) else { return }
        coordinator.unstage(changes: context.selectedChanges)
    }

    @objc func unstageAll(_ sender: Any?) {
        guard let context = requireCurrentContext(for: "Unstage All"),
              canUnstageAll,
              ChangesMutationPolicy.canUnstageAll(
                  status: context.status,
                  content: nil,
                  mutationRunning: coordinator.mutationState == .running
              ) else { return }
        coordinator.unstageAll()
    }

    @objc func stashChanges(_ sender: Any?) {
        guard let context = requireCurrentContext(for: "Stash Changes"),
              canStash,
              ChangesMutationPolicy.stashControlAvailability(
                  status: context.status,
                  mutationRunning: coordinator.mutationState == .running
              ).canStash else { return }
        coordinator.stashChanges()
    }

    @objc func restoreLatestStash(_ sender: Any?) {
        guard let context = requireCurrentContext(for: "Restore Latest Stash"),
              canRestoreStash,
              ChangesMutationPolicy.stashControlAvailability(
                  status: context.status,
                  mutationRunning: coordinator.mutationState == .running
              ).canRestore else { return }
        coordinator.restoreLatestStash()
    }

    @objc func stageChange(_ sender: NSMenuItem) {
        guard let context = requireCurrentContext(for: "Stage Changes"),
              let selectedChanges = sender.representedObject as? [FileChange],
              ChangesMutationPolicy.canStage(
                  changes: selectedChanges,
                  status: context.status,
                  mutationRunning: coordinator.mutationState == .running
              ),
              let changes = ChangesMutationPolicy.stageableChanges(selectedChanges) else { return }
        coordinator.stage(changes: changes)
    }

    @objc func stageFolder(_ sender: NSMenuItem) {
        guard let context = requireCurrentContext(for: "Stage Folder"),
              let folder = sender.representedObject as? String else { return }
        let folderChanges = ChangesMutationPolicy.changes(context.status.changes, inFolder: folder)
        guard ChangesMutationPolicy.canStage(
            changes: folderChanges,
            status: context.status,
            mutationRunning: coordinator.mutationState == .running
        ), let changes = ChangesMutationPolicy.stageableChanges(folderChanges) else { return }
        coordinator.stage(changes: changes)
    }

    @objc func discardChange(_ sender: NSMenuItem) {
        guard let context = requireCurrentContext(for: "Discard Changes", requiresWindow: true),
              let changes = sender.representedObject as? [FileChange],
              ChangesMutationPolicy.canDiscard(
                  changes: changes,
                  status: context.status,
                  mutationRunning: coordinator.mutationState == .running
              ) else { return }
        guard let window = context.window else {
            reportContextFailure(.windowUnavailable, action: "Discard Changes")
            return
        }

        let changesByPath = Dictionary(grouping: changes, by: \.gitPath)
        let untrackedPaths = Set(changesByPath.compactMap { path, pathChanges in
            pathChanges.allSatisfy { $0.kind == .untracked } ? path : nil
        })
        let trackedChanges = changes.filter { !untrackedPaths.contains($0.gitPath) }
        let trackedPaths = Set(GitService.discardAffectedPathValues(for: trackedChanges))
        if !trackedPaths.isEmpty, !untrackedPaths.subtracting(trackedPaths).isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Discard tracked and untracked files separately"
            alert.informativeText = "Select only tracked changes or only untracked files, then try again."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
            return
        }

        let selectedPathCount = Set(changes.map(\.gitPath)).count
        let allUntracked = changes.allSatisfy { $0.kind == .untracked }
        let affectedPaths = GitService.discardAffectedPathValues(for: changes)
        let displayedPaths = affectedPaths.map(\.displayString).joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = if selectedPathCount == 1 {
            allUntracked ? "Delete this untracked file?" : "Discard changes to this file?"
        } else {
            allUntracked
                ? "Delete these \(selectedPathCount) untracked files?"
                : "Discard changes to these \(selectedPathCount) files?"
        }
        alert.informativeText = allUntracked
            ? "This will permanently delete \(displayedPaths) from disk. This cannot be undone."
            : "This will permanently discard all staged and unstaged changes at \(displayedPaths). Newly added files will be deleted from disk. This cannot be undone."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self else { return }
            guard self.isCurrentContext(context) else {
                self.reportContextFailure(.stale, action: "Discard Changes")
                return
            }
            guard ChangesMutationPolicy.normalMutationAvailable(
                status: self.currentContext?.status,
                mutationRunning: self.coordinator.mutationState == .running
            ) else { return }
            self.coordinator.discard(changes: changes)
        }
    }

    @objc func addToGitIgnore(_ sender: NSMenuItem) {
        guard let context = requireCurrentContext(for: "Add to .gitignore"),
              ChangesMutationPolicy.normalMutationAvailable(
                  status: context.status,
                  mutationRunning: coordinator.mutationState == .running
              ),
              let action = sender.representedObject as? IgnoreAction else { return }
        coordinator.addToGitIgnore(
            selectedPath: action.selectedGitPath,
            targetPath: action.targetGitPath,
            isDirectory: action.isDirectory
        )
    }

    @objc func rebaseOnUpstream(_ sender: Any?) {
        guard let context = requireCurrentContext(for: "Rebase", requiresWindow: true),
              ChangesMutationPolicy.rebaseControlAvailability(
                  status: context.status,
                  mutationRunning: coordinator.mutationState == .running
              ).canStart else { return }
        guard let window = context.window else {
            reportContextFailure(.windowUnavailable, action: "Rebase")
            return
        }
        let status = context.status
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Rebase on \(status.branch.upstream ?? "upstream")?"
        alert.informativeText = status.branch.ahead == 0
            ? "This updates the current branch by replaying it on the upstream branch."
            : "This may rewrite \(status.branch.ahead) local commit\(status.branch.ahead == 1 ? "" : "s") by replaying them on the upstream branch."
        alert.addButton(withTitle: "Rebase")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self else { return }
            guard self.isCurrentContext(context) else {
                self.reportContextFailure(.stale, action: "Rebase")
                return
            }
            guard let currentContext = self.currentContext,
                  ChangesMutationPolicy.rebaseControlAvailability(
                      status: currentContext.status,
                      mutationRunning: self.coordinator.mutationState == .running
                  ).canStart else { return }
            self.coordinator.rebaseOnUpstream()
        }
    }

    @objc func continueRebase(_ sender: Any?) {
        guard let context = requireCurrentContext(for: "Continue Rebase"),
              ChangesMutationPolicy.rebaseControlAvailability(
                  status: context.status,
                  mutationRunning: coordinator.mutationState == .running
              ).canContinue else { return }
        coordinator.continueRebase()
    }

    @objc func abortRebase(_ sender: Any?) {
        guard let context = requireCurrentContext(for: "Abort Rebase", requiresWindow: true),
              ChangesMutationPolicy.rebaseControlAvailability(
                  status: context.status,
                  mutationRunning: coordinator.mutationState == .running
              ).canAbort else { return }
        guard let window = context.window else {
            reportContextFailure(.windowUnavailable, action: "Abort Rebase")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Abort rebase?"
        alert.informativeText = "This discards conflict-resolution work and restores the branch to its pre-rebase state."
        alert.addButton(withTitle: "Abort Rebase")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self else { return }
            guard self.isCurrentContext(context) else {
                self.reportContextFailure(.stale, action: "Abort Rebase")
                return
            }
            guard let currentContext = self.currentContext,
                  ChangesMutationPolicy.rebaseControlAvailability(
                      status: currentContext.status,
                      mutationRunning: self.coordinator.mutationState == .running
                  ).canAbort else { return }
            self.coordinator.abortRebase()
        }
    }

}