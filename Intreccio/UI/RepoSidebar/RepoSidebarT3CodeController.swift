import AppKit

@MainActor
struct RepoSidebarValidatedRepositoryDirectory {
    let url: URL
    let resourceID: String
}

@MainActor
protocol RepoSidebarRepositoryDirectoryProviding: AnyObject {
    func validatedRepositoryDirectory(for repositoryID: UUID) -> RepoSidebarValidatedRepositoryDirectory?
    func directoryPath(for repositoryID: UUID, parentDirectory: Bool) -> String
}

@MainActor
final class RepoSidebarT3CodeController: NSObject {
    private enum OpenRepositoryResult {
        case opened
        case repositoryFailure
        case globalFailure
        case stale
    }
    final class OpenTarget: NSObject {
        let context: RepoSidebarMenuContext
        let application: T3CodeInstalledApplication?
        let generation: UInt64

        var repositoryIDs: [UUID] {
            context.repositoryIDs
        }

        init(
            context: RepoSidebarMenuContext,
            application: T3CodeInstalledApplication?,
            generation: UInt64
        ) {
            self.context = context
            self.application = application
            self.generation = generation
        }
    }

    private let coordinator: AppCoordinator
    private let directoryProvider: RepoSidebarRepositoryDirectoryProviding
    private var menuContext: RepoSidebarMenuContext?
    private var contextGeneration: UInt64 = 0
    private var operationTasks: [UUID: Task<Void, Never>] = [:]
    private var isTerminating = false

    init(
        coordinator: AppCoordinator,
        directoryProvider: RepoSidebarRepositoryDirectoryProviding
    ) {
        self.coordinator = coordinator
        self.directoryProvider = directoryProvider
        super.init()
    }


    func updateMenuContext(_ context: RepoSidebarMenuContext) {
        contextGeneration &+= 1
        cancelActiveOperations()
        menuContext = context
    }

    func clearMenuContext(for menu: NSMenu) {
        guard menuContext?.menu === menu else { return }
        contextGeneration &+= 1
        cancelActiveOperations()
        menuContext = nil
    }

    func addMenu(to menu: NSMenu, context: RepoSidebarMenuContext) {
        updateMenuContext(context)
        let generation = contextGeneration
        let applications = T3CodeApplicationService.installedApplications()
        guard applications.count > 1 else {
            addMenuItem(
                "Open in AI Tool",
                target: OpenTarget(context: context, application: applications.first, generation: generation),
                to: menu
            )
            return
        }

        let t3Submenu = NSMenu()
        for application in applications {
            addMenuItem(
                application.menuTitle,
                target: OpenTarget(context: context, application: application, generation: generation),
                to: t3Submenu
            )
        }
        let t3MenuItem = NSMenuItem(title: "T3 Code", action: nil, keyEquivalent: "")
        t3MenuItem.submenu = t3Submenu
        let openInAIToolSubmenu = NSMenu()
        openInAIToolSubmenu.addItem(t3MenuItem)
        let menuItem = NSMenuItem(title: "Open in AI Tool", action: nil, keyEquivalent: "")
        menuItem.submenu = openInAIToolSubmenu
        menu.addItem(menuItem)
    }

    func cancelOperationsForTermination() -> [Task<Void, Never>] {
        isTerminating = true
        let tasks = Array(operationTasks.values)
        cancelActiveOperations()
        return tasks
    }

    private func cancelActiveOperations() {
        operationTasks.values.forEach { $0.cancel() }
        operationTasks.removeAll()
    }

    func resumeOperationsAfterFailedTermination() {
        isTerminating = false
    }

    @objc func openSelectedRepositoriesInT3Code(_ sender: NSMenuItem) {
        guard let target = target(from: sender) else { return }
        let repositoryIDs = target.repositoryIDs
        let application = target.application
        let context = target.context
        let generation = contextGeneration
        runOperation { [weak self, repositoryIDs, application, context, generation] in
            guard let self else { return }
            for repositoryID in repositoryIDs {
                guard self.isCurrent(context: context, generation: generation) else { return }
                let result = await self.openRepository(
                    repositoryID: repositoryID,
                    application: application,
                    context: context,
                    generation: generation
                )
                guard self.isCurrent(context: context, generation: generation) else { return }
                switch result {
                case .opened, .repositoryFailure:
                    continue
                case .globalFailure, .stale:
                    return
                }
            }
        }
    }

    private func isCurrent(context: RepoSidebarMenuContext, generation: UInt64) -> Bool {
        guard !Task.isCancelled,
              contextGeneration == generation,
              let activeContext = menuContext,
              activeContext.menu === context.menu,
              activeContext.repositoryIDs == context.repositoryIDs else { return false }
        return true
    }

    private func target(from sender: NSMenuItem) -> OpenTarget? {
        guard let target = sender.representedObject as? OpenTarget,
              target.generation == contextGeneration,
              let activeMenu = menuContext?.menu,
              activeMenu === target.context.menu,
              menuContext?.repositoryIDs == target.repositoryIDs else { return nil }
        return target
    }

    private func openRepository(
        repositoryID: UUID,
        application: T3CodeInstalledApplication?,
        context: RepoSidebarMenuContext,
        generation: UInt64
    ) async -> OpenRepositoryResult {
        guard isCurrent(context: context, generation: generation) else { return .stale }
        let applicationName = application?.menuTitle ?? "T3 Code"
        guard coordinator.repositories.contains(where: { $0.id == repositoryID }),
              let directory = directoryProvider.validatedRepositoryDirectory(for: repositoryID) else {
            presentOpenError(
                applicationName: applicationName,
                path: directoryProvider.directoryPath(for: repositoryID, parentDirectory: false),
                description: "The folder changed before it could be opened.",
                context: context
            )
            return .repositoryFailure
        }

        do {
            _ = try await T3CodeApplicationService.shared.openWorkspace(
                directory.url,
                expectedResourceID: directory.resourceID,
                in: application
            )
            guard isCurrent(context: context, generation: generation) else { return .stale }
            return .opened
        } catch is CancellationError {
            return .stale
        } catch {
            guard isCurrent(context: context, generation: generation) else { return .stale }
            presentOpenError(
                applicationName: applicationName,
                path: directory.url.path,
                description: error.localizedDescription,
                context: context
            )
            return isGlobalFailure(error) ? .globalFailure : .repositoryFailure
        }
    }

    private func isGlobalFailure(_ error: Error) -> Bool {
        guard let error = error as? T3CodeApplicationError else { return true }
        switch error {
        case .applicationNotInstalled,
             .applicationLaunchFailed,
             .applicationAlreadyRunning,
             .startupTimedOut,
             .responseTimedOut,
             .socketConnectionFailed,
             .invalidSocketResponse,
             .activationFailed:
            return true
        case .invalidWorkspace, .workspaceChanged, .projectCreationFailed, .threadOpenFailed:
            return false
        }
    }

    private func runOperation(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        guard !isTerminating else { return }
        let operationID = UUID()
        let task = Task { [weak self] in
            defer { self?.operationTasks[operationID] = nil }
            guard !Task.isCancelled else { return }
            await operation()
        }
        operationTasks[operationID] = task
    }

    private func addMenuItem(
        _ title: String,
        target: OpenTarget,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(openSelectedRepositoriesInT3Code(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = target
        menu.addItem(item)
    }

    private func presentOpenError(
        applicationName: String,
        path: String,
        description: String,
        context: RepoSidebarMenuContext
    ) {
        OpenApplicationErrorPresenter.present(
            window: context.presentingWindow,
            applicationName: applicationName,
            paths: [path],
            description: description
        )
    }
}