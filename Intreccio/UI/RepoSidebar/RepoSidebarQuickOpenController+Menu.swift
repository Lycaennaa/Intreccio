import AppKit

extension RepoSidebarQuickOpenController {
    final class OpenFileTarget: NSObject {
        typealias ApplicationTarget = OpenApplicationTarget

        let repositoryID: UUID
        let repositoryURL: URL
        let repositoryResourceID: String
        let relativePath: String
        let fileResourceID: String
        let application: ApplicationTarget
        let context: RepoSidebarMenuContext

        init(
            repositoryID: UUID,
            repositoryURL: URL,
            repositoryResourceID: String,
            relativePath: String,
            fileResourceID: String,
            application: ApplicationTarget = .defaultApplication,
            context: RepoSidebarMenuContext
        ) {
            self.repositoryID = repositoryID
            self.repositoryURL = repositoryURL
            self.repositoryResourceID = repositoryResourceID
            self.relativePath = relativePath
            self.fileResourceID = fileResourceID
            self.application = application
            self.context = context
        }
    }

    final class QuickOpenFileTarget: NSObject {
        let repositoryID: UUID
        let relativePath: String
        let context: RepoSidebarMenuContext

        init(repositoryID: UUID, relativePath: String, context: RepoSidebarMenuContext) {
            self.repositoryID = repositoryID
            self.relativePath = relativePath
            self.context = context
        }
    }

    final class QuickOpenFileAssignmentTarget: NSObject {
        let repositoryID: UUID
        let repositoryURL: URL
        let repositoryResourceID: String
        let context: RepoSidebarMenuContext

        init(
            repositoryID: UUID,
            repositoryURL: URL,
            repositoryResourceID: String,
            context: RepoSidebarMenuContext
        ) {
            self.repositoryID = repositoryID
            self.repositoryURL = repositoryURL
            self.repositoryResourceID = repositoryResourceID
            self.context = context
        }
    }

    func addOpenFileMenuItem(
        to menu: NSMenu,
        repositoryIDs: [UUID],
        context: RepoSidebarMenuContext
    ) {
        guard let contextMenu = context.menu,
              contextMenu === menu,
              context.repositoryIDs == repositoryIDs else { return }
        updateMenuContext(context)

        let openMenu = NSMenu(title: "Open")
        if repositoryIDs.count == 1,
           let repositoryID = repositoryIDs.first,
           let repositoryContext = availableRepositoryContext(for: repositoryID) {
            addOpenMenuContents(
                to: openMenu,
                repositoryID: repositoryID,
                repositoryURL: repositoryContext.repository.canonicalURL,
                repositoryResourceID: repositoryContext.resourceID,
                context: context
            )
        } else {
            for repositoryID in repositoryIDs {
                guard let repositoryContext = availableRepositoryContext(for: repositoryID) else { continue }
                let repository = repositoryContext.repository
                let repositoryMenu = NSMenu(title: repository.displayName)
                addOpenMenuContents(
                    to: repositoryMenu,
                    repositoryID: repositoryID,
                    repositoryURL: repository.canonicalURL,
                    repositoryResourceID: repositoryContext.resourceID,
                    context: context
                )
                let repositoryItem = NSMenuItem(
                    title: repository.displayName,
                    action: nil,
                    keyEquivalent: ""
                )
                repositoryItem.submenu = repositoryMenu
                openMenu.addItem(repositoryItem)
            }
        }
        guard !openMenu.items.isEmpty else { return }
        let item = NSMenuItem(title: "Open", action: nil, keyEquivalent: "")
        item.submenu = openMenu
        menu.addItem(item)
    }
    private func addOpenMenuContents(
        to openMenu: NSMenu,
        repositoryID: UUID,
        repositoryURL: URL,
        repositoryResourceID: String,
        context: RepoSidebarMenuContext
    ) {
        let paths = coordinator.quickOpenFilePaths(for: repositoryID)
        for path in paths {
            addQuickOpenFileMenuItem(
                path: path,
                repositoryID: repositoryID,
                repositoryURL: repositoryURL,
                repositoryResourceID: repositoryResourceID,
                context: context,
                to: openMenu
            )
        }
        if !paths.isEmpty { openMenu.addItem(.separator()) }

        let assignItem = NSMenuItem(
            title: "Assign Files…",
            action: #selector(chooseRepositoryFiles(_:)),
            keyEquivalent: ""
        )
        assignItem.target = self
        assignItem.representedObject = QuickOpenFileAssignmentTarget(
            repositoryID: repositoryID,
            repositoryURL: repositoryURL,
            repositoryResourceID: repositoryResourceID,
            context: context
        )
        openMenu.addItem(assignItem)

        if !paths.isEmpty {
            let removeMenu = NSMenu(title: "Remove File")
            for path in paths {
                let item = NSMenuItem(
                    title: path,
                    action: #selector(removeQuickOpenFile(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = QuickOpenFileTarget(
                    repositoryID: repositoryID,
                    relativePath: path,
                    context: context
                )
                removeMenu.addItem(item)
            }
            let removeItem = NSMenuItem(title: "Remove File", action: nil, keyEquivalent: "")
            removeItem.submenu = removeMenu
            openMenu.addItem(removeItem)
        }
    }

    private func addQuickOpenFileMenuItem(
        path: String,
        repositoryID: UUID,
        repositoryURL: URL,
        repositoryResourceID: String,
        context: RepoSidebarMenuContext,
        to menu: NSMenu
    ) {
        let fileMenu = NSMenu(title: path)
        if let fileURL = GitIgnoreWriter.fileURL(repository: repositoryURL, relativePath: path),
           case .valid(let validatedFiles) = validatedRepositoryFiles(at: [fileURL], repositoryURL: repositoryURL),
           let validatedFile = validatedFiles.first {
            addOpenFileApplicationMenu(
                to: fileMenu,
                repositoryID: repositoryID,
                repositoryURL: repositoryURL,
                repositoryResourceID: repositoryResourceID,
                file: validatedFile,
                context: context
            )
            let openItem = NSMenuItem(
                title: "Open",
                action: #selector(openRepositoryFileWithDefaultApplication(_:)),
                keyEquivalent: ""
            )
            openItem.target = self
            openItem.representedObject = OpenFileTarget(
                repositoryID: repositoryID,
                repositoryURL: repositoryURL,
                repositoryResourceID: repositoryResourceID,
                relativePath: validatedFile.relativePath,
                fileResourceID: validatedFile.resourceID,
                context: context
            )
            fileMenu.addItem(openItem)
        } else {
            addUnavailableApplicationMenu(
                to: fileMenu,
                title: "Open With",
                message: "File cannot be opened safely",
                openAction: #selector(openRepositoryFileWithApplication(_:)),
                chooseAction: #selector(chooseRepositoryFileApplication(_:))
            )
        }

        let item = NSMenuItem(title: path, action: nil, keyEquivalent: "")
        item.submenu = fileMenu
        menu.addItem(item)
    }

    private func addOpenFileApplicationMenu(
        to menu: NSMenu,
        repositoryID: UUID,
        repositoryURL: URL,
        repositoryResourceID: String,
        file: ValidatedRepositoryFile,
        context: RepoSidebarMenuContext
    ) {
        addApplicationMenu(
            to: menu,
            title: "Open With",
            resourceURL: file.url,
            context: context,
            openAction: #selector(openRepositoryFileWithApplication(_:)),
            chooseAction: #selector(chooseRepositoryFileApplication(_:)),
            makeTarget: { application in
                OpenFileTarget(
                    repositoryID: repositoryID,
                    repositoryURL: repositoryURL,
                    repositoryResourceID: repositoryResourceID,
                    relativePath: file.relativePath,
                    fileResourceID: file.resourceID,
                    application: application,
                    context: context
                )
            }
        )
    }

    @objc func openRepositoryFileWithApplication(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenFileTarget,
              case .explicit(let application) = target.application else { return }
        openRepositoryFile(target, application: .explicit(application))
    }

    @objc func openRepositoryFileWithDefaultApplication(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenFileTarget,
              case .defaultApplication = target.application else { return }
        openRepositoryFile(target, application: .defaultApplication)
    }

    @objc func chooseRepositoryFileApplication(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenFileTarget else { return }
        chooseApplication(
            path: target.relativePath,
            context: target.context,
            resourceChangedDescription: "The file changed before it could be opened.",
            isResourceValid: { [weak self] in
                self?.validatedRepositoryFile(for: target) != nil
            },
            onApplicationSelected: { [weak self] application in
                self?.openRepositoryFile(target, application: .explicit(application))
            }
        )
    }

    @objc func chooseRepositoryFiles(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? QuickOpenFileAssignmentTarget else { return }
        guard let repositoryURL = currentRepositoryURL(
            repositoryID: target.repositoryID,
            repositoryURL: target.repositoryURL,
            repositoryResourceID: target.repositoryResourceID
        ) else {
            presentOpenError(
                applicationName: "Selected File",
                path: target.repositoryURL.path,
                description: "The repository changed before files could be assigned.",
                context: target.context
            )
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = repositoryURL
        panel.prompt = "Assign"

        let completionHandler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK,
                  let self,
                  !panel.urls.isEmpty else { return }
            guard let currentRepositoryURL = self.currentRepositoryURL(
                repositoryID: target.repositoryID,
                repositoryURL: target.repositoryURL,
                repositoryResourceID: target.repositoryResourceID
            ) else {
                self.presentOpenError(
                    applicationName: "Selected File",
                    path: target.repositoryURL.path,
                    description: "The repository changed before files could be assigned.",
                    context: target.context
                )
                return
            }
            switch self.validatedRepositoryFiles(at: panel.urls, repositoryURL: currentRepositoryURL) {
            case .capacityExceeded:
                self.presentOpenError(
                    applicationName: "Selected File",
                    path: target.repositoryURL.path,
                    description: "Quick Open supports at most \(PersistedUIState.maxQuickOpenFilesPerRepository) files per assignment.",
                    context: target.context
                )
            case .invalid:
                self.presentOpenError(
                    applicationName: "Selected File",
                    path: target.repositoryURL.path,
                    description: "Each selected file must be inside the repository and remain available.",
                    context: target.context
                )
            case .valid(let files):
                let result = self.coordinator.setQuickOpenFilePaths(
                    self.coordinator.quickOpenFilePaths(for: target.repositoryID) + files.map(\.relativePath),
                    for: target.repositoryID
                )
                if case .capacityExceeded = result {
                    self.presentOpenError(
                        applicationName: "Selected File",
                        path: target.repositoryURL.path,
                        description: "Quick Open has reached its storage limit. Remove an assigned file before adding another.",
                        context: target.context
                    )
                }
            }
        }
        if let window = target.context.presentingWindow {
            panel.beginSheetModal(for: window, completionHandler: completionHandler)
        } else if panel.runModal() == .OK {
            completionHandler(.OK)
        }
    }

    @objc func removeQuickOpenFile(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? QuickOpenFileTarget else { return }
        let paths = coordinator.quickOpenFilePaths(for: target.repositoryID)
            .filter { $0 != target.relativePath }
        _ = coordinator.setQuickOpenFilePaths(paths, for: target.repositoryID)
    }

    private func availableRepositoryContext(for repositoryID: UUID) -> (
        repository: RepoDescriptor,
        resourceID: String
    )? {
        guard let repository = coordinator.repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available,
              let resourceID = repository.resourceID,
              currentRepositoryURL(
                  repositoryID: repositoryID,
                  repositoryURL: repository.canonicalURL,
                  repositoryResourceID: resourceID
              ) != nil else { return nil }
        return (repository, resourceID)
    }
    private func currentRepositoryURL(
        repositoryID: UUID,
        repositoryURL: URL,
        repositoryResourceID: String
    ) -> URL? {
        guard let repository = coordinator.repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available,
              repository.canonicalURL == repositoryURL,
              repository.resourceID == repositoryResourceID,
              isDirectory(at: repositoryURL),
              ResourceIdentity.read(from: repositoryURL) == repositoryResourceID else { return nil }
        return repositoryURL
    }

    private struct ValidatedRepositoryFile {
        let url: URL
        let relativePath: String
        let resourceID: String
        let referenceURL: URL
    }

    private enum RepositoryFileValidationResult {
        case valid([ValidatedRepositoryFile])
        case capacityExceeded
        case invalid
    }

    private func validatedRepositoryFile(for target: OpenFileTarget) -> ValidatedRepositoryFile? {
        guard let repositoryURL = currentRepositoryURL(
            repositoryID: target.repositoryID,
            repositoryURL: target.repositoryURL,
            repositoryResourceID: target.repositoryResourceID
        ),
        let fileURL = GitIgnoreWriter.fileURL(repository: repositoryURL, relativePath: target.relativePath),
        case .valid(let files) = validatedRepositoryFiles(at: [fileURL], repositoryURL: repositoryURL),
        let file = files.first,
        file.resourceID == target.fileResourceID else { return nil }
        return file
    }

    private func validatedRepositoryFiles(
        at fileURLs: [URL],
        repositoryURL: URL
    ) -> RepositoryFileValidationResult {
        guard !fileURLs.isEmpty else { return .invalid }
        guard fileURLs.count <= PersistedUIState.maxQuickOpenFilesPerRepository else {
            return .capacityExceeded
        }
        let files = fileURLs.compactMap { fileURL -> (url: URL, relativePath: String, resourceID: String)? in
            guard isRegularFile(at: fileURL),
                  RepositoryPathPolicy.containsResolvingSymlinks(repositoryURL, fileURL),
                  let path = RepositoryPathPolicy.relativePath(from: repositoryURL, to: fileURL),
                  GitIgnoreWriter.fileURL(repository: repositoryURL, relativePath: path) != nil,
                  let resourceID = ResourceIdentity.read(from: fileURL) else { return nil }
            return (fileURL, path, resourceID)
        }
        guard files.count == fileURLs.count else { return .invalid }
        switch PersistedUIState.validatedQuickOpenFilePathsForMutation(files.map(\.relativePath)) {
        case .capacityExceeded:
            return .capacityExceeded
        case .invalid:
            return .invalid
        case .valid(let paths):
            guard paths.count == files.count else { return .invalid }
        }
        guard let referenceURLs = LaunchServicesApplicationService.shared.validatedFileReferenceURLs(
            for: files.map(\.url),
            expectedResourceIDs: files.map(\.resourceID)
        ),
        referenceURLs.count == files.count else { return .invalid }
        return .valid(zip(files, referenceURLs).map { file, referenceURL in
            ValidatedRepositoryFile(
                url: file.url,
                relativePath: file.relativePath,
                resourceID: file.resourceID,
                referenceURL: referenceURL
            )
        })
    }

    private func openRepositoryFile(_ target: OpenFileTarget, application: OpenApplicationTarget) {
        guard let selection = validatedRepositoryFile(for: target) else {
            presentOpenError(
                applicationName: "Selected File",
                path: target.relativePath,
                description: "The assigned file changed before it could be opened.",
                context: target.context
            )
            return
        }
        guard let resolution = resolveApplication(
            application,
            path: target.relativePath,
            context: target.context,
            explicitFailureDescription: "The application changed before the file could be opened.",
            defaultFailureDescription: "The default application could not be referenced safely."
        ) else { return }
        openResolvedResource(
            selection.referenceURL,
            resolution: resolution,
            path: target.relativePath,
            context: target.context,
            systemDefaultApplicationName: "Default Application",
            systemDefaultFailureDescription: "macOS could not open the assigned file."
        )
    }

    private func isRegularFile(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func isDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
