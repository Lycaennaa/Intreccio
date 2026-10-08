import AppKit
import UniformTypeIdentifiers

@MainActor
final class ChangesApplicationActionsController: NSObject {
    struct ValidatedFileSelection {
        let fileURLs: [URL]
        let resourceIDs: [String]
        let referenceURLs: [URL]
    }

    final class FilePathSelection: NSObject {
        let paths: [GitPath]
        let repositoryID: UUID
        let repositoryResourceID: String
        let expectedResourceIDs: [String]

        init(
            paths: [GitPath],
            repositoryID: UUID,
            repositoryResourceID: String,
            expectedResourceIDs: [String]
        ) {
            self.paths = paths
            self.repositoryID = repositoryID
            self.repositoryResourceID = repositoryResourceID
            self.expectedResourceIDs = expectedResourceIDs
        }
    }
    final class FileOpenAction: NSObject {
        typealias ApplicationTarget = OpenApplicationTarget

        let repositoryID: UUID
        let repositoryURL: URL
        let repositoryResourceID: String
        let gitPaths: [GitPath]
        let paths: [String]
        let fileSelection: ValidatedFileSelection
        let application: ApplicationTarget

        var fileResourceIDs: [String] { fileSelection.resourceIDs }
        var fileReferenceURLs: [URL] { fileSelection.referenceURLs }

        init(
            repositoryID: UUID,
            repositoryURL: URL,
            repositoryResourceID: String,
            paths: [String],
            fileSelection: ValidatedFileSelection,
            application: ApplicationTarget = .defaultApplication,
            gitPaths: [GitPath]? = nil
        ) {
            self.repositoryID = repositoryID
            self.repositoryURL = repositoryURL
            self.repositoryResourceID = repositoryResourceID
            self.gitPaths = gitPaths ?? paths.map(GitPath.init)
            self.paths = self.gitPaths.map(\.displayString)
            self.fileSelection = fileSelection
            self.application = application
        }
    }

    private let coordinator: AppCoordinator
    var windowProvider: () -> NSWindow? = { nil }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    var selectedRepositoryURL: URL? {
        guard let repositoryID = coordinator.state.uiState.selectedRepoID,
              let repository = coordinator.repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available else { return nil }
        return repository.canonicalURL
    }

    func addOpenApplicationMenu(to menu: NSMenu, fileOpenAction: FileOpenAction?) {
        let actions = OpenApplicationMenuRenderer.MenuActions(
            open: #selector(openChangeWithApplication(_:)),
            choose: #selector(chooseChangeApplication(_:)),
            removeSelected: #selector(removeSelectedOpenApplications(_:)),
            remove: #selector(removeOpenApplications(_:))
        )
        guard let fileOpenAction,
              !fileOpenAction.paths.isEmpty,
              fileOpenAction.fileSelection.fileURLs.count == fileOpenAction.paths.count,
              fileOpenAction.fileSelection.resourceIDs.count == fileOpenAction.paths.count,
              fileOpenAction.fileSelection.referenceURLs.count == fileOpenAction.paths.count else {
            OpenApplicationMenuRenderer.addMenu(
                .unavailable(title: "Open With", message: "Selection cannot be opened safely"),
                to: menu,
                target: self,
                actions: actions
            )
            return
        }

        let fileSelection = fileOpenAction.fileSelection
        let fileURLs = fileSelection.fileURLs

        let applicationCandidates = LaunchServicesApplicationService.shared.validatedApplications(
            for: fileURLs,
            applicationList: coordinator.state.uiState.openApplicationList
        )
        let applications = applicationCandidates.map { candidate in
            OpenApplicationMenuRenderer.MenuApplication(
                applicationURL: candidate.url,
                title: LaunchServicesApplicationService.shared.applicationName(for: candidate.url),
                representedObject: makeFileOpenAction(
                    from: fileOpenAction,
                    fileSelection: fileSelection,
                    application: candidate.application
                )
            )
        }
        let removalApplications = applicationCandidates.map { candidate in
            OpenApplicationMenuRenderer.RemovalApplication(
                applicationURL: candidate.url,
                title: LaunchServicesApplicationService.shared.applicationName(for: candidate.url)
            )
        }
        OpenApplicationMenuRenderer.addMenu(
            .available(
                title: "Open With",
                applications: applications,
                removalApplications: removalApplications,
                chooseRepresentedObject: fileOpenAction
            ),
            to: menu,
            target: self,
            actions: actions
        )

        let openItem = NSMenuItem(
            title: "Open",
            action: #selector(openChangeWithDefaultApplication(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.representedObject = fileOpenAction
        menu.addItem(openItem)
    }

    @objc func revealChange(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? FilePathSelection else { return }
        revealFiles(selection)
    }

    @discardableResult
    func revealFiles(_ selection: FilePathSelection) -> Bool {
        guard let selectedRepositoryID = coordinator.state.uiState.selectedRepoID,
              selectedRepositoryID == selection.repositoryID,
              let repository = coordinator.repositories.first(where: { $0.id == selectedRepositoryID }),
              repository.availability == .available,
              repository.resourceID == selection.repositoryResourceID,
              ResourceIdentity.read(from: repository.canonicalURL) == selection.repositoryResourceID,
              let fileSelection = validatedFileSelection(
                  gitPaths: selection.paths,
                  repositoryURL: repository.canonicalURL,
                  expectedResourceIDs: selection.expectedResourceIDs,
                  expectedReferenceCount: selection.expectedResourceIDs.count
              ) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting(fileSelection.referenceURLs)
        return true
    }

    @objc func openChangeWithApplication(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FileOpenAction,
              case .explicit(let application) = target.application else { return }
        openFiles(
            target,
            applicationName: LaunchServicesApplicationService.shared.applicationName(for: application.url)
        )
    }

    @objc func removeOpenApplications(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenApplicationMenuRenderer.ApplicationTarget else { return }
        coordinator.removeOpenApplications(target.applicationURLs)
    }

    @objc func removeSelectedOpenApplications(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenApplicationMenuRenderer.ApplicationTarget else { return }
        OpenApplicationRemovalDialog(
            applicationURLs: target.applicationURLs,
            applicationNames: target.applicationURLs.map {
                LaunchServicesApplicationService.shared.applicationName(for: $0)
            }
        ).present(from: windowProvider()) { [weak self] urls in
            self?.coordinator.removeOpenApplications(urls)
        }
    }

    @objc func chooseChangeApplication(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FileOpenAction else { return }
        guard let repositoryID = coordinator.state.uiState.selectedRepoID,
              repositoryID == target.repositoryID,
              let repository = coordinator.repositories.first(where: { $0.id == target.repositoryID }),
              repository.availability == .available,
              repository.canonicalURL == target.repositoryURL,
              repository.resourceID == target.repositoryResourceID,
              ResourceIdentity.read(from: repository.canonicalURL) == target.repositoryResourceID else {
            presentFileOpenError(
                applicationName: "Selected Application",
                paths: target.paths,
                description: "The repository changed before the file could be opened."
            )
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Open"
        let completionHandler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK,
                  let applicationURL = panel.url,
                  let self else { return }
            guard self.coordinator.state.uiState.selectedRepoID == target.repositoryID,
                  let repository = self.coordinator.repositories.first(where: { $0.id == target.repositoryID }),
                  repository.availability == .available,
                  repository.canonicalURL == target.repositoryURL,
                  repository.resourceID == target.repositoryResourceID,
                  ResourceIdentity.read(from: target.repositoryURL) == target.repositoryResourceID,
                  let applicationAction = self.makeFileOpenAction(
                      from: target,
                      fileSelection: target.fileSelection,
                      applicationURL: applicationURL
                  ),
                  applicationAction.repositoryID == target.repositoryID,
                  applicationAction.repositoryURL == target.repositoryURL,
                  applicationAction.repositoryResourceID == target.repositoryResourceID,
                  applicationAction.fileResourceIDs == target.fileResourceIDs else {
                self.presentFileOpenError(
                    applicationName: LaunchServicesApplicationService.shared.applicationName(for: applicationURL),
                    paths: target.paths,
                    description: "The selected file changed before it could be opened."
                )
                return
            }
            self.coordinator.rememberOpenApplication(applicationURL)
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.representedObject = applicationAction
            self.openChangeWithApplication(item)
        }
        if let window = windowProvider() {
            panel.beginSheetModal(for: window, completionHandler: completionHandler)
        } else if panel.runModal() == .OK {
            completionHandler(.OK)
        }
    }

    @objc func openChangeWithDefaultApplication(_ sender: NSMenuItem) {
        guard let fileOpenAction = sender.representedObject as? FileOpenAction,
              case .defaultApplication = fileOpenAction.application else { return }
        let defaultApplicationURL = coordinator.state.uiState.defaultOpenApplicationURL
        openFiles(
            fileOpenAction,
            applicationName: defaultApplicationURL.map {
                LaunchServicesApplicationService.shared.applicationName(for: $0)
            } ?? "Default Application"
        )
    }

    func makeFileOpenAction(paths: [String], applicationURL: URL? = nil) -> FileOpenAction? {
        makeFileOpenAction(
            gitPaths: paths.map(GitPath.init),
            applicationURL: applicationURL
        )
    }

    func makeFileOpenAction(changes: [FileChange], applicationURL: URL? = nil) -> FileOpenAction? {
        var seen = Set<GitPath>()
        let gitPaths = changes.compactMap { change -> GitPath? in
            guard change.isAddressable, seen.insert(change.gitPath).inserted else { return nil }
            return change.gitPath
        }
        guard gitPaths.count == Set(changes.map(\.gitPath)).count else { return nil }
        return makeFileOpenAction(gitPaths: gitPaths, applicationURL: applicationURL)
    }

    func makeFileRevealSelection(changes: [FileChange]) -> FilePathSelection? {
        var seen = Set<GitPath>()
        let paths = changes.compactMap { change -> GitPath? in
            guard change.isAddressable, seen.insert(change.gitPath).inserted else { return nil }
            return change.gitPath
        }
        guard paths.count == Set(changes.map(\.gitPath)).count else { return nil }
        return makeFileRevealSelection(gitPaths: paths)
    }

    func makeFileRevealSelection(gitPaths paths: [GitPath]) -> FilePathSelection? {
        guard !paths.isEmpty,
              paths.count == Set(paths).count,
              let repositoryID = coordinator.state.uiState.selectedRepoID,
              let repository = coordinator.repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available,
              let repositoryResourceID = repository.resourceID,
              paths.allSatisfy(\.isFileActionAddressable) else { return nil }
        let fileURLs = paths.compactMap {
            GitIgnoreWriter.fileURL(repository: repository.canonicalURL, relativePath: $0)
        }
        guard fileURLs.count == paths.count,
              fileURLs.allSatisfy({
                  RepositoryPathPolicy.containsResolvingSymlinks(repository.canonicalURL, $0)
                      && isSafeFileResource($0)
              }) else { return nil }
        let expectedResourceIDs = fileURLs.compactMap { ResourceIdentity.read(from: $0) }
        guard expectedResourceIDs.count == fileURLs.count else { return nil }
        return FilePathSelection(
            paths: paths,
            repositoryID: repositoryID,
            repositoryResourceID: repositoryResourceID,
            expectedResourceIDs: expectedResourceIDs
        )
    }

    func makeFileOpenAction(
        gitPaths: [GitPath],
        applicationURL: URL?
    ) -> FileOpenAction? {
        guard !gitPaths.isEmpty,
              gitPaths.allSatisfy(\.isFileActionAddressable),
              let repositoryID = coordinator.state.uiState.selectedRepoID,
              let repository = coordinator.repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available,
              let repositoryResourceID = repository.resourceID,
              let fileSelection = validatedFileSelection(
                  gitPaths: gitPaths,
                  repositoryURL: repository.canonicalURL
              ) else {
            return nil
        }

        let application: FileOpenAction.ApplicationTarget
        if let applicationURL {
            guard let validatedApplication = LaunchServicesApplicationService.shared.validatedApplication(at: applicationURL) else {
                return nil
            }
            application = .explicit(validatedApplication)
        } else {
            application = .defaultApplication
        }
        return FileOpenAction(
            repositoryID: repositoryID,
            repositoryURL: repository.canonicalURL,
            repositoryResourceID: repositoryResourceID,
            paths: gitPaths.map(\.displayString),
            fileSelection: fileSelection,
            application: application,
            gitPaths: gitPaths
        )
    }

    private func makeFileOpenAction(
        from target: FileOpenAction,
        fileSelection: ValidatedFileSelection,
        application: ValidatedOpenApplication
    ) -> FileOpenAction {
        FileOpenAction(
            repositoryID: target.repositoryID,
            repositoryURL: target.repositoryURL,
            repositoryResourceID: target.repositoryResourceID,
            paths: target.paths,
            fileSelection: fileSelection,
            application: .explicit(application),
            gitPaths: target.gitPaths
        )
    }

    private func makeFileOpenAction(
        from target: FileOpenAction,
        fileSelection: ValidatedFileSelection,
        applicationURL: URL
    ) -> FileOpenAction? {
        guard let application = LaunchServicesApplicationService.shared.validatedApplication(at: applicationURL) else {
            return nil
        }
        return makeFileOpenAction(
            from: target,
            fileSelection: fileSelection,
            application: application
        )
    }

    private func validatedFileSelection(
        paths: [String],
        repositoryURL: URL,
        expectedResourceIDs: [String]? = nil,
        expectedReferenceCount: Int? = nil
    ) -> ValidatedFileSelection? {
        validatedFileSelection(
            gitPaths: paths.map(GitPath.init),
            repositoryURL: repositoryURL,
            expectedResourceIDs: expectedResourceIDs,
            expectedReferenceCount: expectedReferenceCount
        )
    }

    private func isSafeFileResource(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func validatedFileSelection(
        gitPaths: [GitPath],
        repositoryURL: URL,
        expectedResourceIDs: [String]? = nil,
        expectedReferenceCount: Int? = nil
    ) -> ValidatedFileSelection? {
        guard !gitPaths.isEmpty, gitPaths.allSatisfy(\.isFileActionAddressable) else { return nil }
        let fileURLs = gitPaths.compactMap {
            GitIgnoreWriter.fileURL(repository: repositoryURL, relativePath: $0)
        }
        guard fileURLs.count == gitPaths.count,
              !fileURLs.isEmpty,
              fileURLs.allSatisfy({
                  RepositoryPathPolicy.containsResolvingSymlinks(repositoryURL, $0)
                      && isSafeFileResource($0)
              }) else {
            return nil
        }

        let resourceIDs: [String]
        if let expectedResourceIDs {
            guard expectedResourceIDs.count == fileURLs.count else { return nil }
            resourceIDs = expectedResourceIDs
        } else {
            resourceIDs = fileURLs.compactMap { ResourceIdentity.read(from: $0) }
            guard resourceIDs.count == fileURLs.count else { return nil }
        }
        if let expectedReferenceCount {
            guard expectedReferenceCount == fileURLs.count else { return nil }
        }
        guard let referenceURLs = LaunchServicesApplicationService.shared.validatedFileReferenceURLs(
            for: fileURLs,
            expectedResourceIDs: resourceIDs
        ) else { return nil }
        return ValidatedFileSelection(
            fileURLs: fileURLs,
            resourceIDs: resourceIDs,
            referenceURLs: referenceURLs
        )
    }

    // Revalidate containment, resource type, and identity immediately before the URL handoff; residual TOCTOU failures are surfaced rather than retried unsafely.
    func openFiles(
        _ target: FileOpenAction,
        applicationName: String
    ) {
        guard let repositoryID = coordinator.state.uiState.selectedRepoID,
              repositoryID == target.repositoryID,
              let repository = coordinator.repositories.first(where: { $0.id == target.repositoryID }),
              repository.availability == .available,
              repository.canonicalURL == target.repositoryURL,
              repository.resourceID == target.repositoryResourceID,
              ResourceIdentity.read(from: repository.canonicalURL) == target.repositoryResourceID else {
            presentFileOpenError(
                applicationName: applicationName,
                paths: target.paths,
                description: "The repository changed before the file could be opened."
            )
            return
        }
        guard let fileSelection = validatedFileSelection(
            gitPaths: target.gitPaths,
            repositoryURL: target.repositoryURL,
            expectedResourceIDs: target.fileResourceIDs,
            expectedReferenceCount: target.fileReferenceURLs.count
        ) else {
            presentFileOpenError(
                applicationName: applicationName,
                paths: target.paths,
                description: "The selected file changed before it could be opened."
            )
            return
        }
        let fileReferenceURLs = fileSelection.referenceURLs

        switch target.application {
        case .explicit(let application):
            guard let application = LaunchServicesApplicationService.shared.validatedApplication(application) else {
                presentFileOpenError(
                    applicationName: applicationName,
                    paths: target.paths,
                    description: "The application changed before the file could be opened."
                )
                return
            }
            LaunchServicesApplicationService.shared.open(fileReferenceURLs, withApplicationAt: application.referenceURL) { [weak self] description in
                self?.presentFileOpenError(
                    applicationName: applicationName,
                    paths: target.paths,
                    description: description
                )
            }
        case .defaultApplication:
            guard let defaultApplicationURL = coordinator.state.uiState.defaultOpenApplicationURL else {
                let failedPaths = zip(target.paths, fileReferenceURLs).compactMap { path, fileURL in
                    LaunchServicesApplicationService.shared.open(fileURL) ? nil : path
                }
                if !failedPaths.isEmpty {
                    presentFileOpenError(
                        applicationName: applicationName,
                        paths: failedPaths,
                        description: "macOS could not open the selected file."
                    )
                }
                return
            }
            guard let application = LaunchServicesApplicationService.shared.validatedApplication(at: defaultApplicationURL) else {
                presentFileOpenError(
                    applicationName: applicationName,
                    paths: target.paths,
                    description: "The application could not be referenced safely."
                )
                return
            }
            LaunchServicesApplicationService.shared.open(fileReferenceURLs, withApplicationAt: application.referenceURL) { [weak self] description in
                self?.presentFileOpenError(
                    applicationName: LaunchServicesApplicationService.shared.applicationName(for: defaultApplicationURL),
                    paths: target.paths,
                    description: description
                )
            }
        }
    }

    func presentFileOpenError(applicationName: String, paths: [String], description: String) {
        OpenApplicationErrorPresenter.present(
            window: windowProvider(),
            applicationName: applicationName,
            paths: paths,
            description: description
        )
    }
}
