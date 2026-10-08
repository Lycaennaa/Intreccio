import AppKit

@MainActor
final class RepositorySourcesSettingsViewController: NSViewController, SettingsSectionController {
    private let coordinator: AppCoordinator
    private let downloadManager: RepositoryDownloadManager
    private var latestSnapshot: AppSnapshot
    private let sourcesStack = SettingsUI.verticalStack()
    private var operationTask: Task<Void, Never>?

    init(coordinator: AppCoordinator, downloadManager: RepositoryDownloadManager? = nil) {
        self.coordinator = coordinator
        self.downloadManager = downloadManager ?? RepositoryDownloadManager(coordinator: coordinator)
        latestSnapshot = coordinator.snapshot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let addSources = NSPopUpButton(frame: .zero, pullsDown: true)
        addSources.controlSize = .small
        addSources.identifier = NSUserInterfaceItemIdentifier("AddSources")
        addSources.addItem(withTitle: "Add…")
        let actions: [(String, Selector)] = [
            ("Add Root Folder…", #selector(addSourceFolder(_:))),
            ("Add Repository…", #selector(addSourceRepository(_:))),
            ("Create Local Repository…", #selector(createLocalRepository(_:))),
            ("Clone Repository…", #selector(cloneSourceRepository(_:)))
        ]
        for (title, action) in actions {
            let item = addSources.menu?.addItem(withTitle: title, action: action, keyEquivalent: "")
            item?.target = self
        }
        view = SettingsUI.section(title: "Folders & Repositories", views: [
            SettingsUI.row(addSources),
            sourcesStack
        ])
    }

    func stopEventHandling() {
        operationTask?.cancel()
        operationTask = nil
    }

    func refresh(from snapshot: AppSnapshot) {
        latestSnapshot = snapshot
        guard isViewLoaded else { return }
        sourcesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let roots = snapshot.state.watchRoots.map {
            ($0.id, "\($0.displayName) — \($0.lastResolvedPath)", true)
        }
        let repos = snapshot.state.standaloneRepos.map {
            ($0.id, "\($0.displayName) — \($0.lastResolvedPath)", false)
        }
        guard !roots.isEmpty || !repos.isEmpty else {
            sourcesStack.addArrangedSubview(SettingsUI.label("None"))
            return
        }
        let entries = (roots + repos).sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        for (id, title, isWatchRoot) in entries {
            var controls: [NSView] = []
            if isWatchRoot {
                let exclusions = SettingsUI.smallButton(
                    title: "Exclusions…",
                    target: self,
                    action: #selector(manageExclusionsAction(_:))
                )
                exclusions.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
                controls.append(exclusions)
            }
            let remove = SettingsUI.smallButton(
                title: "Remove",
                target: self,
                action: #selector(removeSourceAction(_:))
            )
            remove.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
            controls.append(remove)
            sourcesStack.addArrangedSubview(SettingsUI.row([SettingsUI.label(title)] + controls))
        }
    }

    @objc private func removeSourceAction(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue,
              let id = UUID(uuidString: value),
              let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove this source?"
        alert.informativeText = "Only app state will be removed. Files on disk will not be changed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            runOperation { [coordinator] in await coordinator.removeSource(id) }
        }
    }

    @objc private func manageExclusionsAction(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue,
              let id = UUID(uuidString: value),
              let root = latestSnapshot.state.watchRoots.first(where: { $0.id == id }),
              let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Manage Exclusions"
        guard !root.exclusions.isEmpty else {
            alert.informativeText = "This folder has no excluded repositories."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
            return
        }
        alert.informativeText = "Choose a path to include again."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        popup.addItems(withTitles: root.exclusions)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let path = popup.selectedItem?.title,
                  let self else { return }
            runOperation { [coordinator] in
                await coordinator.restoreExclusion(sourceID: id, path: path)
            }
        }
    }

    private func addSourceDirectory(prompt: String, operation: @escaping (URL) async -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            runOperation { await operation(url) }
        }
    }

    private func runOperation(_ operation: @escaping @MainActor () async -> Void) {
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.refresh(from: self.coordinator.makeSnapshot())
            self.operationTask = nil
        }
    }

    @objc private func addSourceFolder(_ sender: Any?) {
        addSourceDirectory(prompt: "Add Folder") { [coordinator] url in
            await coordinator.addWatchRoot(url)
        }
    }

    @objc private func addSourceRepository(_ sender: Any?) {
        addSourceDirectory(prompt: "Add Repository") { [coordinator] url in
            await coordinator.addStandaloneRepository(url)
        }
    }
    @objc private func cloneSourceRepository(_ sender: Any?) {
        guard let window = view.window else { return }
        RepositoryClonePanel.present(
            on: window,
            loadRepositories: { [coordinator] in try await coordinator.githubRepositories() },
            onClone: { [weak self] sourceURLs, destinationParent in
                guard let self else { return }
                for sourceURL in sourceURLs {
                    self.downloadManager.startClone(
                        from: sourceURL,
                        into: destinationParent,
                        presentingWindow: window
                    )
                }
            }
        )
    }
    @objc private func createLocalRepository(_ sender: Any?) {
        guard let window = view.window else { return }
        LocalRepositoryCreationPanel.present(on: window) { [weak self] name, parentDirectory in
            guard let self else { return }
            self.runOperation { [coordinator] in
                _ = await coordinator.createLocalRepository(named: name, in: parentDirectory)
            }
        }
    }
}
