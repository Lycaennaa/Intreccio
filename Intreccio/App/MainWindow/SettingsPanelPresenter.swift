import AppKit

@MainActor
final class SettingsPanelPresenter {
    private static let minimumContentHeight: CGFloat = 460

    private let coordinator: AppCoordinator
    private let contentController: MainWindowContentController
    private let geometryController: MainWindowGeometryController
    private let downloadManager: RepositoryDownloadManager
    private weak var window: NSWindow?
    private var settingsController: SettingsViewController?
    private(set) var presentedPanel: NSPanel?
    private var panelSizeConstraints: (width: NSLayoutConstraint, height: NSLayoutConstraint)?
    private var minimumHeightConstraint: NSLayoutConstraint?
    private var openingFrame: NSRect?
    private var presentationPending = false
    private var isTerminating = false

    init(
        coordinator: AppCoordinator,
        contentController: MainWindowContentController,
        geometryController: MainWindowGeometryController,
        window: NSWindow,
        downloadManager: RepositoryDownloadManager? = nil
    ) {
        self.coordinator = coordinator
        self.contentController = contentController
        self.geometryController = geometryController
        self.window = window
        self.downloadManager = downloadManager ?? RepositoryDownloadManager(coordinator: coordinator)
    }

    func present() {
        guard !isTerminating, settingsController == nil else { return }
        guard coordinator.hasLoadedState, geometryController.hasRestoredState else {
            presentationPending = true
            return
        }
        guard let window else { return }
        openingFrame = window.frame
        let minimumHeightConstraint = contentController.view.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumContentHeight
        )
        minimumHeightConstraint.isActive = true
        self.minimumHeightConstraint = minimumHeightConstraint
        window.contentView?.layoutSubtreeIfNeeded()

        let settingsFrame = contentFrame(for: window)
        let panel = NSPanel(
            contentRect: settingsFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.appearance = window.appearance
        panel.level = window.level
        panel.hidesOnDeactivate = false

        let controller = SettingsViewController(
            coordinator: coordinator,
            downloadManager: downloadManager
        ) { [weak self, weak panel] in
            self?.finishPresentation(panel: panel)
        }
        controller.startEventHandling()

        let panelContent = NSView(frame: NSRect(origin: .zero, size: settingsFrame.size))
        panelContent.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = panelContent.widthAnchor.constraint(equalToConstant: settingsFrame.width)
        let heightConstraint = panelContent.heightAnchor.constraint(equalToConstant: settingsFrame.height)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        panelSizeConstraints = (width: widthConstraint, height: heightConstraint)
        panel.contentView = panelContent
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.frame = panelContent.bounds
        controller.view.autoresizingMask = [.width, .height]
        panelContent.addSubview(controller.view)
        panel.setFrame(settingsFrame, display: false)

        window.addChildWindow(panel, ordered: .above)
        presentedPanel = panel
        settingsController = controller
        panel.makeKeyAndOrderFront(nil)
    }

    func presentIfPendingAndReady() {
        guard presentationPending,
              coordinator.hasLoadedState,
              geometryController.hasRestoredState else { return }
        presentationPending = false
        present()
    }

    func updateFrame() {
        guard let presentedPanel, let window else { return }
        let frame = contentFrame(for: window)
        panelSizeConstraints?.width.constant = frame.width
        panelSizeConstraints?.height.constant = frame.height
        presentedPanel.setFrame(frame, display: true)
    }

    func dismiss() {
        guard presentedPanel?.attachedSheet == nil else { return }
        settingsController?.close()
    }

    func prepareForTermination() {
        isTerminating = true
        presentationPending = false
        if presentedPanel?.attachedSheet == nil {
            dismiss()
        } else if let openingFrame {
            geometryController.persist(frame: openingFrame)
        }
    }

    func resumeAfterFailedTermination() {
        isTerminating = false
    }

    private func finishPresentation(panel: NSPanel?) {
        if let panel {
            window?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        presentedPanel = nil
        settingsController = nil
        panelSizeConstraints = nil
        minimumHeightConstraint?.isActive = false
        minimumHeightConstraint = nil
        let frame = openingFrame
        openingFrame = nil
        if let frame, let window {
            window.setFrame(frame, display: true)
            geometryController.persistCurrentState()
        }
        if !isTerminating { window?.makeKeyAndOrderFront(nil) }
    }

    private func contentFrame(for window: NSWindow) -> NSRect {
        window.contentRect(forFrameRect: window.frame)
    }
}
