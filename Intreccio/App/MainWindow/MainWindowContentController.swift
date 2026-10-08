import AppKit

@MainActor
private final class ModeViewController: NSViewController {
  private let initialViewController: NSViewController
  private var currentViewController: NSViewController?

  init(initialViewController: NSViewController) {
    self.initialViewController = initialViewController
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func loadView() {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.cgColor
    view = container
    show(initialViewController)
  }

  func show(_ viewController: NSViewController) {
    _ = view
    guard currentViewController !== viewController else { return }
    currentViewController?.view.removeFromSuperview()
    currentViewController?.removeFromParent()
    addChild(viewController)
    viewController.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(viewController.view)
    NSLayoutConstraint.activate([
      viewController.view.topAnchor.constraint(equalTo: view.topAnchor),
      viewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      viewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      viewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    currentViewController = viewController
  }
}

@MainActor
final class MainWindowContentController: NSSplitViewController {
  private let coordinator: AppCoordinator
  private let sidebarController: RepoSidebarViewController
  private let changesController: ChangesViewController
  private let historyController: HistoryViewController
  private let modeController: ModeViewController
  private let diffInspectorController: DiffInspectorViewController
  private let branchFileInspectorController: BranchFileInspectorViewController
  private let detailModeController: ModeViewController
  private let sidebarItem: NSSplitViewItem
  private let listItem: NSSplitViewItem
  var onRefreshRequested: (() -> Void)?

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    sidebarController = RepoSidebarViewController(coordinator: coordinator)
    changesController = ChangesViewController(coordinator: coordinator)
    historyController = HistoryViewController(coordinator: coordinator)
    modeController = ModeViewController(initialViewController: changesController)
    diffInspectorController = DiffInspectorViewController()
    branchFileInspectorController = BranchFileInspectorViewController()
    detailModeController = ModeViewController(initialViewController: diffInspectorController)
    sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
    listItem = NSSplitViewItem(viewController: modeController)
    super.init(nibName: nil, bundle: nil)

    historyController.onBranchFilePresentationChange = { [weak self] in
      guard let self, coordinator.state.uiState.mode == .history else { return }
      renderDetailPane(coordinator.snapshot)
    }
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.cgColor
    splitView.dividerStyle = .thin
    splitView.autosaveName = "MainWindowSplitView"
    sidebarItem.minimumThickness = 200
    sidebarItem.maximumThickness = 360
    sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 270)
    listItem.minimumThickness = 260
    listItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

    let detailItem = NSSplitViewItem(viewController: detailModeController)
    detailItem.minimumThickness = 320
    detailItem.holdingPriority = .defaultLow
    addSplitViewItem(sidebarItem)
    addSplitViewItem(listItem)
    addSplitViewItem(detailItem)
    configureDiffRequests()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = .black
    window.isOpaque = true
    window.titlebarAppearsTransparent = true
    window.contentViewController = self
    window.center()
    return window
  }

  var paneWidths: (sidebar: CGFloat, list: CGFloat) {
    (sidebarController.view.frame.width, modeController.view.frame.width)
  }

  var panePositions: (sidebar: CGFloat, list: CGFloat)? {
    guard let sidebarPane = splitPane(containing: sidebarController.view),
      let listPane = splitPane(containing: modeController.view)
    else { return nil }
    return (sidebarPane.frame.maxX, listPane.frame.maxX)
  }

  func restorePaneWidths(
    sidebarWidth: CGFloat,
    listWidth: CGFloat?,
    preserving adjustments: (sidebar: Bool, list: Bool)
  ) {
    if !adjustments.sidebar,
      let sidebarPane = splitPane(containing: sidebarController.view) {
      let width = min(sidebarItem.maximumThickness, max(sidebarItem.minimumThickness, sidebarWidth))
      splitView.setPosition(
        sidebarPane.frame.maxX + width - sidebarController.view.frame.width,
        ofDividerAt: 0
      )
      splitView.layoutSubtreeIfNeeded()
    }
    if !adjustments.list,
      let listWidth,
      let listPane = splitPane(containing: modeController.view) {
      let width = max(listItem.minimumThickness, listWidth)
      splitView.setPosition(
        listPane.frame.maxX + width - modeController.view.frame.width,
        ofDividerAt: 1
      )
    }
  }

  func refresh(_ snapshot: AppSnapshot) {
    diffInspectorController.applyDisplaySettings(
      fontSize: snapshot.state.uiState.diffFontSize,
      showWhitespace: snapshot.state.uiState.showWhitespaceInDiff
    )
    sidebarController.reload(snapshot)
    let mode = snapshot.state.uiState.mode
    if mode == .changes {
      modeController.show(changesController)
      changesController.reload(snapshot)
    } else {
      modeController.show(historyController)
      historyController.reload(snapshot)
    }
    let paths = changesController.selectedGitPaths
    let selectedID = snapshot.state.uiState.selectedRepoID
    renderDetailPane(snapshot)
    if mode == .changes,
      !paths.isEmpty,
      snapshot.selectedSession.diffState == .idle,
      let selectedID,
      snapshot.runtime.refreshStates[selectedID]?.status != nil {
      coordinator.requestSelectedDiff(
        changes: changesController.selectedChanges,
        kind: diffInspectorController.kind
      )
    }
  }

  private func renderDetailPane(_ snapshot: AppSnapshot) {
    let mode = snapshot.state.uiState.mode
    if mode == .history, historyController.isBrowsingBranchFiles {
      detailModeController.show(branchFileInspectorController)
      branchFileInspectorController.render(historyController.branchFilePresentation)
      return
    }
    let paths = changesController.selectedGitPaths
    let selectedID = snapshot.state.uiState.selectedRepoID
    detailModeController.show(diffInspectorController)
    diffInspectorController.render(
      mode: mode,
      hasRepository: snapshot.repositories.contains {
        $0.id == selectedID && $0.availability == .available
      },
      hasSelection: !paths.isEmpty,
      state: snapshot.selectedSession.diffState,
      commitState: snapshot.selectedSession.commitState,
      diffGeneration: snapshot.selectedSession.diffGeneration,
      commitGeneration: snapshot.selectedSession.commitGeneration,
      repositoryID: selectedID,
      selectedPaths: paths
    )
  }

  func focusSearch() {
    if coordinator.state.uiState.mode == .history {
      historyController.focusSearch()
    } else {
      sidebarController.focusSearch()
    }
  }

  func focusDiffSearch() { diffInspectorController.focusSearch() }
  func nextDiffHunk() { diffInspectorController.moveToNextHunk() }
  func previousDiffHunk() { diffInspectorController.moveToPreviousHunk() }
  func nextDiffFile() { diffInspectorController.moveToNextFile() }
  func previousDiffFile() { diffInspectorController.moveToPreviousFile() }

  var canNavigateDiffHunks: Bool { diffInspectorController.canNavigateDiffHunks }
  var canNavigateDiffFiles: Bool { diffInspectorController.canNavigateDiffFiles }
  var canSearchDiff: Bool { diffInspectorController.canSearchDiff }

  func focusRepositoryList() { sidebarController.focusRepositoryList() }
  func focusChanges() { changesController.focusChangeList() }
  func focusHistory() { historyController.focusCommitList() }
  func stageSelected(_ sender: Any?) { changesController.mutationController.stageSelected(sender) }
  func stageAll(_ sender: Any?) { changesController.mutationController.stageAll(sender) }
  func unstageSelected(_ sender: Any?) {
    changesController.mutationController.unstageSelected(sender)
  }
  func unstageAll(_ sender: Any?) { changesController.mutationController.unstageAll(sender) }
  func stashChanges(_ sender: Any?) { changesController.mutationController.stashChanges(sender) }
  func restoreLatestStash(_ sender: Any?) {
    changesController.mutationController.restoreLatestStash(sender)
  }
  func commit(_ sender: Any?) { changesController.commitCompositionController.commit(sender) }

  var canStageSelected: Bool { changesController.mutationController.canStageSelected }
  var canStageAll: Bool { changesController.mutationController.canStageAll }
  var canUnstageSelected: Bool { changesController.mutationController.canUnstageSelected }
  var canUnstageAll: Bool { changesController.mutationController.canUnstageAll }
  var canStash: Bool { changesController.mutationController.canStash }
  var canRestoreStash: Bool { changesController.mutationController.canRestoreStash }
  var canCommit: Bool { changesController.commitCompositionController.canCommit }

  func cancelRendering() -> Task<Void, Never>? { diffInspectorController.cancelRendering() }
  func cancelSidebarOperations() -> [Task<Void, Never>] {
    sidebarController.cancelOperationsForTermination()
  }
  func resumeSidebarOperations() { sidebarController.resumeOperationsAfterFailedTermination() }

  private func configureDiffRequests() {
    changesController.onSelectionChange = { [weak self] paths in
      guard let self, coordinator.state.uiState.mode == .changes else { return }
      if paths.isEmpty {
        coordinator.clearSelectedDiff()
        onRefreshRequested?()
      } else {
        coordinator.requestSelectedDiff(
          changes: changesController.selectedChanges,
          kind: diffInspectorController.kind
        )
      }
    }
    diffInspectorController.onWhitespaceChange = { [weak coordinator] enabled in
      coordinator?.setShowWhitespaceInDiff(enabled)
    }
    diffInspectorController.onFileAction = { [weak self] action in
      self?.performDiffFileAction(action)
    }
    diffInspectorController.onRetryUnavailableFile = { [weak self] fileID in
      self?.retryUnavailableDiffFile(fileID)
    }
  }

  private func retryUnavailableDiffFile(_ fileID: DiffFileID) {
    guard coordinator.state.uiState.mode == .changes,
      let model = diffInspectorController.currentPresentationModel,
      !diffInspectorController.presentationIsRetained,
      let file = model.file(with: fileID),
      case .content(.unavailable(let reason)) = file.state,
      reason.isRetryable,
      !changesController.selectedChanges.isEmpty
    else { return }
    coordinator.requestSelectedDiff(
      changes: changesController.selectedChanges,
      kind: diffInspectorController.kind
    )
  }

  private func performDiffFileAction(_ action: DiffFileAction) {
    let applicationActions = changesController.applicationActionsController
    switch action {
    case .open(let path):
      guard path.isFileActionAddressable,
        let target = applicationActions.makeFileOpenAction(gitPaths: [path], applicationURL: nil)
      else {
        applicationActions.presentFileOpenError(
          applicationName: "Default Application",
          paths: [path.displayString],
          description: "The selected path cannot be opened safely."
        )
        return
      }
      let applicationName =
        coordinator.state.uiState.defaultOpenApplicationURL.map {
          LaunchServicesApplicationService.shared.applicationName(for: $0)
        } ?? "Default Application"
      applicationActions.openFiles(target, applicationName: applicationName)
    case .reveal(let path):
      guard path.isFileActionAddressable,
        let selection = applicationActions.makeFileRevealSelection(gitPaths: [path]),
        applicationActions.revealFiles(selection)
      else {
        applicationActions.presentFileOpenError(
          applicationName: "Finder",
          paths: [path.displayString],
          description: "The selected path changed or cannot be revealed safely."
        )
        return
      }
    }
  }

  private func splitPane(containing view: NSView) -> NSView? {
    var pane = view
    while let superview = pane.superview {
      if superview === splitView { return pane }
      pane = superview
    }
    return nil
  }
}
