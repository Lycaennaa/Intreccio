import AppKit
import UniformTypeIdentifiers

@MainActor
final class OpenApplicationSettingsViewController: NSViewController, SettingsSectionController {
    private static let textFileExtensions = [
        "txt", "md", "log", "csv", "json", "yaml", "yml", "xml", "html", "css", "ini", "cfg",
    ]
    private static let sourceFileExtensions = SourceCodeFileClassifier.extensions

    private let coordinator: AppCoordinator
    private var latestSnapshot: AppSnapshot
    private let previewCandidates = OpenApplicationPreviewCandidates()
    private let defaultAppLabel = NSTextField(labelWithString: "System default")
    private let clearDefaultAppButton = NSButton(title: "Clear", target: nil, action: nil)
    private let rememberedStack = SettingsUI.verticalStack()
    private let hiddenStack = SettingsUI.verticalStack()
    private let folderPreviewPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let removeFolderAppsButton = NSButton(title: "Remove Apps…", target: nil, action: nil)
    private let folderAppsStack = SettingsUI.verticalStack()
    private let fileGroupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let removeFileAppsButton = NSButton(title: "Remove Apps…", target: nil, action: nil)
    private let fileAppsStack = SettingsUI.verticalStack()
    private var workspaceObservers: [NSObjectProtocol] = []

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        latestSnapshot = coordinator.snapshot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        clearDefaultAppButton.target = self
        clearDefaultAppButton.action = #selector(clearDefaultApp(_:))
        clearDefaultAppButton.bezelStyle = .rounded
        clearDefaultAppButton.controlSize = .small
        folderPreviewPopup.target = self
        folderPreviewPopup.action = #selector(folderPreviewSelectionChanged(_:))
        removeFolderAppsButton.target = self
        removeFolderAppsButton.action = #selector(removeFolderPreviewApps(_:))
        removeFolderAppsButton.bezelStyle = .rounded
        removeFolderAppsButton.controlSize = .small
        fileGroupPopup.target = self
        fileGroupPopup.action = #selector(fileGroupSelectionChanged(_:))
        fileGroupPopup.addItems(withTitles: ["Text Files", "Source Files"])
        removeFileAppsButton.target = self
        removeFileAppsButton.action = #selector(removeFilePreviewApps(_:))
        removeFileAppsButton.bezelStyle = .rounded
        removeFileAppsButton.controlSize = .small

        let chooseDefault = SettingsUI.smallButton(
            title: "Choose…",
            target: self,
            action: #selector(chooseDefaultApp(_:))
        )
        let removeMultiple = SettingsUI.smallButton(
            title: "Remove Multiple…",
            target: self,
            action: #selector(removeMultipleRememberedApplications(_:))
        )
        let removeAll = SettingsUI.smallButton(
            title: "Remove All",
            target: self,
            action: #selector(removeAllRememberedApplications(_:))
        )
        let hideApp = SettingsUI.smallButton(
            title: "Hide Application…",
            target: self,
            action: #selector(hideApplication(_:))
        )
        view = SettingsUI.section(title: "Open In App", views: [
            SettingsUI.row(SettingsUI.label("Default application"), defaultAppLabel, chooseDefault, clearDefaultAppButton),
            SettingsUI.label("Remembered applications"),
            SettingsUI.row(removeMultiple, removeAll),
            rememberedStack,
            SettingsUI.divider(),
            SettingsUI.label("Hidden from menus"),
            SettingsUI.row(hideApp),
            hiddenStack,
            SettingsUI.divider(),
            SettingsUI.sectionLabel("Menu Preview"),
            SettingsUI.label("These lists show exactly what the right-click menus offer today."),
            SettingsUI.row(SettingsUI.label("Open folder menu"), folderPreviewPopup, removeFolderAppsButton),
            folderAppsStack,
            SettingsUI.row(SettingsUI.label("Open file menu"), fileGroupPopup, removeFileAppsButton),
            fileAppsStack,
        ])
    }

    func startEventHandling() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidatePreviewCaches() }
            })
        }
    }

    func stopEventHandling() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    func refresh(from snapshot: AppSnapshot) {
        latestSnapshot = snapshot
        guard isViewLoaded else { return }
        updateDefaultAppPresentation(snapshot)
        refreshRememberedApplications(snapshot)
        refreshHiddenApplications(snapshot)
        refreshFolderPreviewSources(snapshot)
        refreshFolderPreviewApps(snapshot)
        refreshFilePreviewApps(snapshot)
    }

    private func invalidatePreviewCaches() {
        previewCandidates.invalidate()
        refreshFolderPreviewApps(latestSnapshot)
        refreshFilePreviewApps(latestSnapshot)
    }

    private func updateDefaultAppPresentation(_ snapshot: AppSnapshot) {
        if let url = snapshot.state.uiState.defaultOpenApplicationURL {
            defaultAppLabel.stringValue = LaunchServicesApplicationService.shared.applicationName(for: url)
            defaultAppLabel.textColor = .white
        } else {
            defaultAppLabel.stringValue = "System default"
            defaultAppLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        }
        clearDefaultAppButton.isEnabled = snapshot.state.uiState.defaultOpenApplicationURL != nil
    }

    @objc private func chooseDefaultApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Choose"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            coordinator.setDefaultOpenApplication(url)
            refreshAllAppLists()
        }
    }

    @objc private func clearDefaultApp(_ sender: NSButton) {
        coordinator.setDefaultOpenApplication(nil)
        refreshAllAppLists()
    }

    private func refreshRememberedApplications(_ snapshot: AppSnapshot) {
        rememberedStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = snapshot.state.uiState.savedOpenApplicationURLs
        guard !urls.isEmpty else {
            rememberedStack.addArrangedSubview(SettingsUI.label("None yet"))
            return
        }
        for url in urls {
            let remove = SettingsUI.smallButton(
                title: "Remove",
                target: self,
                action: #selector(removeRememberedApplication(_:))
            )
            remove.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
            rememberedStack.addArrangedSubview(SettingsUI.row(
                SettingsUI.label(LaunchServicesApplicationService.shared.applicationName(for: url)),
                remove
            ))
        }
    }

    private func refreshHiddenApplications(_ snapshot: AppSnapshot) {
        hiddenStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = snapshot.state.uiState.excludedOpenApplicationURLs
        guard !urls.isEmpty else {
            hiddenStack.addArrangedSubview(SettingsUI.label("None"))
            return
        }
        for url in urls {
            let restore = SettingsUI.smallButton(
                title: "Restore",
                target: self,
                action: #selector(restoreHiddenApplication(_:))
            )
            restore.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
            hiddenStack.addArrangedSubview(SettingsUI.row(
                SettingsUI.label(LaunchServicesApplicationService.shared.applicationName(for: url)),
                restore
            ))
        }
    }

    private func refreshAllAppLists() {
        refresh(from: coordinator.makeSnapshot())
    }

    @objc private func removeRememberedApplication(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let url = URL(string: value) else { return }
        coordinator.removeOpenApplication(url)
        refreshAllAppLists()
    }

    @objc private func removeMultipleRememberedApplications(_ sender: NSButton) {
        let urls = latestSnapshot.state.uiState.savedOpenApplicationURLs
        guard !urls.isEmpty else { return }
        presentRemovalDialog(urls: urls)
    }

    @objc private func removeAllRememberedApplications(_ sender: NSButton) {
        let urls = latestSnapshot.state.uiState.savedOpenApplicationURLs
        guard !urls.isEmpty else { return }
        coordinator.removeOpenApplications(urls)
        refreshAllAppLists()
    }

    @objc private func hideApplication(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Hide"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            coordinator.removeOpenApplication(url)
            refreshAllAppLists()
        }
    }

    @objc private func restoreHiddenApplication(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let url = URL(string: value) else { return }
        coordinator.restoreExcludedOpenApplications([url])
        refreshAllAppLists()
    }

    private func presentRemovalDialog(urls: [URL]) {
        OpenApplicationRemovalDialog(
            applicationURLs: urls,
            applicationNames: urls.map { LaunchServicesApplicationService.shared.applicationName(for: $0) }
        ).present(from: view.window, darkAppearance: true) { [weak self] removedURLs in
            self?.coordinator.removeOpenApplications(removedURLs)
            self?.refreshAllAppLists()
        }
    }

    private func previewSources(in snapshot: AppSnapshot) -> [(id: UUID, title: String, path: String)] {
        let roots = snapshot.state.watchRoots.map { ($0.id, $0.displayName, $0.lastResolvedPath) }
        let repos = snapshot.state.standaloneRepos.map { ($0.id, $0.displayName, $0.lastResolvedPath) }
        return (roots + repos).sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    private func refreshFolderPreviewSources(_ snapshot: AppSnapshot) {
        let previousID = folderPreviewPopup.selectedItem?.identifier
        folderPreviewPopup.removeAllItems()
        for source in previewSources(in: snapshot) {
            folderPreviewPopup.addItem(withTitle: "\(source.title) — \(source.path)")
            folderPreviewPopup.lastItem?.identifier = NSUserInterfaceItemIdentifier(source.id.uuidString)
        }
        if let previousID,
           let index = folderPreviewPopup.itemArray.firstIndex(where: { $0.identifier == previousID }) {
            folderPreviewPopup.selectItem(at: index)
        }
    }

    @objc private func folderPreviewSelectionChanged(_ sender: NSPopUpButton) {
        refreshFolderPreviewApps(latestSnapshot)
    }

    @discardableResult
    private func refreshFolderPreviewApps(_ snapshot: AppSnapshot, force: Bool = false) -> [URL] {
        guard let value = folderPreviewPopup.selectedItem?.identifier?.rawValue,
              let id = UUID(uuidString: value),
              let source = previewSources(in: snapshot).first(where: { $0.id == id }) else {
            replaceContents(of: folderAppsStack, with: SettingsUI.label("No folders added"))
            removeFolderAppsButton.isEnabled = false
            return []
        }
        let applications = previewCandidates.folderApplications(
            sourceID: id,
            path: source.path,
            applicationList: snapshot.state.uiState.openApplicationList,
            force: force
        )
        replaceContents(
            of: folderAppsStack,
            with: SettingsUI.label(applications.isEmpty ? "None offered for this folder" : "\(applications.count) offered")
        )
        removeFolderAppsButton.isEnabled = !applications.isEmpty
        return applications
    }

    @objc private func removeFolderPreviewApps(_ sender: NSButton) {
        let applications = refreshFolderPreviewApps(latestSnapshot, force: true)
        guard !applications.isEmpty else { return }
        presentRemovalDialog(urls: applications)
    }

    @objc private func fileGroupSelectionChanged(_ sender: NSPopUpButton) {
        refreshFilePreviewApps(latestSnapshot)
    }

    private var currentFileExtensions: [String] {
        fileGroupPopup.indexOfSelectedItem == 0 ? Self.textFileExtensions : Self.sourceFileExtensions
    }

    @discardableResult
    private func refreshFilePreviewApps(_ snapshot: AppSnapshot, force: Bool = false) -> [URL]? {
        let refreshed = previewCandidates.fileApplications(
            group: fileGroupPopup.indexOfSelectedItem,
            extensions: currentFileExtensions,
            applicationList: snapshot.state.uiState.openApplicationList,
            force: force
        )
        let applications = refreshed ?? previewCandidates.cachedFileApplications
        replaceContents(
            of: fileAppsStack,
            with: SettingsUI.label(applications.isEmpty ? "None offered for this group" : "\(applications.count) offered")
        )
        removeFileAppsButton.isEnabled = !applications.isEmpty
        return refreshed
    }

    @objc private func removeFilePreviewApps(_ sender: NSButton) {
        guard let applications = refreshFilePreviewApps(latestSnapshot, force: true), !applications.isEmpty else { return }
        presentRemovalDialog(urls: applications)
    }

    private func replaceContents(of stack: NSStackView, with view: NSView) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(view)
    }
}

