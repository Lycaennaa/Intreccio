import AppKit

@MainActor
final class RepoSidebarJustMenuImplementation: NSObject {
    private let coordinator: AppCoordinator
    private let applicationController: RepoSidebarApplicationController
    private let singleImplementation: RepoSidebarJustMenuSingleImplementation
    private var menuContext: RepoSidebarMenuContext?
    private var contextGeneration: UInt64 = 0
    private var discoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var recipeActionTasks: [UUID: Task<Void, Never>] = [:]
    private var isTerminating = false

    init(
        coordinator: AppCoordinator,
        applicationController: RepoSidebarApplicationController
    ) {
        self.coordinator = coordinator
        self.applicationController = applicationController
        singleImplementation = RepoSidebarJustMenuSingleImplementation(
            coordinator: coordinator,
            applicationController: applicationController
        )
        super.init()
    }

    deinit {
        discoveryTasks.values.forEach { $0.cancel() }
        recipeActionTasks.values.forEach { $0.cancel() }
    }

    func updateMenuContext(_ context: RepoSidebarMenuContext) {
        contextGeneration &+= 1
        cancelActiveDiscoveryTasks()
        cancelActiveRecipeTasks()
        menuContext = context
        singleImplementation.updateMenuContext(context)
    }

    func clearMenuContext(for menu: NSMenu) {
        guard menuContext?.menu === menu else { return }
        contextGeneration &+= 1
        cancelActiveDiscoveryTasks()
        cancelActiveRecipeTasks()
        menuContext = nil
        singleImplementation.clearMenuContext(for: menu)
    }

    func waitForPendingDiscovery() async {
        for task in Array(discoveryTasks.values) {
            await task.value
        }
    }

    func cancelOperationsForTermination() -> [Task<Void, Never>] {
        isTerminating = true
        let tasks = Array(discoveryTasks.values)
            + Array(recipeActionTasks.values)
            + singleImplementation.cancelPendingRecipeActions()
        cancelActiveDiscoveryTasks()
        cancelActiveRecipeTasks()
        tasks.forEach { $0.cancel() }
        return tasks
    }

    func resumeOperationsAfterFailedTermination() {
        isTerminating = false
    }

    private func cancelActiveDiscoveryTasks() {
        discoveryTasks.values.forEach { $0.cancel() }
        discoveryTasks.removeAll()
    }

    private func cancelActiveRecipeTasks() {
        recipeActionTasks.values.forEach { $0.cancel() }
        recipeActionTasks.removeAll()
    }

    private func startDiscovery(
        for repositories: [RepoDescriptor],
        context: RepoSidebarMenuContext,
        menu: NSMenu,
        apply: @escaping ([JustfileDiscovery]) -> Void
    ) {
        guard !isTerminating else { return }
        let operationID = UUID()
        let generation = contextGeneration
        let repositoryURLs = repositories.map(\.canonicalURL)
        let task = Task { [weak self, weak menu] in
            defer { self?.discoveryTasks[operationID] = nil }
            let discoveries = await JustfileService.discoveriesAsync(in: repositoryURLs)
            guard !Task.isCancelled, discoveries.count == repositoryURLs.count,
                  let self,
                  let menu,
                  self.isCurrent(context, generation: generation),
                  self.repositoriesAreCurrent(repositories) else { return }
            apply(discoveries)
            menu.update()
        }
        discoveryTasks[operationID] = task
    }

    private func repositoriesAreCurrent(_ repositories: [RepoDescriptor]) -> Bool {
        repositories.allSatisfy { captured in
            coordinator.repositories.contains(where: {
                $0.id == captured.id
                    && $0.availability == .available
                    && $0.canonicalURL.standardizedFileURL == captured.canonicalURL.standardizedFileURL
            })
        }
    }

    func addMenuItems(
        to menu: NSMenu,
        repositoryID: UUID,
        context: RepoSidebarMenuContext,
        owner: RepoSidebarJustMenuController
    ) {
        guard let contextMenu = context.menu,
              contextMenu === menu,
              context.repositoryIDs.contains(repositoryID),
              let repository = coordinator.repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available else { return }
        updateMenuContext(context)
        let submenu = singleImplementation.makeLoadingRepositoryJustMenu(owner: owner)
        let justItem = NSMenuItem(title: "Just", action: nil, keyEquivalent: "")
        justItem.submenu = submenu
        menu.addItem(justItem)
        startDiscovery(for: [repository], context: context, menu: submenu) { [weak self, weak submenu] discoveries in
            guard let self, let submenu, let discovery = discoveries.first else { return }
            self.singleImplementation.populateRepositoryJustMenu(
                submenu,
                for: repository,
                context: context,
                discovery: discovery
            )
        }
    }
    func runRecipe(_ sender: NSMenuItem) {
        singleImplementation.runRecipe(sender)
    }

    func createJustfile(_ sender: NSMenuItem) {
        singleImplementation.createJustfile(sender)
    }

    func showJustInfo(_ sender: NSMenuItem) {
        singleImplementation.showJustInfo(sender)
    }
    final class CreateAllTarget: NSObject {
        let context: RepoSidebarMenuContext

        var repositoryIDs: [UUID] {
            context.repositoryIDs
        }

        init(context: RepoSidebarMenuContext) {
            self.context = context
        }
    }
    final class SelectedRecipeTarget: NSObject {
        struct RepositoryRecipe {
            let repositoryID: UUID
            let justfile: JustfileDefinition
        }

        let recipeName: String
        let repositories: [RepositoryRecipe]
        let context: RepoSidebarMenuContext

        var repositoryIDs: [UUID] {
            context.repositoryIDs
        }

        init(
            recipeName: String,
            repositories: [RepositoryRecipe],
            context: RepoSidebarMenuContext
        ) {
            self.recipeName = recipeName
            self.repositories = repositories
            self.context = context
        }
    }
    func addMenuItems(
        to menu: NSMenu,
        repositoryIDs: [UUID],
        context: RepoSidebarMenuContext,
        owner: RepoSidebarJustMenuController
    ) {
        guard let contextMenu = context.menu,
              contextMenu === menu,
              !repositoryIDs.isEmpty,
              context.repositoryIDs == repositoryIDs else { return }
        if repositoryIDs.count == 1, let repositoryID = repositoryIDs.first {
            addMenuItems(to: menu, repositoryID: repositoryID, context: context, owner: owner)
            return
        }
        updateMenuContext(context)
        let availableRepositories = repositoryIDs.compactMap { repositoryID in
            coordinator.repositories.first {
                $0.id == repositoryID && $0.availability == .available
            }
        }
        guard !availableRepositories.isEmpty else { return }

        let justMenu = NSMenu(title: "Just")
        let loadingItem = NSMenuItem(title: "Loading recipes…", action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false
        justMenu.addItem(loadingItem)
        let justItem = NSMenuItem(title: "Just", action: nil, keyEquivalent: "")
        justItem.submenu = justMenu
        menu.addItem(justItem)

        startDiscovery(
            for: availableRepositories,
            context: context,
            menu: justMenu
        ) { [weak self, weak owner, weak justMenu] discoveries in
            guard let self, let owner, let justMenu else { return }
            self.populateJustMenu(
                justMenu,
                repositories: availableRepositories,
                discoveries: discoveries,
                repositoryIDs: repositoryIDs,
                context: context,
                owner: owner
            )
        }
    }

    private func populateJustMenu(
        _ justMenu: NSMenu,
        repositories: [RepoDescriptor],
        discoveries: [JustfileDiscovery],
        repositoryIDs: [UUID],
        context: RepoSidebarMenuContext,
        owner: RepoSidebarJustMenuController
    ) {
        justMenu.removeAllItems()
        let repositoryDiscoveries = zip(repositories, discoveries).map { pair in
            (repository: pair.0, discovery: pair.1)
        }
        let repositoryJustfiles = repositoryDiscoveries.compactMap {
            entry -> (repositoryID: UUID, justfile: JustfileDefinition)? in
            guard case .definition(let justfile) = entry.discovery else { return nil }
            return (repositoryID: entry.repository.id, justfile: justfile)
        }
        let commonRecipes = repositoryJustfiles.count == repositoryIDs.count
            ? JustfileService.commonRecipes(in: repositoryJustfiles.map(\.justfile))
            : []
        let canCreateInAll = repositories.count == repositoryIDs.count
            && repositoryDiscoveries.allSatisfy {
                if case .noJustfile = $0.discovery { return true }
                return false
            }
        let justInstalled = repositoryDiscoveries.allSatisfy {
            if case .noJustfile(let isInstalled) = $0.discovery { return isInstalled }
            return false
        }
        if canCreateInAll {
            addCreateAllItems(to: justMenu, context: context, owner: owner, justInstalled: justInstalled)
        } else if !commonRecipes.isEmpty {
            let selectedRepositories = repositoryJustfiles.map {
                SelectedRecipeTarget.RepositoryRecipe(
                    repositoryID: $0.repositoryID,
                    justfile: $0.justfile
                )
            }
            for recipe in commonRecipes {
                let item = NSMenuItem(
                    title: recipe.name,
                    action: #selector(runSelectedRecipe(_:)),
                    keyEquivalent: ""
                )
                item.target = owner
                item.representedObject = SelectedRecipeTarget(
                    recipeName: recipe.name,
                    repositories: selectedRepositories,
                    context: context
                )
                justMenu.addItem(item)
            }
        } else {
            for entry in repositoryDiscoveries {
                let repositoryMenu = singleImplementation.makeRepositoryJustMenu(
                    for: entry.repository,
                    context: context,
                    discovery: entry.discovery,
                    owner: owner
                )
                let repositoryItem = NSMenuItem(
                    title: entry.repository.displayName,
                    action: nil,
                    keyEquivalent: ""
                )
                repositoryItem.submenu = repositoryMenu
                justMenu.addItem(repositoryItem)
            }
        }
    }
    private func addCreateAllItems(
        to submenu: NSMenu,
        context: RepoSidebarMenuContext,
        owner: RepoSidebarJustMenuController,
        justInstalled: Bool
    ) {
        let target = CreateAllTarget(context: context)
        let createItem = NSMenuItem(
            title: "Create in All",
            action: #selector(createJustfiles(_:)),
            keyEquivalent: ""
        )
        createItem.target = owner
        createItem.representedObject = target
        submenu.addItem(createItem)

        if !justInstalled {
            let unavailableItem = NSMenuItem(title: "just is not installed", action: nil, keyEquivalent: "")
            unavailableItem.isEnabled = false
            submenu.addItem(unavailableItem)
        }

        let infoItem = NSMenuItem(
            title: "What Is This?",
            action: #selector(showJustInfoForSelection(_:)),
            keyEquivalent: ""
        )
        infoItem.target = owner
        infoItem.representedObject = target
        submenu.addItem(infoItem)
    }
    @objc func runSelectedRecipe(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SelectedRecipeTarget,
              !isTerminating,
              isCurrentContext(target.context, repositoryIDs: target.repositoryIDs) else { return }
        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.recipeActionTasks[operationID] = nil }
            var failures: [String] = []
            for selectedRepository in target.repositories {
                guard !Task.isCancelled,
                      self.isCurrentContext(target.context, repositoryIDs: target.repositoryIDs) else { return }
                let failure = await self.singleImplementation.executeRecipe(
                    repositoryID: selectedRepository.repositoryID,
                    recipeName: target.recipeName,
                    justfile: selectedRepository.justfile,
                    context: target.context
                )
                guard !Task.isCancelled,
                      self.isCurrentContext(target.context, repositoryIDs: target.repositoryIDs) else { return }
                guard let failure else { continue }
                let repositoryName = self.coordinator.repositories.first {
                    $0.id == selectedRepository.repositoryID
                }?.displayName ?? "Selected repository"
                failures.append("\(repositoryName): \(failure)")
            }
            guard !failures.isEmpty,
                  self.isCurrentContext(target.context, repositoryIDs: target.repositoryIDs) else { return }
            self.singleImplementation.presentError(
                for: target.context,
                messageText: "Could Not Run Selected Just Recipe",
                description: failures.joined(separator: "\n")
            )
        }
        recipeActionTasks[operationID] = task
    }
    @objc func createJustfiles(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CreateAllTarget,
              isCurrentContext(target.context, repositoryIDs: target.repositoryIDs) else { return }

        var createdRepositories: [String] = []
        var failures: [String] = []
        for repositoryID in target.repositoryIDs {
            guard let repository = coordinator.repositories.first(where: { $0.id == repositoryID }) else {
                failures.append("Selected repository: The repository is no longer available.")
                continue
            }
            guard repository.availability == .available,
                  applicationController.isCurrentRepository(repository) else {
                failures.append("\(repository.displayName): The repository is no longer available.")
                continue
            }
            guard !JustfileService.hasJustfile(in: repository.canonicalURL) else {
                failures.append("\(repository.displayName): A justfile already exists.")
                continue
            }
            do {
                _ = try JustfileService.createExample(in: repository.canonicalURL)
                createdRepositories.append(repository.displayName)
            } catch {
                failures.append("\(repository.displayName): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            singleImplementation.presentMessage(
                for: target.context,
                messageText: "Justfiles Created",
                informativeText: "Created justfiles in \(createdRepositories.count) repositories."
            )
        } else {
            let createdDescription = createdRepositories.isEmpty
                ? ""
                : "Created in: \(createdRepositories.joined(separator: ", "))\n\n"
            singleImplementation.presentError(
                for: target.context,
                messageText: createdRepositories.isEmpty ? "Could Not Create Justfiles" : "Some Justfiles Created",
                description: createdDescription + failures.joined(separator: "\n")
            )
        }
    }
    @objc func showJustInfoForSelection(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CreateAllTarget,
              isCurrentContext(target.context, repositoryIDs: target.repositoryIDs) else { return }
        singleImplementation.presentJustInfo(for: target.context)
    }
    private func isCurrentContext(
        _ context: RepoSidebarMenuContext,
        repositoryIDs: [UUID]
    ) -> Bool {
        guard let menu = context.menu else { return false }
        return menuContext?.menu === menu && menuContext?.repositoryIDs == repositoryIDs
    }
    private func isCurrent(_ context: RepoSidebarMenuContext, generation: UInt64) -> Bool {
        !Task.isCancelled
            && contextGeneration == generation
            && isCurrentContext(context, repositoryIDs: context.repositoryIDs)
    }

}
