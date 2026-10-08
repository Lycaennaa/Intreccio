import AppKit
import UniformTypeIdentifiers

@MainActor
class RepoSidebarOpenApplicationController: NSObject {
    enum OpenApplicationResolution {
        case systemDefault
        case application(ValidatedOpenApplication, name: String)
    }

    let coordinator: AppCoordinator
    private var menuContext: RepoSidebarMenuContext?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func updateMenuContext(_ context: RepoSidebarMenuContext) {
        menuContext = context
    }

    func clearMenuContext(for menu: NSMenu) {
        guard menuContext?.menu === menu else { return }
        menuContext = nil
    }

    func addApplicationMenu(
        to menu: NSMenu,
        title: String,
        resourceURL: URL,
        context: RepoSidebarMenuContext,
        openAction: Selector,
        chooseAction: Selector,
        makeTarget: (OpenApplicationTarget) -> AnyObject
    ) {
        updateMenuContext(context)

        let candidates = LaunchServicesApplicationService.shared.validatedApplications(
            for: resourceURL,
            applicationList: coordinator.state.uiState.openApplicationList
        )
        let applications = candidates.map { candidate in
            OpenApplicationMenuRenderer.MenuApplication(
                applicationURL: candidate.url,
                title: applicationName(for: candidate.url),
                representedObject: makeTarget(.explicit(candidate.application))
            )
        }
        let removalApplications = candidates.map { candidate in
            OpenApplicationMenuRenderer.RemovalApplication(
                applicationURL: candidate.url,
                title: applicationName(for: candidate.url)
            )
        }
        OpenApplicationMenuRenderer.addMenu(
            .available(
                title: title,
                applications: applications,
                removalApplications: removalApplications,
                chooseRepresentedObject: makeTarget(OpenApplicationTarget.defaultApplication)
            ),
            to: menu,
            target: self,
            actions: applicationMenuActions(open: openAction, choose: chooseAction)
        )
    }

    func addUnavailableApplicationMenu(
        to menu: NSMenu,
        title: String,
        message: String,
        openAction: Selector,
        chooseAction: Selector
    ) {
        OpenApplicationMenuRenderer.addMenu(
            .unavailable(title: title, message: message),
            to: menu,
            target: self,
            actions: applicationMenuActions(open: openAction, choose: chooseAction)
        )
    }

    func applicationMenuActions(open: Selector, choose: Selector) -> OpenApplicationMenuRenderer.MenuActions {
        OpenApplicationMenuRenderer.MenuActions(
            open: open,
            choose: choose,
            removeSelected: #selector(removeSelectedOpenApplications(_:)),
            remove: #selector(removeOpenApplications(_:))
        )
    }

    func applications(for directoryURL: URL) -> [URL] {
        LaunchServicesApplicationService.shared.applications(
            for: directoryURL,
            applicationList: coordinator.state.uiState.openApplicationList
        )
    }

    func applicationName(for applicationURL: URL) -> String {
        LaunchServicesApplicationService.shared.applicationName(for: applicationURL)
    }

    func chooseApplication(
        path: String,
        context: RepoSidebarMenuContext,
        resourceChangedDescription: String,
        isResourceValid: @escaping () -> Bool,
        onApplicationSelected: @escaping (ValidatedOpenApplication) -> Void
    ) {
        guard isResourceValid() else {
            presentOpenError(
                applicationName: "Selected Application",
                path: path,
                description: resourceChangedDescription,
                context: context
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
            guard let application = LaunchServicesApplicationService.shared.validatedApplication(at: applicationURL) else {
                self.presentOpenError(
                    applicationName: self.applicationName(for: applicationURL),
                    path: path,
                    description: "The selected application is not valid.",
                    context: context
                )
                return
            }
            self.coordinator.rememberOpenApplication(application.url)
            onApplicationSelected(application)
        }
        if let window = context.presentingWindow {
            panel.beginSheetModal(for: window, completionHandler: completionHandler)
        } else if panel.runModal() == .OK {
            completionHandler(.OK)
        }
    }

    func resolveApplication(
        _ target: OpenApplicationTarget,
        path: String,
        context: RepoSidebarMenuContext,
        explicitFailureDescription: String,
        defaultFailureDescription: String
    ) -> OpenApplicationResolution? {
        switch target {
        case .explicit(let application):
            guard let validatedApplication = LaunchServicesApplicationService.shared.validatedApplication(application) else {
                presentOpenError(
                    applicationName: applicationName(for: application.url),
                    path: path,
                    description: explicitFailureDescription,
                    context: context
                )
                return nil
            }
            return .application(
                validatedApplication,
                name: applicationName(for: validatedApplication.url)
            )
        case .defaultApplication:
            guard let defaultApplicationURL = coordinator.state.uiState.defaultOpenApplicationURL else {
                return .systemDefault
            }
            guard let application = LaunchServicesApplicationService.shared.validatedApplication(at: defaultApplicationURL) else {
                presentOpenError(
                    applicationName: "Default Application",
                    path: path,
                    description: defaultFailureDescription,
                    context: context
                )
                return nil
            }
            return .application(
                application,
                name: applicationName(for: application.url)
            )
        }
    }

    func openResolvedResource(
        _ resourceURL: URL,
        resolution: OpenApplicationResolution,
        path: String,
        context: RepoSidebarMenuContext,
        systemDefaultApplicationName: String,
        systemDefaultFailureDescription: String
    ) {
        switch resolution {
        case .systemDefault:
            guard LaunchServicesApplicationService.shared.open(resourceURL) else {
                presentOpenError(
                    applicationName: systemDefaultApplicationName,
                    path: path,
                    description: systemDefaultFailureDescription,
                    context: context
                )
                return
            }
        case .application(let application, let name):
            LaunchServicesApplicationService.shared.open(
                [resourceURL],
                withApplicationAt: application.referenceURL
            ) { [weak self] description in
                self?.presentOpenError(
                    applicationName: name,
                    path: path,
                    description: description,
                    context: context
                )
            }
        }
    }

    @objc func removeOpenApplications(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenApplicationMenuRenderer.ApplicationTarget else { return }
        coordinator.removeOpenApplications(target.applicationURLs)
    }

    @objc func removeSelectedOpenApplications(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? OpenApplicationMenuRenderer.ApplicationTarget,
              let context = menuContext else { return }
        OpenApplicationRemovalDialog(
            applicationURLs: target.applicationURLs,
            applicationNames: target.applicationURLs.map { applicationName(for: $0) }
        ).present(from: context.presentingWindow, darkAppearance: true) { [weak self] urls in
            self?.coordinator.removeOpenApplications(urls)
        }
    }

    func presentOpenError(
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
