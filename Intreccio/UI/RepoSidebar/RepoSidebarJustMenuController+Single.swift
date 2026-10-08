import AppKit

@MainActor
final class RepoSidebarJustMenuSingleImplementation: NSObject {
    final class RecipeTarget: NSObject {
        let repositoryID: UUID
        let recipeName: String
        let justfile: JustfileDefinition
        let context: RepoSidebarMenuContext

        init(
            repositoryID: UUID,
            recipeName: String,
            justfile: JustfileDefinition,
            context: RepoSidebarMenuContext
        ) {
            self.repositoryID = repositoryID
            self.recipeName = recipeName
            self.justfile = justfile
            self.context = context
        }
    }
    final class CreateTarget: NSObject {
        let repositoryID: UUID
        let context: RepoSidebarMenuContext

        init(repositoryID: UUID, context: RepoSidebarMenuContext) {
            self.repositoryID = repositoryID
            self.context = context
        }
    }
    static let justWebsiteURLString = "https://github.com/casey/just"

    private let coordinator: AppCoordinator
    private let applicationController: RepoSidebarApplicationController
    private var menuContext: RepoSidebarMenuContext?
    private var recipeTasks: [UUID: Task<Void, Never>] = [:]
    private weak var actionTarget: RepoSidebarJustMenuController?
    private var menuTarget: AnyObject {
        actionTarget ?? self
    }

    init(
        coordinator: AppCoordinator,
        applicationController: RepoSidebarApplicationController
    ) {
        self.coordinator = coordinator
        self.applicationController = applicationController
        super.init()
    }

    deinit {
        recipeTasks.values.forEach { $0.cancel() }
    }

    func updateMenuContext(_ context: RepoSidebarMenuContext) {
        cancelPendingRecipeActions()
        menuContext = context
    }

    func clearMenuContext(for menu: NSMenu) {
        guard menuContext?.menu === menu else { return }
        cancelPendingRecipeActions()
        menuContext = nil
    }

    @discardableResult
    func cancelPendingRecipeActions() -> [Task<Void, Never>] {
        let tasks = Array(recipeTasks.values)
        recipeTasks.removeAll()
        tasks.forEach { $0.cancel() }
        return tasks
    }

    func makeLoadingRepositoryJustMenu(owner: RepoSidebarJustMenuController) -> NSMenu {
        actionTarget = owner
        let submenu = NSMenu(title: "Just")
        addLoadingRecipesItem(to: submenu)
        return submenu
    }

    func makeRepositoryJustMenu(
        for repository: RepoDescriptor,
        context: RepoSidebarMenuContext,
        discovery: JustfileDiscovery
    ) -> NSMenu {
        let submenu = NSMenu(title: "Just")
        populateRepositoryJustMenu(
            submenu,
            for: repository,
            context: context,
            discovery: discovery
        )
        return submenu
    }

    func makeRepositoryJustMenu(
        for repository: RepoDescriptor,
        context: RepoSidebarMenuContext,
        discovery: JustfileDiscovery,
        owner: RepoSidebarJustMenuController
    ) -> NSMenu {
        actionTarget = owner
        return makeRepositoryJustMenu(for: repository, context: context, discovery: discovery)
    }

    func populateRepositoryJustMenu(
        _ submenu: NSMenu,
        for repository: RepoDescriptor,
        context: RepoSidebarMenuContext,
        discovery: JustfileDiscovery
    ) {
        submenu.removeAllItems()
        switch discovery {
        case .definition(let justfile):
            addRecipeItems(justfile, to: submenu, repositoryID: repository.id, context: context)
        case .noJustfile(let justInstalled):
            addCreateItems(
                to: submenu,
                repositoryID: repository.id,
                context: context,
                justInstalled: justInstalled
            )
        case .justNotInstalled:
            addJustUnavailableItems(to: submenu, repositoryID: repository.id, context: context)
        case .unsupportedJustfile:
            addUnavailableRecipesItem(
                to: submenu,
                repositoryID: repository.id,
                context: context,
                title: "Justfile must be a regular file"
            )
        case .justfileTooLarge:
            addUnavailableRecipesItem(
                to: submenu,
                repositoryID: repository.id,
                context: context,
                title: "Justfile exceeds 16 MiB limit"
            )
        case .unreadableJustfile:
            addUnavailableRecipesItem(
                to: submenu,
                repositoryID: repository.id,
                context: context,
                title: "Could not read Justfile"
            )
        case .invalidJustfile:
            addUnavailableRecipesItem(to: submenu, repositoryID: repository.id, context: context)
        case .changedDuringDiscovery, .verificationUnavailable:
            addUnavailableRecipesItem(
                to: submenu,
                repositoryID: repository.id,
                context: context,
                title: "Could not verify Justfile; reopen menu"
            )
        }
    }
    private func addRecipeItems(
        _ justfile: JustfileDefinition,
        to submenu: NSMenu,
        repositoryID: UUID,
        context: RepoSidebarMenuContext
    ) {
        guard !justfile.recipes.isEmpty else {
            addNoRecipesItem(to: submenu)
            return
        }
        for recipe in justfile.recipes {
            let item = NSMenuItem(
                title: recipe.name,
                action: #selector(runRecipe(_:)),
                keyEquivalent: ""
            )
            item.target = menuTarget
            item.representedObject = RecipeTarget(
                repositoryID: repositoryID,
                recipeName: recipe.name,
                justfile: justfile,
                context: context
            )
            submenu.addItem(item)
        }
    }

    private func addCreateItems(
        to submenu: NSMenu,
        repositoryID: UUID,
        context: RepoSidebarMenuContext,
        justInstalled: Bool
    ) {
        let target = CreateTarget(repositoryID: repositoryID, context: context)
        let createItem = NSMenuItem(title: "Create", action: #selector(createJustfile(_:)), keyEquivalent: "")
        createItem.target = menuTarget
        createItem.representedObject = target
        submenu.addItem(createItem)

        if !justInstalled {
            addJustNotInstalledItem(to: submenu)
        }
        addJustInfoItem(target, to: submenu)
    }

    private func addJustUnavailableItems(
        to submenu: NSMenu,
        repositoryID: UUID,
        context: RepoSidebarMenuContext
    ) {
        addJustNotInstalledItem(to: submenu)
        addJustInfoItem(CreateTarget(repositoryID: repositoryID, context: context), to: submenu)
    }

    private func addJustNotInstalledItem(to submenu: NSMenu) {
        let item = NSMenuItem(title: "just is not installed", action: nil, keyEquivalent: "")
        item.isEnabled = false
        submenu.addItem(item)
    }

    private func addJustInfoItem(_ target: CreateTarget, to submenu: NSMenu) {
        let infoItem = NSMenuItem(title: "What Is This?", action: #selector(showJustInfo(_:)), keyEquivalent: "")
        infoItem.target = menuTarget
        infoItem.representedObject = target
        submenu.addItem(infoItem)
    }

    private func addUnavailableRecipesItem(
        to submenu: NSMenu,
        repositoryID: UUID,
        context: RepoSidebarMenuContext,
        title: String = "Could not list recipes"
    ) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        submenu.addItem(item)
        addJustInfoItem(CreateTarget(repositoryID: repositoryID, context: context), to: submenu)
    }

    private func addNoRecipesItem(to submenu: NSMenu) {
        let emptyItem = NSMenuItem(title: "No recipes found", action: nil, keyEquivalent: "")
        emptyItem.isEnabled = false
        submenu.addItem(emptyItem)
    }
    private func addLoadingRecipesItem(to submenu: NSMenu) {
        let item = NSMenuItem(title: "Loading recipes…", action: nil, keyEquivalent: "")
        item.isEnabled = false
        submenu.addItem(item)
    }

    @objc func runRecipe(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? RecipeTarget,
              isCurrentContext(target.context, repositoryID: target.repositoryID) else { return }
        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.recipeTasks[operationID] = nil }
            guard let failure = await self.executeRecipe(
                repositoryID: target.repositoryID,
                recipeName: target.recipeName,
                justfile: target.justfile,
                context: target.context
            ),
                  !Task.isCancelled,
                  self.isCurrentContext(target.context, repositoryID: target.repositoryID) else { return }
            self.presentError(for: target.context, description: failure)
        }
        recipeTasks[operationID] = task
    }
    func executeRecipe(
        repositoryID: UUID,
        recipeName: String,
        justfile: JustfileDefinition,
        context: RepoSidebarMenuContext
    ) async -> String? {
        guard let repository = coordinator.repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available,
              applicationController.isCurrentRepository(repository),
              justfile.recipes.contains(where: { $0.name == recipeName }) else {
            return "The justfile or recipe is no longer available."
        }
        guard await JustfileService.isCurrentAsync(justfile, in: repository.canonicalURL) else {
            return "Could not verify the justfile; reopen the menu and try again."
        }
        guard !Task.isCancelled,
              isCurrentContext(context, repositoryID: repositoryID),
              let currentRepository = coordinator.repositories.first(where: { $0.id == repositoryID }),
              currentRepository.availability == .available,
              currentRepository.canonicalURL.standardizedFileURL == repository.canonicalURL.standardizedFileURL,
              applicationController.isCurrentRepository(currentRepository) else { return nil }
        do {
            try TerminalLauncher.open(
                command: JustfileService.command(
                    for: recipeName,
                    in: currentRepository.canonicalURL,
                    justfileURL: justfile.fileURL
                ),
                repositoryURL: currentRepository.canonicalURL,
                repositoryID: currentRepository.id,
                recipeName: recipeName
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @objc func createJustfile(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CreateTarget,
              isCurrentContext(target.context, repositoryID: target.repositoryID) else { return }
        guard let repository = coordinator.repositories.first(where: { $0.id == target.repositoryID }),
              repository.availability == .available,
              applicationController.isCurrentRepository(repository) else {
            presentError(
                for: target.context,
                messageText: "Could Not Create Justfile",
                description: "The repository is no longer available."
            )
            return
        }

        do {
            let fileURL = try JustfileService.createExample(in: repository.canonicalURL)
            presentMessage(
                for: target.context,
                messageText: "Justfile Created",
                informativeText: "Created an example justfile at \(fileURL.lastPathComponent)."
            )
        } catch {
            presentError(
                for: target.context,
                messageText: "Could Not Create Justfile",
                description: error.localizedDescription
            )
        }
    }

    @objc func showJustInfo(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CreateTarget,
              isCurrentContext(target.context, repositoryID: target.repositoryID) else { return }
        presentJustInfo(for: target.context)
    }

    func presentJustInfo(for context: RepoSidebarMenuContext) {
        presentMessage(
            for: context,
            messageText: "What Is Just?",
            informativeText: "Just is an easier way to run commands in a project. For instance, you can create a recipe called build and use just build in your terminal rather than a large command everytime. The file it uses is called a justfile. Learn more at the official repo:",
            accessoryView: makeJustWebsiteLink()
        )
    }

    private func makeJustWebsiteLink() -> NSButton {
        let button = NSButton(
            title: Self.justWebsiteURLString,
            target: self,
            action: #selector(openJustWebsite(_:))
        )
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.alignment = .left
        button.attributedTitle = NSAttributedString(
            string: Self.justWebsiteURLString,
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        button.sizeToFit()
        button.setAccessibilityLabel("Open just website")
        return button
    }

    @objc private func openJustWebsite(_ sender: NSButton) {
        guard let url = URL(string: Self.justWebsiteURLString) else { return }
        _ = LaunchServicesApplicationService.shared.open(url)
    }

    private func isCurrentContext(_ context: RepoSidebarMenuContext, repositoryID: UUID) -> Bool {
        guard let menu = context.menu else { return false }
        return menuContext?.menu === menu
            && menuContext?.repositoryIDs == context.repositoryIDs
            && context.repositoryIDs.contains(repositoryID)
    }
    func isCurrentContext(_ context: RepoSidebarMenuContext, repositoryIDs: [UUID]) -> Bool {
        guard let menu = context.menu else { return false }
        return menuContext?.menu === menu && menuContext?.repositoryIDs == repositoryIDs
    }

    func presentError(
        for context: RepoSidebarMenuContext,
        messageText: String = "Could Not Open Just Recipe",
        description: String
    ) {
        presentMessage(
            for: context,
            messageText: messageText,
            informativeText: description,
            alertStyle: .warning
        )
    }

    func presentMessage(
        for context: RepoSidebarMenuContext,
        messageText: String,
        informativeText: String,
        accessoryView: NSView? = nil,
        alertStyle: NSAlert.Style = .informational
    ) {
        let alert = NSAlert()
        alert.alertStyle = alertStyle
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: "OK")
        if let window = context.presentingWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
