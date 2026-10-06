import AppKit

@MainActor
final class MainWindowGeometryController: NSObject {
    private let coordinator: AppCoordinator
    private let contentController: MainWindowContentController
    private weak var window: NSWindow?
    private(set) var hasRestoredState = false
    private var isRestoringState = false
    private var preRestoreAdjustments = (sidebar: false, list: false)
    private var initialPaneWidths: (sidebar: CGFloat, list: CGFloat)?
    private var lastPanePositions: (sidebar: CGFloat, list: CGFloat)?
    private var lastWindowContentSize: NSSize?

    init(coordinator: AppCoordinator, contentController: MainWindowContentController) {
        self.coordinator = coordinator
        self.contentController = contentController
    }

    func attach(to window: NSWindow) {
        self.window = window
        window.contentView?.layoutSubtreeIfNeeded()
        initialPaneWidths = contentController.paneWidths
        lastPanePositions = contentController.panePositions
        lastWindowContentSize = window.contentView?.bounds.size
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize),
            name: NSSplitView.didResizeSubviewsNotification,
            object: contentController.splitView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func restoreIfReady() -> Bool {
        guard coordinator.hasLoadedState, !hasRestoredState else { return false }
        let adjustments = preRestoreAdjustments
        isRestoringState = true
        if let frame = PersistedUIState.sanitizedWindowFrame(coordinator.state.uiState.windowFrame) {
            window?.setFrame(NSRectFromString(frame), display: false)
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        contentController.restorePaneWidths(
            sidebarWidth: coordinator.state.uiState.sidebarWidth,
            listWidth: coordinator.state.uiState.changesListWidth.map { CGFloat($0) },
            preserving: adjustments
        )
        window?.contentView?.layoutSubtreeIfNeeded()
        hasRestoredState = true
        isRestoringState = false
        lastPanePositions = contentController.panePositions
        lastWindowContentSize = window?.contentView?.bounds.size
        if adjustments.sidebar || adjustments.list { persistCurrentState() }
        return true
    }

    func windowDidMoveOrResize() {
        persistCurrentState()
    }

    func persistCurrentState() {
        guard hasRestoredState, !isRestoringState, let window else { return }
        persist(frame: window.frame)
    }

    func persist(frame: NSRect) {
        let widths = contentController.paneWidths
        coordinator.setWindowState(
            frame: NSStringFromRect(frame),
            sidebarWidth: widths.sidebar,
            changesListWidth: widths.list
        )
    }

    @objc private func splitViewDidResize(_ notification: Notification) {
        if !hasRestoredState && !isRestoringState { recordPreRestoreAdjustment() }
        persistCurrentState()
    }

    private func recordPreRestoreAdjustment() {
        let windowContentSize = window?.contentView?.bounds.size
        if let previousSize = lastWindowContentSize,
           let windowContentSize,
           abs(windowContentSize.width - previousSize.width) > 1
            || abs(windowContentSize.height - previousSize.height) > 1 {
            initialPaneWidths = contentController.paneWidths
            lastPanePositions = contentController.panePositions
            lastWindowContentSize = windowContentSize
            return
        }
        guard let initialPaneWidths,
              let previous = lastPanePositions,
              let currentPositions = contentController.panePositions else {
            lastPanePositions = contentController.panePositions
            lastWindowContentSize = windowContentSize
            return
        }
        let currentWidths = contentController.paneWidths
        let sidebarChanged = abs(currentWidths.sidebar - initialPaneWidths.sidebar) > 1
        let listChanged = abs(currentWidths.list - initialPaneWidths.list) > 1
        if sidebarChanged && !listChanged {
            preRestoreAdjustments.sidebar = true
        } else if listChanged && !sidebarChanged {
            preRestoreAdjustments.list = true
        } else if sidebarChanged && listChanged {
            if abs(currentPositions.sidebar - previous.sidebar) > 1 {
                preRestoreAdjustments.sidebar = true
            } else if abs(currentPositions.list - previous.list) > 1 {
                preRestoreAdjustments.list = true
            }
        }
        lastPanePositions = currentPositions
        lastWindowContentSize = windowContentSize
    }
}
