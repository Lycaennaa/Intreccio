import AppKit

@MainActor
final class PushToOriginToolbarController {
    private let coordinator: AppCoordinator
    private weak var window: NSWindow?
    private var button: NSButton?
    private var isPreparing = false
    private var isSelectingRepositories = false
    private var isTerminating = false
    private var preparationTask: Task<Void, Never>?

    init(coordinator: AppCoordinator, window: NSWindow) {
        self.coordinator = coordinator
        self.window = window
    }

    func toolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Push to Origin"
        item.paletteLabel = "Push to Origin"
        item.isNavigational = true
        let pushButton = NSButton(
            title: "Push to Origin (0)",
            target: self,
            action: #selector(pushToOrigin(_:))
        )
        pushButton.image = NSImage(
            systemSymbolName: "arrow.up.to.line",
            accessibilityDescription: "Push to Origin"
        )
        pushButton.bezelStyle = .texturedRounded
        pushButton.imagePosition = .imageLeading
        pushButton.setAccessibilityLabel("Push to Origin")
        item.view = pushButton
        button = pushButton
        update(coordinator.snapshot)
        return item
    }

    func update(_ snapshot: AppSnapshot) {
        let candidates = PushToOriginPolicy.candidates(
            repositories: snapshot.repositories,
            refreshStates: snapshot.runtime.refreshStates
        )
        let readyCount = candidates.filter { PushToOriginPolicy.isReady(status: $0.status) }.count
        if coordinator.mutationIsBatchPush, snapshot.mutationState == .running {
            button?.title = "Pushing to Origin…"
            button?.toolTip = "Pushing the selected repositories to origin."
            button?.setAccessibilityLabel("Pushing repositories to origin")
        } else if isPreparing, !isSelectingRepositories {
            button?.title = "Preparing Push…"
            button?.toolTip = "Preparing the selected repositories from the latest status."
            button?.setAccessibilityLabel("Preparing selected repositories to push")
        } else {
            button?.title = "Push to Origin (\(readyCount))"
            button?.toolTip = "\(readyCount) repositories ready to push to origin. "
                + "\(candidates.count) repositories have outgoing commits on origin."
            button?.setAccessibilityLabel(
                "Push to Origin, \(readyCount) repositories ready to push"
            )
        }
        button?.isEnabled = !isTerminating
            && !isPreparing
            && snapshot.mutationState != .running
            && !candidates.isEmpty
    }

    @objc func pushToOrigin(_ sender: Any?) {
        guard !isTerminating,
              !isPreparing,
              coordinator.mutationState != .running,
              let window else { return }
        let candidates = PushToOriginPolicy.candidates(
            repositories: coordinator.snapshot.repositories,
            refreshStates: coordinator.snapshot.runtime.refreshStates
        )
        guard !candidates.isEmpty else { return }
        isPreparing = true
        isSelectingRepositories = true
        update(coordinator.snapshot)
        PushToOriginPanel.present(
            on: window,
            candidates: candidates,
            onSelect: { [weak self] selectedCandidates in
                self?.selectionCompleted(selectedCandidates)
            }
        )
    }

    func prepareForTermination() -> Task<Void, Never>? {
        isTerminating = true
        isSelectingRepositories = false
        isPreparing = false
        let task = preparationTask
        task?.cancel()
        preparationTask = nil
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
        button?.isEnabled = false
        return task
    }

    func resumeAfterFailedTermination() {
        isTerminating = false
        update(coordinator.snapshot)
    }

    private func prepare(_ candidate: PushToOriginCandidate) async throws -> GitPushTarget {
        guard !isTerminating,
              let current = coordinator.repositories.first(where: {
                  $0.id == candidate.repository.id
              }),
              current.availability == .available,
              current.canonicalURL == candidate.repository.canonicalURL else {
            throw GitServiceError.pushTargetChanged
        }
        let target = try await coordinator.gitService.preparePushTarget(
            repository: current.canonicalURL,
            status: candidate.status
        )
        try Task.checkCancellation()
        guard !isTerminating,
              coordinator.repositories.contains(where: {
                  $0.id == candidate.repository.id
                      && $0.availability == .available
                      && $0.canonicalURL == candidate.repository.canonicalURL
              }) else {
            throw CancellationError()
        }
        return target
    }

    private func selectionCompleted(_ candidates: [PushToOriginCandidate]?) {
        isSelectingRepositories = false
        guard !isTerminating, let candidates, !candidates.isEmpty, let window else {
            isPreparing = false
            update(coordinator.snapshot)
            return
        }
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var targets = [GitPushTarget]()
                targets.reserveCapacity(candidates.count)
                for candidate in candidates {
                    try Task.checkCancellation()
                    targets.append(try await prepare(candidate))
                }
                try Task.checkCancellation()
                guard !isTerminating else { throw CancellationError() }
                preparationTask = nil
                isPreparing = false
                update(coordinator.snapshot)
                presentConfirmation(targets, on: window)
            } catch {
                preparationTask = nil
                isPreparing = false
                update(coordinator.snapshot)
                guard !Task.isCancelled, !isTerminating else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not prepare selected repositories"
                alert.informativeText = String(describing: error)
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window) { _ in }
            }
        }
    }

    private func presentConfirmation(_ targets: [GitPushTarget], on window: NSWindow) {
        let commitCount = targets.reduce(0) { $0 + $1.ahead }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Push \(targets.count) repositories to origin?"
        alert.informativeText = """
            Push \(commitCount) local commits. Uncommitted changes are not included.
            Force push is never used.
            """
        alert.addButton(withTitle: "Push to Origin")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  !isTerminating else { return }
            coordinator.pushToUpstream(targets)
            guard !coordinator.hasActiveMutation else { return }
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .warning
            errorAlert.messageText = "Push could not start"
            errorAlert.informativeText = """
                A repository changed or another operation started after confirmation.
                Review the repositories and try again.
                """
            errorAlert.addButton(withTitle: "OK")
            errorAlert.beginSheetModal(for: window) { _ in }
        }
    }
}
