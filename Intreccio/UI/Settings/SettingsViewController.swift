import AppKit

@MainActor
protocol SettingsSectionController: AnyObject {
    func startEventHandling()
    func stopEventHandling()
    func refresh(from snapshot: AppSnapshot)
}

@MainActor
extension SettingsSectionController {
    func startEventHandling() {}
    func stopEventHandling() {}
}

@MainActor
private final class ClickOutsideCatcher: NSView {
    var onClick: (() -> Void)?
    weak var exclusionView: NSView?

    override func mouseDown(with event: NSEvent) {
        guard window?.attachedSheet == nil else { return }
        if let exclusionView {
            let point = convert(event.locationInWindow, from: nil)
            guard !exclusionView.frame.contains(point) else { return }
        }
        onClick?()
    }
}

@MainActor
final class SettingsViewController: NSViewController {
    enum Tab: Int, CaseIterable {
        case diff
        case fileWatching
        case openInApp
        case foldersAndRepositories

        var title: String {
            switch self {
            case .diff: return "Diff"
            case .fileWatching: return "File Watching"
            case .openInApp: return "Open In App"
            case .foldersAndRepositories: return "Folders && Repositories"
            }
        }

        var symbolName: String {
            switch self {
            case .diff: return "character.cursor.ibeam"
            case .fileWatching: return "eye"
            case .openInApp: return "app.gift"
            case .foldersAndRepositories: return "folder"
            }
        }
    }

    private let coordinator: AppCoordinator
    private let downloadManager: RepositoryDownloadManager
    private let onClose: () -> Void
    private let diffController: DiffSettingsViewController
    private let fileWatchingController: FileWatchingSettingsViewController
    private let openApplicationController: OpenApplicationSettingsViewController
    private let sourcesController: RepositorySourcesSettingsViewController
    private var latestSnapshot: AppSnapshot
    private var snapshotHandlerID: UUID?
    private var keyMonitor: Any?
    private var isClosed = false
    private var selectedTab: Tab = .diff {
        didSet { tabSelectionChanged() }
    }
    private var tabButtons: [NSButton] = []

    private var sectionControllers: [Tab: NSViewController] {
        [
            .diff: diffController,
            .fileWatching: fileWatchingController,
            .openInApp: openApplicationController,
            .foldersAndRepositories: sourcesController,
        ]
    }

    private var eventHandlers: [SettingsSectionController] {
        [diffController, fileWatchingController, openApplicationController, sourcesController]
    }

    init(
        coordinator: AppCoordinator,
        downloadManager: RepositoryDownloadManager? = nil,
        onClose: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.downloadManager = downloadManager ?? RepositoryDownloadManager(coordinator: coordinator)
        self.onClose = onClose
        latestSnapshot = coordinator.snapshot
        diffController = DiffSettingsViewController(coordinator: coordinator)
        fileWatchingController = FileWatchingSettingsViewController(coordinator: coordinator)
        openApplicationController = OpenApplicationSettingsViewController(coordinator: coordinator)
        sourcesController = RepositorySourcesSettingsViewController(
            coordinator: coordinator,
            downloadManager: self.downloadManager
        )
        super.init(nibName: nil, bundle: nil)
        sectionControllers.values.forEach(addChild)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let overlay = ClickOutsideCatcher()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.onClick = { [weak self] in self?.close() }

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(calibratedWhite: 0.30, alpha: 1).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.7
        card.layer?.shadowRadius = 16
        card.layer?.shadowOffset = CGSize(width: 0, height: -4)
        card.translatesAutoresizingMaskIntoConstraints = false
        overlay.exclusionView = card

        let sidebar = buildSidebar()
        let contentHolder = NSView()
        contentHolder.translatesAutoresizingMaskIntoConstraints = false
        for (tab, controller) in sectionControllers {
            let sectionView = controller.view
            sectionView.translatesAutoresizingMaskIntoConstraints = false
            sectionView.isHidden = tab != selectedTab
            contentHolder.addSubview(sectionView)
            NSLayoutConstraint.activate([
                sectionView.topAnchor.constraint(equalTo: contentHolder.topAnchor),
                sectionView.leadingAnchor.constraint(equalTo: contentHolder.leadingAnchor),
                sectionView.trailingAnchor.constraint(equalTo: contentHolder.trailingAnchor),
                sectionView.bottomAnchor.constraint(equalTo: contentHolder.bottomAnchor),
            ])
        }

        overlay.addSubview(card)
        card.addSubview(sidebar)
        card.addSubview(contentHolder)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: card.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 170),
            contentHolder.topAnchor.constraint(equalTo: card.topAnchor),
            contentHolder.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentHolder.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            contentHolder.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 640),
            card.heightAnchor.constraint(equalToConstant: 460),
        ])
        view = overlay
        refresh(from: latestSnapshot)
    }

    private func buildSidebar() -> NSView {
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.black.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Settings")
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        titleLabel.textColor = .white
        let stack = NSStackView(views: [titleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 10)
        for tab in Tab.allCases {
            let button = NSButton(
                title: tab.title.replacingOccurrences(of: "&&", with: "&"),
                target: self,
                action: #selector(selectTab(_:))
            )
            button.isBordered = false
            button.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.identifier = NSUserInterfaceItemIdentifier(tab.title)
            tabButtons.append(button)
            stack.addArrangedSubview(button)
        }
        highlightSelectedTab()
        sidebar.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
        ])
        return sidebar
    }

    @objc func selectTab(_ sender: NSButton) {
        guard let title = sender.identifier?.rawValue,
              let tab = Tab.allCases.first(where: { $0.title == title }) else { return }
        selectedTab = tab
    }

    private func tabSelectionChanged() {
        highlightSelectedTab()
        for (tab, controller) in sectionControllers {
            controller.view.isHidden = tab != selectedTab
        }
    }

    private func highlightSelectedTab() {
        for button in tabButtons {
            let isSelected = button.identifier?.rawValue == selectedTab.title
            button.contentTintColor = isSelected ? .white : NSColor(calibratedWhite: 0.62, alpha: 1)
        }
    }

    func refresh(from snapshot: AppSnapshot) {
        latestSnapshot = snapshot
        eventHandlers.forEach { $0.refresh(from: snapshot) }
    }

    func startEventHandling() {
        guard snapshotHandlerID == nil else { return }
        eventHandlers.forEach { $0.startEventHandling() }
        snapshotHandlerID = coordinator.addSnapshotHandler { [weak self] snapshot in
            self?.refresh(from: snapshot)
        }
        refresh(from: coordinator.snapshot)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.view.window?.attachedSheet == nil else { return event }
            self?.close()
            return nil
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let snapshotHandlerID {
            coordinator.removeSnapshotHandler(snapshotHandlerID)
            self.snapshotHandlerID = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        eventHandlers.forEach { $0.stopEventHandling() }
        view.removeFromSuperview()
        removeFromParent()
        onClose()
    }

    deinit {
        if let snapshotHandlerID {
            MainActor.assumeIsolated {
                coordinator.removeSnapshotHandler(snapshotHandlerID)
            }
        }
    }

    #if DEBUG
    var selectedTabForTesting: Tab { selectedTab }
    func sectionControllerForTesting(_ tab: Tab) -> NSViewController? { sectionControllers[tab] }
    #endif
}
