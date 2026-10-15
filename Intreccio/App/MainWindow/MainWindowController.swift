import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultWindowTitle = "Intreccio"

    private let coordinator: AppCoordinator
    let contentController: MainWindowContentController
    let geometryController: MainWindowGeometryController
    let settingsPresenter: SettingsPanelPresenter
    let commandRouter: MainWindowCommandRouter
    private var isTerminating = false
    private var snapshotHandlerID: UUID?

    var restoredWindowState: Bool { geometryController.hasRestoredState }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let contentController = MainWindowContentController(coordinator: coordinator)
        let window = contentController.makeWindow()
        let downloadManager = RepositoryDownloadManager(coordinator: coordinator)
        downloadManager.attach(to: window)
        window.title = Self.defaultWindowTitle
        let geometryController = MainWindowGeometryController(
            coordinator: coordinator,
            contentController: contentController
        )
        geometryController.attach(to: window)
        let settingsPresenter = SettingsPanelPresenter(
            coordinator: coordinator,
            contentController: contentController,
            geometryController: geometryController,
            window: window,
            downloadManager: downloadManager
        )
        let commandRouter = MainWindowCommandRouter(
            coordinator: coordinator,
            contentController: contentController,
            settingsPresenter: settingsPresenter,
            window: window,
            downloadManager: downloadManager
        )
        self.contentController = contentController
        self.geometryController = geometryController
        self.settingsPresenter = settingsPresenter
        self.commandRouter = commandRouter
        super.init(window: window)

        updateWindowTitle(coordinator.snapshot)
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateReduceMotion),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        updateReduceMotion()
        commandRouter.configureToolbar()
        contentController.onRefreshRequested = { [weak self] in self?.coordinatorDidChange() }
        snapshotHandlerID = coordinator.addSnapshotHandler { [weak self] snapshot in
            self?.coordinatorDidChange(snapshot)
        }
        coordinator.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        if let snapshotHandlerID {
            MainActor.assumeIsolated {
                coordinator.removeSnapshotHandler(snapshotHandlerID)
            }
        }
        NotificationCenter.default.removeObserver(self)
    }

    func rescanIfLoaded() {
        coordinator.rescanAllIfStale()
    }

    func flushState() async -> Bool {
        isTerminating = true
        settingsPresenter.prepareForTermination()
        let renderingTask = contentController.cancelRendering()
        let sidebarTasks = contentController.cancelSidebarOperations()
        let directoryOperation = await commandRouter.cancelDirectoryOperationForTermination()
        let saved = await coordinator.shutdown()
        await renderingTask?.value
        await TaskCompletionDrain.waitForCompletion(sidebarTasks + [directoryOperation].compactMap(\.self))
        commandRouter.finishTerminationWait()
        if !saved {
            isTerminating = false
            settingsPresenter.resumeAfterFailedTermination()
            commandRouter.resumeAfterFailedTermination()
            contentController.resumeSidebarOperations()
            coordinatorDidChange()
        }
        return saved
    }

    var hasActiveMutation: Bool { coordinator.hasActiveMutation }

    func closeMutationAdmission() {
        coordinator.mutationAdmissionClosed = true
    }

    func reopenMutationAdmission() {
        coordinator.mutationAdmissionClosed = false
    }

    func waitForMutation() async -> Bool {
        let failure = await coordinator.waitForActiveMutation()
        return failure == nil
    }

    func windowDidMove(_ notification: Notification) {
        settingsPresenter.updateFrame()
        geometryController.windowDidMoveOrResize()
    }

    func windowDidResize(_ notification: Notification) {
        settingsPresenter.updateFrame()
        geometryController.windowDidMoveOrResize()
    }

    private func coordinatorDidChange() {
        coordinatorDidChange(coordinator.snapshot)
    }

    private func coordinatorDidChange(_ snapshot: AppSnapshot) {
        guard !isTerminating else { return }
        updateWindowTitle(snapshot)
        if geometryController.restoreIfReady() {
            contentController.focusRepositoryList()
        }
        contentController.refresh(snapshot)
        commandRouter.updatePushToOriginToolbar(snapshot)
        settingsPresenter.presentIfPendingAndReady()
    }

    private func updateWindowTitle(_ snapshot: AppSnapshot) {
        guard let selectedID = snapshot.state.uiState.selectedRepoID,
              let repository = snapshot.repositories.first(where: { $0.id == selectedID }),
              repository.availability == .available else {
            window?.title = Self.defaultWindowTitle
            return
        }
        window?.title = repository.displayName
    }

    @objc private func updateReduceMotion() {
        window?.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .documentWindow
    }
}
