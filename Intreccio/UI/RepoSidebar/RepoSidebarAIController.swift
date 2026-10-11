import AppKit

@MainActor
struct RepoSidebarValidatedRepositoryDirectory {
    let url: URL
    let resourceID: String
    let fileSystemID: String
    init?(url: URL, resourceID: String) {
        guard let fileSystemID = ResourceIdentity.readFileSystemID(from: url),
              ResourceIdentity.read(from: url) == resourceID else { return nil }
        self.url = url
        self.resourceID = resourceID
        self.fileSystemID = fileSystemID
    }
}

@MainActor
protocol RepoSidebarRepositoryDirectoryProviding: AnyObject {
    func validatedRepositoryDirectory(for repositoryID: UUID) -> RepoSidebarValidatedRepositoryDirectory?
    func directoryPath(for repositoryID: UUID, parentDirectory: Bool) -> String
}

@MainActor
final class RepoSidebarAIController: NSObject {
    private enum OpenRepositoryResult {
        case opened
        case repositoryFailure
        case globalFailure
        case stale
    }

    private struct PendingOpenErrors {
        let context: RepoSidebarMenuContext
        let applicationName: String
        var paths: [String]
        var descriptions: [String]
    }

    enum OpenDestination: Equatable {
        case t3Code(T3CodeInstalledApplication?)
        case omp(OMPLauncher.Terminal)

        var applicationName: String {
            switch self {
            case .t3Code(let application): application?.menuTitle ?? "T3 Code"
            case .omp(let terminal): "OMP in \(terminal.menuTitle)"
            }
        }
    }

    final class OpenTarget: NSObject {
        let context: RepoSidebarMenuContext
        let destination: OpenDestination
        let generation: UInt64

        var repositoryIDs: [UUID] {
            context.repositoryIDs
        }

        init(context: RepoSidebarMenuContext, destination: OpenDestination, generation: UInt64) {
            self.context = context
            self.destination = destination
            self.generation = generation
        }
    }

    private let coordinator: AppCoordinator
    private let directoryProvider: RepoSidebarRepositoryDirectoryProviding
    private var menuContext: RepoSidebarMenuContext?
    private var contextGeneration: UInt64 = 0
    private var operationTasks: [UUID: Task<Void, Never>] = [:]
    private var isTerminating = false
    private var pendingTerminationOpenErrors: PendingOpenErrors?

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
        let openInAIToolSubmenu = NSMenu()
        let ompSubmenu = NSMenu()
        for terminal in OMPLauncher.Terminal.allCases {
            addMenuItem(
                terminal.menuTitle,
                target: OpenTarget(
                    context: context,
                    destination: .omp(terminal),
                    generation: generation
                ),
                to: ompSubmenu
            )
        }
        let ompMenuItem = NSMenuItem(title: "OMP", action: nil, keyEquivalent: "")
        ompMenuItem.submenu = ompSubmenu
        openInAIToolSubmenu.addItem(ompMenuItem)

        let applications = T3CodeApplicationService.installedApplications()
        if applications.count > 1 {
            let t3Submenu = NSMenu()
            for application in applications {
                addMenuItem(
                    application.menuTitle,
                    target: OpenTarget(
                        context: context,
                        destination: .t3Code(application),
                        generation: generation
                    ),
                    to: t3Submenu
                )
            }
            let t3MenuItem = NSMenuItem(title: "T3 Code", action: nil, keyEquivalent: "")
            t3MenuItem.submenu = t3Submenu
            openInAIToolSubmenu.addItem(t3MenuItem)
        } else {
            addMenuItem(
                "T3 Code",
                target: OpenTarget(
                    context: context,
                    destination: .t3Code(applications.first),
                    generation: generation
                ),
                to: openInAIToolSubmenu
            )
        }

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
        guard let errors = pendingTerminationOpenErrors else { return }
        pendingTerminationOpenErrors = nil
        OpenApplicationErrorPresenter.present(
            window: errors.context.presentingWindow,
            applicationName: errors.applicationName,
            paths: errors.paths,
            description: errors.descriptions.joined(separator: "\n")
        )
    }

    @objc func openSelectedRepositories(_ sender: NSMenuItem) {
        guard let target = target(from: sender) else { return }
        let repositoryIDs = target.repositoryIDs
        let destination = target.destination
        let context = target.context
        let generation = contextGeneration
        runOperation { [weak self, repositoryIDs, destination, context, generation] in
            guard let self else { return }
            for repositoryID in repositoryIDs {
                guard self.isCurrent(context: context, generation: generation) else { return }
                let result = await self.openRepository(
                    repositoryID: repositoryID,
                    destination: destination,
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
        guard !Task.isCancelled, !isTerminating,
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
        destination: OpenDestination,
        context: RepoSidebarMenuContext,
        generation: UInt64
    ) async -> OpenRepositoryResult {
        guard isCurrent(context: context, generation: generation) else { return .stale }
        guard coordinator.repositories.contains(where: { $0.id == repositoryID }),
              let directory = directoryProvider.validatedRepositoryDirectory(for: repositoryID) else {
            presentOpenError(
                applicationName: destination.applicationName,
                path: directoryProvider.directoryPath(for: repositoryID, parentDirectory: false),
                description: "The folder changed before it could be opened.",
                context: context
            )
            return .repositoryFailure
        }

        do {
            switch destination {
            case .t3Code(let application):
                _ = try await T3CodeApplicationService.shared.openWorkspace(
                    directory.url,
                    expectedResourceID: directory.resourceID,
                    in: application
                )
            case .omp(let terminal):
                try OMPLauncher.open(
                    in: directory.url,
                    expectedFileSystemID: directory.fileSystemID,
                    repositoryID: repositoryID,
                    using: terminal
                ) { [weak self] description in
                    guard let self else { return }
                    self.presentOpenError(
                        applicationName: destination.applicationName,
                        path: directory.url.path,
                        description: description,
                        context: context
                    )
                }
            }
            guard isCurrent(context: context, generation: generation) else { return .stale }
            return .opened
        } catch is CancellationError {
            return .stale
        } catch {
            guard isCurrent(context: context, generation: generation) else { return .stale }
            presentOpenError(
                applicationName: destination.applicationName,
                path: directory.url.path,
                description: error.localizedDescription,
                context: context
            )
            return openFailureResult(for: error, destination: destination)
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

    private func openFailureResult(for error: Error, destination: OpenDestination) -> OpenRepositoryResult {
        switch destination {
        case .t3Code:
            isGlobalFailure(error) ? .globalFailure : .repositoryFailure
        case .omp:
            .globalFailure
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
            action: #selector(openSelectedRepositories(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = target
        menu.addItem(item)
    }

    func presentOpenError(
        applicationName: String,
        path: String,
        description: String,
        context: RepoSidebarMenuContext
    ) {
        if isTerminating {
            if var pending = pendingTerminationOpenErrors {
                pending.paths.append(path)
                pending.descriptions.append(description)
                pendingTerminationOpenErrors = pending
            } else {
                pendingTerminationOpenErrors = PendingOpenErrors(
                    context: context,
                    applicationName: applicationName,
                    paths: [path],
                    descriptions: [description]
                )
            }
            return
        }
        OpenApplicationErrorPresenter.present(
            window: context.presentingWindow,
            applicationName: applicationName,
            paths: [path],
            description: description
        )
    }
}
