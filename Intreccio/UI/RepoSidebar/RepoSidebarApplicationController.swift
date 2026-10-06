import AppKit
import UniformTypeIdentifiers

@MainActor
final class RepoSidebarApplicationController: RepoSidebarOpenApplicationController, RepoSidebarRepositoryDirectoryProviding {
    final class OpenDirectoryTarget: NSObject {
        typealias ApplicationTarget = OpenApplicationTarget

        let repositoryID: UUID
        let parentDirectory: Bool
        let directoryResourceID: String
        let application: ApplicationTarget
        let context: RepoSidebarMenuContext

        init(
            repositoryID: UUID,
            parentDirectory: Bool,
            directoryResourceID: String,
            application: ApplicationTarget = .defaultApplication,
            context: RepoSidebarMenuContext
        ) {
            self.repositoryID = repositoryID
            self.parentDirectory = parentDirectory
            self.directoryResourceID = directoryResourceID
            self.application = application
            self.context = context
        }
        var directoryTarget: OpenDirectoriesTarget.DirectoryTarget {
            OpenDirectoriesTarget.DirectoryTarget(
                repositoryID: repositoryID,
                parentDirectory: parentDirectory,
                directoryResourceID: directoryResourceID
            )
        }
    }
    final class OpenDirectoriesTarget: NSObject {
        typealias ApplicationTarget = OpenApplicationTarget

        struct DirectoryTarget {
            let repositoryID: UUID
            let parentDirectory: Bool
            let directoryResourceID: String
        }

        let directories: [DirectoryTarget]
        let application: ApplicationTarget
        let context: RepoSidebarMenuContext

        init(
            directories: [DirectoryTarget],
            application: ApplicationTarget = .defaultApplication,
            context: RepoSidebarMenuContext
        ) {
            self.directories = directories
            self.application = application
            self.context = context
        }
    }
    private struct ValidatedDirectoryTarget {
        let target: OpenDirectoriesTarget.DirectoryTarget
        let url: URL
    }



    func addOpenApplicationMenu(
        to menu: NSMenu,
        title: String,
        repositoryIDs: [UUID],
        parentDirectory: Bool,
        context: RepoSidebarMenuContext
    ) {
        guard let contextMenu = context.menu,
              contextMenu === menu,
              !repositoryIDs.isEmpty,
              context.repositoryIDs == repositoryIDs else { return }
        updateMenuContext(context)
        let directories = repositoryIDs.compactMap {
            validatedDirectoryTarget(for: $0, parentDirectory: parentDirectory)
        }
        let isMultiple = repositoryIDs.count > 1
        guard directories.count == repositoryIDs.count,
              let firstDirectory = directories.first else {
            if shouldOmitUnavailableRepositoryFolderMenu(
                repositoryIDs: repositoryIDs,
                parentDirectory: parentDirectory
            ) {
                return
            }
            addUnavailableApplicationMenu(
                to: menu,
                title: title,
                message: isMultiple
                    ? "One or more selected folders cannot be opened safely"
                    : "Folder cannot be opened safely",
                openAction: isMultiple
                    ? #selector(openRepositoriesWithApplication(_:))
                    : #selector(openRepositoryWithApplication(_:)),
                chooseAction: isMultiple
                    ? #selector(chooseRepositoriesApplication(_:))
                    : #selector(chooseRepositoryApplication(_:))
            )
            return
        }

        let makeTarget: (OpenApplicationTarget) -> AnyObject
        let openAction: Selector
        let chooseAction: Selector
        if isMultiple {
            let directories = directories.map { $0.target }
            makeTarget = { application in
                OpenDirectoriesTarget(
                    directories: directories,
                    application: application,
                    context: context
                )
            }
            openAction = #selector(openRepositoriesWithApplication(_:))
            chooseAction = #selector(chooseRepositoriesApplication(_:))
        } else {
            let directory = firstDirectory.target
            makeTarget = { application in
                OpenDirectoryTarget(
                    repositoryID: directory.repositoryID,
                    parentDirectory: directory.parentDirectory,
                    directoryResourceID: directory.directoryResourceID,
                    application: application,
                    context: context
                )
            }
            openAction = #selector(openRepositoryWithApplication(_:))
            chooseAction = #selector(chooseRepositoryApplication(_:))
        }
        addApplicationMenu(
            to: menu,
            title: title,
            resourceURL: firstDirectory.url,
            context: context,
            openAction: openAction,
            chooseAction: chooseAction,
            makeTarget: makeTarget
        )
    }


    private func shouldOmitUnavailableRepositoryFolderMenu(
        repositoryIDs: [UUID],
        parentDirectory: Bool
    ) -> Bool {
        guard repositoryIDs.count == 1,
              !parentDirectory,
              let repositoryID = repositoryIDs.first,
              let repository = coordinator.repositories.first(where: { $0.id == repositoryID }) else { return false }
        if case .unavailable = repository.availability { return true }
        return false
    }
    private func validatedDirectoryTarget(
        for repositoryID: UUID,
        parentDirectory: Bool
    ) -> ValidatedDirectoryTarget? {
        guard let repository = coordinator.repositories.first(where: { $0.id == repositoryID }),
              let directoryURL = openDirectoryURL(
                  for: repositoryID,
                  parentDirectory: parentDirectory
              ) else { return nil }
        let expectedResourceID = parentDirectory
            ? ResourceIdentity.read(from: directoryURL)
            : repository.resourceID
        guard let expectedResourceID,
              fileReferenceURL(for: directoryURL, expectedResourceID: expectedResourceID) != nil else { return nil }
        return ValidatedDirectoryTarget(
            target: OpenDirectoriesTarget.DirectoryTarget(
                repositoryID: repositoryID,
                parentDirectory: parentDirectory,
                directoryResourceID: expectedResourceID
            ),
            url: directoryURL
        )
    }
    @objc func openRepositoryWithApplication(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenDirectoryTarget,
              case .explicit(let application) = target.application else { return }
        openDirectories(
            [target.directoryTarget],
            application: application,
            context: target.context
        )
    }

    @objc func chooseRepositoryApplication(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenDirectoryTarget else { return }
        chooseApplicationForDirectories(
            [target.directoryTarget],
            context: target.context,
            resourceChangedDescription: "The folder changed before it could be opened."
        )
    }

    @objc func openRepositoriesWithApplication(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenDirectoriesTarget,
              case .explicit(let application) = target.application else { return }
        openDirectories(target.directories, application: application, context: target.context)
    }

    @objc func chooseRepositoriesApplication(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenDirectoriesTarget else { return }
        chooseApplicationForDirectories(
            target.directories,
            context: target.context,
            resourceChangedDescription: "One or more selected folders changed before they could be opened."
        )
    }

    private func openDirectories(
        _ directories: [OpenDirectoriesTarget.DirectoryTarget],
        application: ValidatedOpenApplication,
        context: RepoSidebarMenuContext
    ) {
        for directory in directories {
            openRepository(
                repositoryID: directory.repositoryID,
                application: application,
                parentDirectory: directory.parentDirectory,
                directoryResourceID: directory.directoryResourceID,
                context: context
            )
        }
    }

    private func chooseApplicationForDirectories(
        _ directories: [OpenDirectoriesTarget.DirectoryTarget],
        context: RepoSidebarMenuContext,
        resourceChangedDescription: String
    ) {
        let path = directories.map {
            directoryPath(for: $0.repositoryID, parentDirectory: $0.parentDirectory)
        }.joined(separator: "\n")
        chooseApplication(
            path: path,
            context: context,
            resourceChangedDescription: resourceChangedDescription,
            isResourceValid: { [weak self] in
                guard let self else { return false }
                return directories.allSatisfy { directory in
                    guard let directoryURL = self.openDirectoryURL(
                        for: directory.repositoryID,
                        parentDirectory: directory.parentDirectory
                    ) else { return false }
                    return ResourceIdentity.read(from: directoryURL) == directory.directoryResourceID
                        && self.fileReferenceURL(
                            for: directoryURL,
                            expectedResourceID: directory.directoryResourceID
                        ) != nil
                }
            },
            onApplicationSelected: { [weak self] application in
                self?.openDirectories(directories, application: application, context: context)
            }
        )
    }

    func openRepository(
        repositoryID: UUID,
        application: ValidatedOpenApplication,
        parentDirectory: Bool,
        directoryResourceID: String,
        context: RepoSidebarMenuContext
    ) {
        let applicationName = self.applicationName(for: application.url)
        guard let directoryURL = openDirectoryURL(for: repositoryID, parentDirectory: parentDirectory) else {
            presentOpenError(
                applicationName: applicationName,
                path: directoryPath(for: repositoryID, parentDirectory: parentDirectory),
                description: "The folder is no longer available.",
                context: context
            )
            return
        }
        guard let currentDirectoryURL = openDirectoryURL(for: repositoryID, parentDirectory: parentDirectory),
              currentDirectoryURL == directoryURL,
              ResourceIdentity.read(from: directoryURL) == directoryResourceID else {
            presentOpenError(
                applicationName: applicationName,
                path: directoryPath(for: repositoryID, parentDirectory: parentDirectory),
                description: "The folder changed before it could be opened.",
                context: context
            )
            return
        }
        guard let directoryReferenceURL = fileReferenceURL(for: directoryURL, expectedResourceID: directoryResourceID) else {
            presentOpenError(
                applicationName: applicationName,
                path: directoryURL.path,
                description: "The folder could not be referenced safely.",
                context: context
            )
            return
        }
        guard let resolution = resolveApplication(
            .explicit(application),
            path: directoryURL.path,
            context: context,
            explicitFailureDescription: "The application could not be referenced safely.",
            defaultFailureDescription: "The application could not be referenced safely."
        ) else { return }

        let fileCoordinator = NSFileCoordinator()
        var coordinationError: NSError?
        fileCoordinator.coordinate(
            readingItemAt: directoryReferenceURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            Task { @MainActor in
                self.openResolvedResource(
                    coordinatedURL,
                    resolution: resolution,
                    path: coordinatedURL.path,
                    context: context,
                    systemDefaultApplicationName: "Default Application",
                    systemDefaultFailureDescription: "The folder could not be opened."
                )
            }
        }
        if let coordinationError {
            presentOpenError(
                applicationName: applicationName,
                path: directoryURL.path,
                description: coordinationError.localizedDescription,
                context: context
            )
        }
    }


    func validatedRepositoryDirectory(for repositoryID: UUID) -> RepoSidebarValidatedRepositoryDirectory? {
        guard let repository = coordinator.repositories.first(where: { $0.id == repositoryID }),
              let directoryURL = openDirectoryURL(for: repositoryID, parentDirectory: false),
              let resourceID = repository.resourceID else { return nil }
        return RepoSidebarValidatedRepositoryDirectory(url: directoryURL, resourceID: resourceID)
    }

    func openDirectoryURL(for repositoryID: UUID, parentDirectory: Bool) -> URL? {
        guard let repository = coordinator.repositories.first(where: { $0.id == repositoryID }) else { return nil }
        if parentDirectory {
            let parentURL = repository.canonicalURL.deletingLastPathComponent()
            guard isDirectory(at: parentURL) else { return nil }
            if case .unavailable = repository.availability {
                return parentURL
            }
            guard isCurrentRepository(repository) else { return nil }
            return parentURL
        }
        guard repository.availability == .available, isCurrentRepository(repository) else { return nil }
        return repository.canonicalURL
    }

    func fileReferenceURL(for url: URL, expectedResourceID: String? = nil) -> URL? {
        LaunchServicesApplicationService.shared.fileReferenceURL(for: url, expectedResourceID: expectedResourceID)
    }

    func isCurrentRepository(_ repository: RepoDescriptor) -> Bool {
        guard isDirectory(at: repository.canonicalURL) else { return false }
        guard let expectedResourceID = repository.resourceID else { return false }
        guard let currentResourceID = ResourceIdentity.read(from: repository.canonicalURL) else { return false }
        return expectedResourceID == currentResourceID
    }

    func isDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func directoryPath(for repositoryID: UUID, parentDirectory: Bool) -> String {
        guard let repository = coordinator.repositories.first(where: { $0.id == repositoryID }) else {
            return "The selected repository"
        }
        if parentDirectory {
            return repository.canonicalURL.deletingLastPathComponent().path
        }
        return repository.canonicalURL.path
    }
}