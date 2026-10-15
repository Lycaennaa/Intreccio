import AppKit

@MainActor
final class MainWindowCommandRouter: NSObject, NSToolbarDelegate, NSMenuItemValidation {
    private enum ToolbarID {
        static let toolbar = NSToolbar.Identifier("MainToolbar")
        static let addSources = NSToolbarItem.Identifier("AddSources")
        static let downloads = NSToolbarItem.Identifier("Downloads")
        static let refreshActions = NSToolbarItem.Identifier("RefreshActions")
        static let pushToOrigin = NSToolbarItem.Identifier("PushToOrigin")
        static let viewMode = NSToolbarItem.Identifier("ViewMode")
        static let settings = NSToolbarItem.Identifier("Settings")
    }

    private let coordinator: AppCoordinator
    private let contentController: MainWindowContentController
    private let settingsPresenter: SettingsPanelPresenter
    private let downloadManager: RepositoryDownloadManager
    private weak var window: NSWindow?
    private var directoryOperationTask: Task<Void, Never>?
    private var isTerminating = false
    private let pushToOriginController: PushToOriginToolbarController

    init(
        coordinator: AppCoordinator,
        contentController: MainWindowContentController,
        settingsPresenter: SettingsPanelPresenter,
        window: NSWindow,
        downloadManager: RepositoryDownloadManager
    ) {
        self.coordinator = coordinator
        self.downloadManager = downloadManager
        self.contentController = contentController
        self.settingsPresenter = settingsPresenter
        self.window = window
        pushToOriginController = PushToOriginToolbarController(coordinator: coordinator, window: window)
    }

    func configureToolbar() {
        let toolbar = NSToolbar(identifier: ToolbarID.toolbar)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbarStyle = .unified
        window?.toolbar = toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            ToolbarID.addSources,
            ToolbarID.refreshActions,
            ToolbarID.pushToOrigin,
            ToolbarID.viewMode,
            ToolbarID.downloads,
            ToolbarID.settings
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.addSources:
            return menuToolbarItem(
                identifier: itemIdentifier,
                label: "Add",
                image: "plus",
                toolTip: "Add a root folder or repository",
                actions: [
                    ("Add Root Folder…", #selector(addFolder(_:))),
                    ("Add Repository…", #selector(addRepository(_:))),
                    ("Create Local Repository…", #selector(createLocalRepository(_:))),
                    ("Clone Repository…", #selector(cloneRepository(_:)))
                ]
            )
        case ToolbarID.downloads:
            return toolbarItem(identifier: itemIdentifier, label: "Downloads", image: "tray.and.arrow.down", action: #selector(showDownloads(_:)))
        case ToolbarID.refreshActions:
            return menuToolbarItem(
                identifier: itemIdentifier,
                label: "Refresh",
                image: "arrow.clockwise",
                toolTip: "Refresh repository or rescan all sources",
                actions: [
                    ("Refresh Repository", #selector(refresh(_:))),
                    ("Rescan All Sources", #selector(rescan(_:)))
                ]
            )
        case ToolbarID.pushToOrigin:
            return pushToOriginController.toolbarItem(identifier: itemIdentifier)
        case ToolbarID.settings:
            return toolbarItem(identifier: itemIdentifier, label: "Settings", image: "gearshape", action: #selector(showSettings(_:)))
        case ToolbarID.viewMode:
            return menuToolbarItem(
                identifier: itemIdentifier,
                label: "View",
                image: "list.bullet",
                toolTip: "Switch between Changes and History",
                actions: [
                    ("Changes", #selector(showChanges(_:))),
                    ("History", #selector(showHistory(_:)))
                ]
            )
        default:
            return nil
        }
    }

    func updatePushToOriginToolbar(_ snapshot: AppSnapshot) {
        pushToOriginController.update(snapshot)
    }

    @objc func addFolder(_ sender: Any?) {
        presentDirectoryPanel(prompt: "Add Root Folder") { [coordinator] url in
            await coordinator.addWatchRoot(url)
        }
    }

    @objc func addRepository(_ sender: Any?) {
        presentDirectoryPanel(prompt: "Add Repository") { [coordinator] url in
            await coordinator.addStandaloneRepository(url)
        }
    }
    @objc func cloneRepository(_ sender: Any?) {
        guard !isTerminating, let window else { return }
        RepositoryClonePanel.present(
            on: window,
            loadRepositories: { [coordinator] in try await coordinator.githubRepositories() },
            onClone: { [weak self] sourceURLs, destinationParent in
                guard let self, !self.isTerminating else { return }
                for sourceURL in sourceURLs {
                    self.downloadManager.startClone(
                        from: sourceURL,
                        into: destinationParent,
                        presentingWindow: window
                    )
                }
            }
        )
    }
    @objc func showDownloads(_ sender: Any?) {
        guard !isTerminating, let window else { return }
        downloadManager.present(from: window)
    }
    @objc func createLocalRepository(_ sender: Any?) {
        guard !isTerminating, directoryOperationTask == nil, let window else { return }
        LocalRepositoryCreationPanel.present(
            on: window,
            onCreate: { [weak self] name, parentDirectory, githubOptions in
                guard let self, !self.isTerminating else { return }
                self.startDirectoryOperation { [coordinator] in
                    _ = await coordinator.createLocalRepository(
                        named: name,
                        in: parentDirectory,
                        githubOptions: githubOptions
                    )
                }
            }
        )
    }

    @objc func rescan(_ sender: Any?) { coordinator.rescanAll() }
    @objc func refresh(_ sender: Any?) { coordinator.refreshSelectedRepository() }
    @objc func showSettings(_ sender: Any?) { settingsPresenter.present() }
    @objc func focusSearch(_ sender: Any?) { contentController.focusSearch() }
    @objc func focusDiffSearch(_ sender: Any?) { contentController.focusDiffSearch() }
    @objc func nextDiffHunk(_ sender: Any?) { contentController.nextDiffHunk() }
    @objc func previousDiffHunk(_ sender: Any?) { contentController.previousDiffHunk() }
    @objc func nextDiffFile(_ sender: Any?) { contentController.nextDiffFile() }
    @objc func previousDiffFile(_ sender: Any?) { contentController.previousDiffFile() }
    @objc func focusRepositories(_ sender: Any?) { contentController.focusRepositoryList() }

    @objc func showChanges(_ sender: Any?) {
        coordinator.setMode(.changes)
        contentController.focusChanges()
    }

    @objc func showHistory(_ sender: Any?) {
        coordinator.setMode(.history)
        contentController.focusHistory()
    }

    @objc func stageSelected(_ sender: Any?) { contentController.stageSelected(sender) }
    @objc func stageAll(_ sender: Any?) { contentController.stageAll(sender) }
    @objc func unstageSelected(_ sender: Any?) { contentController.unstageSelected(sender) }
    @objc func unstageAll(_ sender: Any?) { contentController.unstageAll(sender) }
    @objc func stashChanges(_ sender: Any?) { contentController.stashChanges(sender) }
    @objc func restoreLatestStash(_ sender: Any?) { contentController.restoreLatestStash(sender) }
    @objc func commit(_ sender: Any?) { contentController.commit(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(refresh(_:)):
            return coordinator.selectedRepositoryIsAvailable
        case #selector(stageSelected(_:)):
            return coordinator.state.uiState.mode == .changes && contentController.canStageSelected
        case #selector(stageAll(_:)):
            return coordinator.state.uiState.mode == .changes && contentController.canStageAll
        case #selector(unstageSelected(_:)):
            return coordinator.state.uiState.mode == .changes && contentController.canUnstageSelected
        case #selector(unstageAll(_:)):
            return coordinator.state.uiState.mode == .changes && contentController.canUnstageAll
        case #selector(stashChanges(_:)):
            return coordinator.state.uiState.mode == .changes && contentController.canStash
        case #selector(restoreLatestStash(_:)):
            return coordinator.state.uiState.mode == .changes && contentController.canRestoreStash
        case #selector(commit(_:)):
            return coordinator.state.uiState.mode == .changes && contentController.canCommit
        case #selector(focusDiffSearch(_:)):
            return contentController.canSearchDiff
        case #selector(nextDiffHunk(_:)), #selector(previousDiffHunk(_:)):
            return contentController.canNavigateDiffHunks
        case #selector(nextDiffFile(_:)), #selector(previousDiffFile(_:)):
            return contentController.canNavigateDiffFiles
        case #selector(showChanges(_:)):
            menuItem.state = coordinator.state.uiState.mode == .changes ? .on : .off
            return true
        case #selector(showHistory(_:)):
            menuItem.state = coordinator.state.uiState.mode == .history ? .on : .off
            return true
        default:
            return true
        }
    }

    func cancelDirectoryOperationForTermination() async -> Task<Void, Never>? {
        isTerminating = true
        directoryOperationTask?.cancel()
        let downloadTask = downloadManager.cancelForTermination()
        let pushPreparationTask = pushToOriginController.prepareForTermination()
        await pushPreparationTask?.value
        let tasks = [directoryOperationTask, downloadTask].compactMap(\.self)
        switch tasks.count {
        case 0:
            return nil
        case 1:
            return tasks[0]
        default:
            return Task {
                for task in tasks {
                    await task.value
                }
            }
        }
    }

    func finishTerminationWait() {
        directoryOperationTask = nil
        downloadManager.finishTerminationWait()
    }

    func resumeAfterFailedTermination() {
        isTerminating = false
        pushToOriginController.resumeAfterFailedTermination()
    }

    private func menuToolbarItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        image: String,
        toolTip: String,
        actions: [(String, Selector)]
    ) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: label)
        item.isNavigational = true
        item.showsIndicator = true
        let menu = NSMenu(title: label)
        for (title, action) in actions {
            let menuItem = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            menuItem.target = self
        }
        item.menu = menu
        return item
    }

    private func toolbarItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        image: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: label)
        item.isNavigational = true
        item.target = self
        item.action = action
        return item
    }

    private func startDirectoryOperation(_ operation: @escaping @MainActor () async -> Void) {
        guard !isTerminating, directoryOperationTask == nil else { return }
        directoryOperationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            guard let self, !Task.isCancelled else { return }
            self.directoryOperationTask = nil
        }
    }

    private func presentDirectoryPanel(prompt: String, operation: @escaping @MainActor (URL) async -> Void) {
        guard !isTerminating, directoryOperationTask == nil, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.isTerminating, response == .OK, let url = panel.url else { return }
            self.startDirectoryOperation { await operation(url) }
        }
    }
}
