import AppKit

@MainActor
final class RepoSidebarGitHubMenuController: NSObject {
    private let coordinator: AppCoordinator

    private var menuContext: RepoSidebarMenuContext?

    private var lookupTask: Task<Void, Never>?
    private var lookupRepositoryID: UUID?
    private var pendingLookup: (context: RepoSidebarMenuContext, repositoryID: UUID)?
    private var lookupGeneration: UInt64 = 0
    private var browserOpenTask: Task<Void, Never>?
    private var browserOpenGeneration: UInt64 = 0

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
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

    deinit {
        lookupTask?.cancel()
        browserOpenTask?.cancel()
    }
    func updateMenuContext(_ context: RepoSidebarMenuContext) {
        guard context.menu != nil else { return }
        menuContext = context
    }

    func clearMenuContext(for menu: NSMenu) {
        guard menuContext?.menu === menu else { return }
        menuContext = nil
    }

    func addMenuItems(
        to menu: NSMenu,
        repositoryIDs: [UUID],
        context: RepoSidebarMenuContext
    ) {
        guard let contextMenu = context.menu,
              contextMenu === menu,
              !repositoryIDs.isEmpty,
              context.repositoryIDs == repositoryIDs else { return }
        updateMenuContext(context)
        let repositories = repositoryIDs.compactMap { repositoryID in
            coordinator.repositories.first(where: { $0.id == repositoryID })
        }
        guard repositories.count == repositoryIDs.count else { return }
        if repositoryIDs.count == 1, let repositoryID = repositoryIDs.first {
            if repositories[0].availability == .available,
               coordinator.githubURLs[repositoryID] != nil {
                addMenuItem("Open on GitHub", action: #selector(openRepositoryOnGitHub(_:)), id: repositoryID, to: menu)
            }
            if repositories[0].availability == .available {
                requestGitHubMenuLookup(context, repositoryID: repositoryID)
            }
            return
        }
        guard repositories.allSatisfy({ $0.availability == .available }) else { return }
        let item = NSMenuItem(
            title: "Open on GitHub",
            action: #selector(openRepositoriesOnGitHub(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = RepositorySelectionTarget(context: context)
        menu.addItem(item)
    }

    private func requestGitHubMenuLookup(_ context: RepoSidebarMenuContext, repositoryID: UUID) {
        guard let menu = context.menu else { return }
        guard lookupTask == nil else {
            if lookupRepositoryID != repositoryID {
                pendingLookup = (context: context, repositoryID: repositoryID)
            }
            return
        }
        lookupGeneration &+= 1
        let generation = lookupGeneration
        lookupRepositoryID = repositoryID
        let coordinator = coordinator
        lookupTask = Task { [weak self, weak menu, coordinator] in
            defer {
                if let self, self.lookupGeneration == generation {
                    self.lookupTask = nil
                    self.lookupRepositoryID = nil
                    if let pending = self.pendingLookup {
                        self.pendingLookup = nil
                        self.requestGitHubMenuLookup(pending.context, repositoryID: pending.repositoryID)
                    }
                }
            }
            let webURL = await coordinator.refreshGitHubURLWithRetry(for: repositoryID)
            guard !Task.isCancelled,
                  let self,
                  self.lookupGeneration == generation,
                  let menu,
                  self.isCurrentMenu(menu, repositoryID: repositoryID) else { return }
            self.setGitHubMenuItem(menu, repositoryID: repositoryID, available: webURL != nil)
        }
    }

    private func isCurrentMenu(_ menu: NSMenu, repositoryID: UUID) -> Bool {
        guard let context = menuContext, context.menu === menu else { return false }
        return context.repositoryIDs == [repositoryID]
    }

    private func isCurrentMenu(_ menu: NSMenu, repositoryIDs: [UUID]) -> Bool {
        guard let context = menuContext, context.menu === menu else { return false }
        return context.repositoryIDs == repositoryIDs
    }

    private func setGitHubMenuItem(_ menu: NSMenu, repositoryID: UUID, available: Bool) {
        let existingItems = menu.items.filter { $0.title == "Open on GitHub" }
        guard available else {
            existingItems.forEach(menu.removeItem)
            return
        }
        guard existingItems.isEmpty else { return }
        let item = NSMenuItem(
            title: "Open on GitHub",
            action: #selector(openRepositoryOnGitHub(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = repositoryID
        if let index = menu.items.firstIndex(where: { $0.title == "Refetch Upstream" }) {
            menu.insertItem(item, at: index)
        } else {
            menu.addItem(item)
        }
    }

    func cancelOperationsForTermination() -> [Task<Void, Never>] {
        let tasks = [lookupTask, browserOpenTask].compactMap(\.self)
        tasks.forEach { $0.cancel() }
        lookupTask = nil
        lookupRepositoryID = nil
        pendingLookup = nil
        browserOpenTask = nil
        return tasks
    }

    private func waitForGitHubMenuLookup(for repositoryID: UUID) async -> Bool {
        var waitedForRequestedRepository = false
        while !Task.isCancelled {
            guard let task = lookupTask else { return waitedForRequestedRepository }
            if lookupRepositoryID == repositoryID {
                waitedForRequestedRepository = true
            }
            await task.value
        }
        return waitedForRequestedRepository
    }

    @objc func openRepositoryOnGitHub(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let context = menuContext,
              let menu = context.menu,
              context.repositoryID == id,
              isCurrentMenu(menu, repositoryID: id),
              browserOpenTask == nil else { return }
        startOpeningRepositoriesOnGitHub(
            [id],
            context: context,
            usesMenuLookupFor: id,
            failureTitle: "Could Not Open on GitHub"
        )
    }

    @objc func openRepositoriesOnGitHub(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? RepositorySelectionTarget,
              let contextMenu = target.context.menu,
              isCurrentMenu(contextMenu, repositoryIDs: target.repositoryIDs),
              browserOpenTask == nil else { return }
        startOpeningRepositoriesOnGitHub(
            target.repositoryIDs,
            context: target.context,
            failureTitle: "Could Not Open All Repositories on GitHub"
        )
    }

    private func startOpeningRepositoriesOnGitHub(
        _ repositoryIDs: [UUID],
        context: RepoSidebarMenuContext,
        usesMenuLookupFor lookupRepositoryID: UUID? = nil,
        failureTitle: String
    ) {
        browserOpenGeneration &+= 1
        let generation = browserOpenGeneration
        let coordinator = coordinator
        browserOpenTask = Task { [weak self, coordinator, context, repositoryIDs] in
            defer {
                if let self, self.browserOpenGeneration == generation {
                    self.browserOpenTask = nil
                }
            }
            guard let self else { return }
            var failures: [String] = []
            for repositoryID in repositoryIDs {
                guard !Task.isCancelled,
                      self.browserOpenGeneration == generation,
                      let menu = context.menu,
                      self.isCurrentMenu(menu, repositoryIDs: repositoryIDs) else { return }

                let url: URL?
                if repositoryID == lookupRepositoryID {
                    let usedMenuLookup = await self.waitForGitHubMenuLookup(for: repositoryID)
                    guard !Task.isCancelled,
                          self.browserOpenGeneration == generation,
                          let menu = context.menu,
                          self.isCurrentMenu(menu, repositoryIDs: repositoryIDs) else { return }
                    if usedMenuLookup {
                        url = coordinator.githubURLs[repositoryID]
                    } else {
                        url = await coordinator.refreshGitHubURLWithRetry(for: repositoryID)
                    }
                } else if let cachedURL = coordinator.githubURLs[repositoryID] {
                    url = cachedURL
                } else {
                    url = await coordinator.refreshGitHubURLWithRetry(for: repositoryID)
                }

                guard !Task.isCancelled,
                      self.browserOpenGeneration == generation,
                      let menu = context.menu,
                      self.isCurrentMenu(menu, repositoryIDs: repositoryIDs) else { return }
                let failureMessage: String?
                if let url {
                    failureMessage = NSWorkspace.shared.open(url) ? nil : url.absoluteString
                } else {
                    failureMessage = "This repository does not have a GitHub remote."
                }
                if let failureMessage {
                    if repositoryIDs.count == 1 {
                        failures.append(failureMessage)
                    } else {
                        let repositoryName = coordinator.repositories.first {
                            $0.id == repositoryID
                        }?.displayName ?? "Selected repository"
                        failures.append("\(repositoryName): \(failureMessage)")
                    }
                }
            }
            guard !Task.isCancelled,
                  self.browserOpenGeneration == generation,
                  let menu = context.menu,
                  self.isCurrentMenu(menu, repositoryIDs: repositoryIDs),
                  !failures.isEmpty else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = failureTitle
            alert.informativeText = failures.joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            if let window = context.presentingWindow {
                await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    private func addMenuItem(_ title: String, action: Selector, id: UUID, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        menu.addItem(item)
    }
}
