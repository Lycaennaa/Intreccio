import AppKit

@MainActor
final class RepoSidebarMenuController: NSObject {
    final class FolderExclusionTarget: NSObject {
        let sourceID: UUID
        let relativePath: String

        init(sourceID: UUID, relativePath: String) {
            self.sourceID = sourceID
            self.relativePath = relativePath
        }
    }
    final class RepositorySelectionTarget: NSObject {
        let context: RepoSidebarMenuContext

        var repositoryIDs: [UUID] {
            context.repositoryIDs
        }

        init(context: RepoSidebarMenuContext) {
            self.context = context
        }
    }

    private let coordinator: AppCoordinator
    private let githubMenuController: RepoSidebarGitHubMenuController
    private let applicationController: RepoSidebarApplicationController
    private let aiToolController: RepoSidebarAIController
    private let justMenuController: RepoSidebarJustMenuController
    let quickOpenController: RepoSidebarQuickOpenController

    private var menuContext: RepoSidebarMenuContext?
    private var operationTasks: [UUID: Task<Void, Never>] = [:]
    private var isTerminating = false

    init(
        coordinator: AppCoordinator,
        githubMenuController: RepoSidebarGitHubMenuController,
        applicationController: RepoSidebarApplicationController
    ) {
        self.coordinator = coordinator
        self.githubMenuController = githubMenuController
        self.applicationController = applicationController
        self.aiToolController = RepoSidebarAIController(
            coordinator: coordinator,
            directoryProvider: applicationController
        )
        self.quickOpenController = RepoSidebarQuickOpenController(coordinator: coordinator)

        self.justMenuController = RepoSidebarJustMenuController(
            coordinator: coordinator,
            applicationController: applicationController
        )
        super.init()
    }

    deinit {
        operationTasks.values.forEach { $0.cancel() }
    }

    func clearMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if menuContext?.menu === menu {
            menuContext = nil
        }
        githubMenuController.clearMenuContext(for: menu)
        applicationController.clearMenuContext(for: menu)
        aiToolController.clearMenuContext(for: menu)
        quickOpenController.clearMenuContext(for: menu)

        justMenuController.clearMenuContext(for: menu)
    }

    func populateMenu(with context: RepoSidebarMenuContext) {
        guard let menu = context.menu else { return }
        menu.removeAllItems()
        setMenuContext(context)
        switch context.node.kind {
        case .root(let sourceID):
            addMenuItem("Manage Exclusions…", action: #selector(manageExclusions(_:)), id: sourceID, to: menu)
            addMenuItem("Re-authorize…", action: #selector(reauthorize(_:)), id: sourceID, to: menu)
            menu.addItem(.separator())
            addMenuItem("Remove Repo…", action: #selector(removeSource(_:)), id: sourceID, to: menu)
        case .folder(let sourceID, let relativePath):
            addFolderMenuItem(
                "Ignore Folder and Contents",
                action: #selector(excludeFolder(_:)),
                sourceID: sourceID,
                relativePath: relativePath,
                to: menu
            )
        case .pinnedSection, .standaloneSection:
            break
        case .repository:
            populateRepositoryMenu(context)
        }
    }

    func populateRepositoryMenu(_ context: RepoSidebarMenuContext) {
        guard let menu = context.menu, !context.repositoryIDs.isEmpty else { return }
        let repositories = context.repositoryIDs.compactMap { repositoryID in
            coordinator.repositories.first(where: { $0.id == repositoryID })
        }
        guard repositories.count == context.repositoryIDs.count else { return }
        setMenuContext(context)
        let target = RepositorySelectionTarget(context: context)
        addRepositoryActionMenus(
            to: menu,
            context: context,
            repositories: repositories,
            target: target
        )
        menu.addItem(.separator())
        if repositories.count == 1, let repository = repositories.first {
            addSingleRepositoryStateItems(to: menu, repository: repository)
        } else {
            addMultipleRepositoryStateItems(to: menu, repositories: repositories, target: target)
        }
    }
    private func addRepositoryActionMenus(
        to menu: NSMenu,
        context: RepoSidebarMenuContext,
        repositories: [RepoDescriptor],
        target: RepositorySelectionTarget
    ) {
        aiToolController.addMenu(to: menu, context: context)

        applicationController.addOpenApplicationMenu(
            to: menu,
            title: "Open in Regular App",
            repositoryIDs: context.repositoryIDs,
            parentDirectory: false,
            context: context
        )
        applicationController.addOpenApplicationMenu(
            to: menu,
            title: "Open Parent in Regular App",
            repositoryIDs: context.repositoryIDs,
            parentDirectory: true,
            context: context
        )
        githubMenuController.addMenuItems(
            to: menu,
            repositoryIDs: context.repositoryIDs,
            context: context
        )

        if repositories.count == 1, let repository = repositories.first {
            if repository.availability == .available {
                addMenuItem("Refetch Upstream", action: #selector(refetchUpstream(_:)), id: repository.id, to: menu)
            }
            addMenuItem("Copy Path", action: #selector(copyRepositoryPath(_:)), id: repository.id, to: menu)
        } else {
            if repositories.contains(where: { $0.availability == .available }) {
                addSelectionMenuItem(
                    "Refetch Upstream",
                    action: #selector(refetchSelectedRepositories(_:)),
                    target: target,
                    to: menu
                )
            }
            addSelectionMenuItem(
                "Copy Paths",
                action: #selector(copySelectedRepositoryPaths(_:)),
                target: target,
                to: menu
            )
        }
        quickOpenController.addOpenFileMenuItem(
            to: menu,
            repositoryIDs: context.repositoryIDs,
            context: context
        )
        justMenuController.addMenuItems(
            to: menu,
            repositoryIDs: context.repositoryIDs,
            context: context
        )
    }

    private func addSingleRepositoryStateItems(
        to menu: NSMenu,
        repository: RepoDescriptor
    ) {
        let repositoryID = repository.id
        let isPinned = coordinator.state.uiState.pinnedRepositoryIDs.contains(repositoryID)
        addMenuItem(
            isPinned ? "Unpin" : "Pin",
            action: #selector(setRepositoryPinned(_:)),
            id: repositoryID,
            to: menu
        )
        if repository.availability == .available, repository.hasSubmodules {
            let item = NSMenuItem(
                title: "Show All Initialized Submodules",
                action: #selector(toggleShowCleanInitializedSubmodules(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = repositoryID
            item.state = coordinator.state.uiState.showCleanSubmoduleRepositoryIDs.contains(repositoryID)
                ? .on
                : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        switch repository.source {
        case .watchRoot(let sourceID, _, _):
            addMenuItem("Remove Repo…", action: #selector(excludeRepository(_:)), id: repositoryID, to: menu)
            if case .unavailable = repository.availability {
                menu.addItem(.separator())
                addMenuItem("Re-authorize Folder…", action: #selector(reauthorize(_:)), id: sourceID, to: menu)
            }
        case .standalone(let sourceID):
            guard repository.submoduleParentRepositoryID == nil else { return }
            addMenuItem("Re-authorize…", action: #selector(reauthorize(_:)), id: sourceID, to: menu)
            addMenuItem("Remove Repo…", action: #selector(removeSource(_:)), id: sourceID, to: menu)
        }
    }

    private func addMultipleRepositoryStateItems(
        to menu: NSMenu,
        repositories: [RepoDescriptor],
        target: RepositorySelectionTarget
    ) {
        let allPinned = repositories.allSatisfy {
            coordinator.state.uiState.pinnedRepositoryIDs.contains($0.id)
        }
        addSelectionMenuItem(
            allPinned ? "Unpin" : "Pin",
            action: #selector(setSelectedRepositoriesPinned(_:)),
            target: target,
            to: menu
        )

        let allWatchRoot = repositories.allSatisfy {
            if case .watchRoot = $0.source { return true }
            return false
        }
        let allStandalone = repositories.allSatisfy {
            if case .standalone = $0.source { return true }
            return false
        }
        if allStandalone,
           repositories.contains(where: { $0.submoduleParentRepositoryID != nil }) {
            return
        }
        guard allWatchRoot || allStandalone else { return }
        menu.addItem(.separator())
        let title: String
        let action: Selector
        if allWatchRoot {
            let allUnavailable = repositories.allSatisfy {
                if case .unavailable = $0.availability { return true }
                return false
            }
            title = allUnavailable ? "Remove Selected Repositories…" : "Exclude Selected"
            action = #selector(excludeSelectedRepositories(_:))
        } else {
            title = "Remove Selected Repositories…"
            action = #selector(removeSelectedRepositories(_:))
        }
        addSelectionMenuItem(title, action: action, target: target, to: menu)
    }

    private func setMenuContext(_ context: RepoSidebarMenuContext) {
        menuContext = context
        githubMenuController.updateMenuContext(context)
        applicationController.updateMenuContext(context)
        aiToolController.updateMenuContext(context)
        quickOpenController.updateMenuContext(context)
        justMenuController.updateMenuContext(context)
    }

    func waitForJustMenuDiscovery() async {
        await justMenuController.waitForPendingDiscovery()
    }
    func cancelOperationsForTermination() -> [Task<Void, Never>] {
        isTerminating = true
        let tasks = Array(operationTasks.values)
            + aiToolController.cancelOperationsForTermination()
            + justMenuController.cancelOperationsForTermination()
        tasks.forEach { $0.cancel() }
        operationTasks.removeAll()
        return tasks
    }

    func resumeOperationsAfterFailedTermination() {
        isTerminating = false
        aiToolController.resumeOperationsAfterFailedTermination()
        justMenuController.resumeOperationsAfterFailedTermination()
    }

    @objc func refetchUpstream(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator.refetchUpstream(for: id)
    }

    @objc func copyRepositoryPath(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let repository = coordinator.repositories.first(where: { $0.id == id }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(repository.canonicalURL.path, forType: .string)
    }

    @objc func setRepositoryPinned(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator.setRepositoryPinned(id, pinned: !coordinator.state.uiState.pinnedRepositoryIDs.contains(id))
    }
    @objc func toggleShowCleanInitializedSubmodules(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let repository = coordinator.repositories.first(where: { $0.id == id }),
              repository.hasSubmodules else { return }
        let enabled = !coordinator.state.uiState.showCleanSubmoduleRepositoryIDs.contains(id)
        coordinator.setShowCleanInitializedSubmodules(enabled, for: id)
    }
    @objc func refetchSelectedRepositories(_ sender: NSMenuItem) {
        guard let target = selectionTarget(from: sender) else { return }
        let repositoryIDs = target.repositoryIDs.filter { repositoryID in
            coordinator.repositories.contains {
                $0.id == repositoryID && $0.availability == .available
            }
        }
        coordinator.refetchUpstream(for: repositoryIDs)
    }

    @objc func copySelectedRepositoryPaths(_ sender: NSMenuItem) {
        guard let target = selectionTarget(from: sender) else { return }
        let paths = target.repositoryIDs.compactMap { repositoryID in
            coordinator.repositories.first(where: { $0.id == repositoryID })?.canonicalURL.path
        }
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func setSelectedRepositoriesPinned(_ sender: NSMenuItem) {
        guard let target = selectionTarget(from: sender) else { return }
        let shouldPin = target.repositoryIDs.contains {
            !coordinator.state.uiState.pinnedRepositoryIDs.contains($0)
        }
        coordinator.setRepositoriesPinned(target.repositoryIDs, pinned: shouldPin)
    }

    @objc func excludeSelectedRepositories(_ sender: NSMenuItem) {
        guard let target = selectionTarget(from: sender) else { return }
        runOperation { [coordinator, repositoryIDs = target.repositoryIDs] in
            for repositoryID in repositoryIDs {
                guard !Task.isCancelled else { return }
                await coordinator.excludeRepository(repositoryID)
            }
        }
    }

    @objc func removeSelectedRepositories(_ sender: NSMenuItem) {
        guard let target = selectionTarget(from: sender),
              let window = target.context.presentingWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Remove selected repositories?"
        alert.informativeText = "Only app state will be removed. Files on disk will not be changed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, coordinator, repositoryIDs = target.repositoryIDs] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.runOperation { [coordinator] in
                for repositoryID in repositoryIDs {
                    guard !Task.isCancelled,
                          let repository = coordinator.repositories.first(where: { $0.id == repositoryID }),
                          repository.submoduleParentRepositoryID == nil,
                          case .standalone(let sourceID) = repository.source else { continue }
                    await coordinator.removeSource(sourceID)
                }
            }
        }
    }

    private func selectionTarget(from sender: NSMenuItem) -> RepositorySelectionTarget? {
        guard let target = sender.representedObject as? RepositorySelectionTarget,
              let activeMenu = menuContext?.menu,
              activeMenu === target.context.menu,
              menuContext?.repositoryIDs == target.repositoryIDs else { return nil }
        return target
    }

    @objc func excludeRepository(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        runOperation { [coordinator] in await coordinator.excludeRepository(id) }
    }

    @objc func excludeFolder(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FolderExclusionTarget else { return }
        runOperation { [coordinator] in
            await coordinator.excludeFolder(sourceID: target.sourceID, path: target.relativePath)
        }
    }

    @objc func removeSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let window = menuContext?.presentingWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Remove this source?"
        alert.informativeText = "Only app state will be removed. Files on disk will not be changed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.runOperation { [coordinator] in await coordinator.removeSource(id) }
        }
    }

    @objc func manageExclusions(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let root = coordinator.state.watchRoots.first(where: { $0.id == id }),
              let window = menuContext?.presentingWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Manage Exclusions"
        guard !root.exclusions.isEmpty else {
            alert.informativeText = "This folder has no excluded repositories."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
            return
        }
        alert.informativeText = "Choose a path to include again."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        popup.addItems(withTitles: root.exclusions)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let path = popup.selectedItem?.title,
                  let self else { return }
            self.runOperation { [coordinator] in await coordinator.restoreExclusion(sourceID: id, path: path) }
        }
    }

    @objc func reauthorize(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let window = menuContext?.presentingWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Authorize"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.runOperation { [coordinator] in await coordinator.reauthorizeSource(id, with: url) }
        }
    }

    private func runOperation(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        guard !isTerminating else { return }
        let operationID = UUID()
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            guard let self, !Task.isCancelled else { return }
            self.operationTasks[operationID] = nil
        }
        operationTasks[operationID] = task
    }

    private func addMenuItem(_ title: String, action: Selector, id: UUID, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        menu.addItem(item)
    }
    private func addSelectionMenuItem(
        _ title: String,
        action: Selector,
        target: RepositorySelectionTarget,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = target
        menu.addItem(item)
    }

    private func addFolderMenuItem(
        _ title: String,
        action: Selector,
        sourceID: UUID,
        relativePath: String,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = FolderExclusionTarget(sourceID: sourceID, relativePath: relativePath)
        menu.addItem(item)
    }
}
