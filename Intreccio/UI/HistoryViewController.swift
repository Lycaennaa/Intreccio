import AppKit

@MainActor
final class HistoryViewController: NSViewController,
  NSTableViewDataSource,
  NSTableViewDelegate,
  NSMenuDelegate {
  private let coordinator: AppCoordinator
  private let headerView = HistoryHeaderView()
  private let tableView = NSTableView()
  private let scrollView = NSScrollView()
  private let stateLabel = NSTextField(labelWithString: "Select a repository")
  private var commits: [Commit] = []
  private var repositoryID: UUID?
  private var renderedHistory: SelectedHistoryState?
  private var renderedSearchText: String?
  private var suppressSelectionChange = false
  private var renderedContentMode = false
  private let branchFileBrowserController: BranchFileBrowserViewController
  private var openWorktreeTask: Task<Void, Never>?
  private var branchRefreshTask: Task<Void, Never>?
  var onBranchFilePresentationChange: (() -> Void)?
  var isBrowsingBranchFiles: Bool { headerView.isBrowsingFiles }
  var branchFilePresentation: BranchFileInspectorPresentation {
    branchFileBrowserController.presentation
  }
  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    branchFileBrowserController = BranchFileBrowserViewController(coordinator: coordinator)
    super.init(nibName: nil, bundle: nil)
    branchFileBrowserController.onPresentationChange = { [weak self] in
      self?.branchFileBrowserDidChange()
    }
    headerView.onBranchSelection = { [weak self] in self?.coordinator.setHistoryBranch($0) }
    headerView.onBranchMenuOpening = { [weak self] in self?.refreshBranchesWhenPickerOpens() }
    headerView.onScopeSelection = { [weak self] in self?.coordinator.setHistoryScope($0) }
    headerView.onSearchTextChange = { [weak self] in self?.coordinator.setSearchText($0) }
    headerView.onContentSelection = { [weak self] in self?.setContentMode($0) }
    headerView.onOpenWorktree = { [weak self] in self?.openWorktree($0) }
    headerView.onRetryHistory = { [weak self] in self?.coordinator.retryHistoryPage() }
  }
  private func branchFileBrowserDidChange() {
    if isBrowsingBranchFiles {
      headerView.updateSummary(
        headerView.historySummary(
          for: coordinator.selectedHistoryState,
          filteredCommitCount: commits.count,
          fileCount: branchFileBrowserController.fileCount,
          visibleFileCount: branchFileBrowserController.visibleFileCount
        )
      )
    }
    onBranchFilePresentationChange?()
  }
  private func openWorktree(_ branchReference: String?) {
    guard openWorktreeTask == nil else { return }
    headerView.setWorktreeOpening(true)
    let coordinator = self.coordinator
    openWorktreeTask = Task { [weak self, coordinator] in
      await coordinator.openHistoryBranchWorktree(branchReference)
      guard !Task.isCancelled, let self else { return }
      openWorktreeTask = nil
      headerView.setWorktreeOpening(false)
    }
  }

  private func refreshBranchesWhenPickerOpens() {
    branchRefreshTask?.cancel()
    let coordinator = self.coordinator
    branchRefreshTask = Task { [weak self, coordinator] in
      await coordinator.refreshHistoryBranches()
      guard !Task.isCancelled, let self else { return }
      branchRefreshTask = nil
    }
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    MainActor.assumeIsolated {
      openWorktreeTask?.cancel()
      branchRefreshTask?.cancel()
    }
  }

  override func loadView() {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.cgColor
    container.setAccessibilityLabel("History")
    addChild(branchFileBrowserController)
    let branchFileView = branchFileBrowserController.view
    branchFileView.isHidden = true
    configureTableView()
    configureScrollView()
    configureLayout(in: container, branchFileView: branchFileView)
    view = container
  }

  private func configureTableView() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HistoryItem"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.backgroundColor = .black
    tableView.rowHeight = 48
    tableView.dataSource = self
    tableView.delegate = self
    tableView.setAccessibilityLabel("Commits")
    let contextMenu = NSMenu()
    contextMenu.delegate = self
    tableView.menu = contextMenu
  }

  private func configureScrollView() {
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .black
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollViewBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
    stateLabel.textColor = .secondaryLabelColor
    stateLabel.alignment = .center
    stateLabel.maximumNumberOfLines = 4
  }

  private func configureLayout(in container: NSView, branchFileView: NSView) {
    for child in [headerView, scrollView, branchFileView, stateLabel] {
      child.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(child)
    }
    NSLayoutConstraint.activate([
      headerView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
      headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      headerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      branchFileView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 8),
      branchFileView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      branchFileView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      branchFileView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      stateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      stateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
      stateLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
      stateLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20)
    ])
  }
  func reload(_ snapshot: AppSnapshot? = nil) {
    guard isViewLoaded else { return }
    let snapshot = snapshot ?? coordinator.snapshot
    guard snapshot.state.uiState.mode == .history else { return }
    guard let selectedID = snapshot.state.uiState.selectedRepoID,
      let repository = snapshot.repositories.first(where: { $0.id == selectedID })
    else {
      repositoryID = nil
      showState("Select a repository", summary: "History")
      return
    }
    if case .unavailable(let reason) = repository.availability {
      repositoryID = selectedID
      showState(reason, summary: repository.displayName)
      return
    }
    refreshHistoryView(snapshot, repository: repository, repositoryID: selectedID)
  }

  private func refreshHistoryView(
    _ snapshot: AppSnapshot, repository: RepoDescriptor, repositoryID: UUID
  ) {
    let history = snapshot.selectedSession.historyState
    scrollView.isHidden = isBrowsingBranchFiles
    branchFileBrowserController.view.isHidden = !isBrowsingBranchFiles
    if isBrowsingBranchFiles {
      branchFileBrowserController.reload(
        repository: repository.canonicalURL,
        repositoryID: repositoryID,
        history: history,
        searchText: snapshot.state.uiState.searchText
      )
    }
    let searchText = snapshot.state.uiState.searchText
    let filteredCommits = history.filteredCommits(searchText: searchText)
    guard needsHistoryRender(repositoryID, history, filteredCommits, searchText) else { return }
    let selectedObjectID =
      self.repositoryID == repositoryID && !isBrowsingBranchFiles
      ? selectedCommit?.objectID
      : nil
    self.repositoryID = repositoryID
    commits = filteredCommits
    renderedHistory = history
    renderedSearchText = searchText
    renderedContentMode = isBrowsingBranchFiles
    headerView.render(
      history: history,
      scope: snapshot.selectedSession.historyScope,
      summary: headerView.historySummary(
        for: history,
        filteredCommitCount: commits.count,
        fileCount: branchFileBrowserController.fileCount,
        visibleFileCount: branchFileBrowserController.visibleFileCount
      ),
      searchText: searchText
    )
    renderHistoryRows(selectedObjectID: selectedObjectID)
    renderHistoryState(history, searchText: searchText)
    if selectedCommit == nil, snapshot.selectedSession.commitState.commit != nil {
      coordinator.selectCommit(nil)
    }
    requestNextPageIfNeeded()
  }

  private func needsHistoryRender(
    _ repositoryID: UUID,
    _ history: SelectedHistoryState,
    _ filteredCommits: [Commit],
    _ searchText: String
  ) -> Bool {
    self.repositoryID != repositoryID
      || commits != filteredCommits
      || renderedHistory != history
      || renderedSearchText != searchText
      || renderedContentMode != isBrowsingBranchFiles
  }

  private func renderHistoryRows(selectedObjectID: String?) {
    tableView.setAccessibilityLabel("Commits")
    suppressSelectionChange = true
    tableView.reloadData()
    if let selectedObjectID,
      let row = commits.firstIndex(where: { $0.objectID == selectedObjectID }) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else {
      tableView.deselectAll(nil)
    }
    suppressSelectionChange = false
  }

  private func renderHistoryState(_ history: SelectedHistoryState, searchText: String) {
    guard !isBrowsingBranchFiles else {
      stateLabel.isHidden = true
      return
    }
    switch history.phase {
    case .failed(let failure):
      stateLabel.stringValue =
        failure.title + "\n" + failure.recoverySuggestion + "\n\n" + failure.details
      stateLabel.isSelectable = true
      stateLabel.isHidden = false
    case .loading where commits.isEmpty:
      showListState("Loading history")
    default:
      if history.commits.isEmpty, history.reachedEnd {
        showListState(history.scope.emptyMessage)
      } else if commits.isEmpty, !searchText.isEmpty {
        showListState("No loaded commits match the filter")
      } else {
        stateLabel.isHidden = true
      }
    }
  }

  func focusSearch() {
    _ = view
    view.window?.makeFirstResponder(headerView.searchField)
  }

  func focusCommitList() {
    _ = view
    view.window?.makeFirstResponder(tableView)
  }
  private func setContentMode(_ isFiles: Bool) {
    if isFiles {
      tableView.deselectAll(nil)
      coordinator.selectCommit(nil)
      coordinator.loadNextHistoryPage()
    }
    renderedContentMode = !isFiles
    reload(coordinator.snapshot)
    onBranchFilePresentationChange?()
  }

  private var selectedCommit: Commit? {
    guard !isBrowsingBranchFiles else { return nil }
    let row = tableView.selectedRow
    return commits.indices.contains(row) ? commits[row] : nil
  }

  private func showState(_ message: String, summary: String) {
    branchFileBrowserController.clear(message: message)
    commits = []
    headerView.clearRepositoryContext()
    headerView.retryHistoryButton.isHidden = true
    headerView.updateSummary(summary)
    showListState(message)
    suppressSelectionChange = true
    tableView.reloadData()
    suppressSelectionChange = false
    if coordinator.selectedCommitState.commit != nil { coordinator.selectCommit(nil) }
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    commits.count
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !suppressSelectionChange else { return }
    coordinator.selectCommit(selectedCommit)
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    guard !isBrowsingBranchFiles,
      coordinator.selectedHistoryState.selectedBranchRef == nil,
      commits.indices.contains(tableView.clickedRow)
    else { return }
    let commit = commits[tableView.clickedRow]
    let item = NSMenuItem(
      title: "Amend Commit", action: #selector(amendCommit(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = commit
    item.isEnabled =
      coordinator.mutationState != .running
      && coordinator.selectedHistoryState.headObjectID == commit.objectID
      && commit.subjectMetadata.completeness.isComplete
      && commit.bodyMetadata.completeness.isComplete
    if !commit.subjectMetadata.completeness.isComplete
      || !commit.bodyMetadata.completeness.isComplete {
      item.toolTip = "Commit message is truncated; reload history before amending."
    }
    menu.addItem(item)
  }

  @objc private func amendCommit(_ sender: NSMenuItem) {
    guard let commit = sender.representedObject as? Commit else { return }
    coordinator.beginAmending(commit)
  }

  @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
    requestNextPageIfNeeded()
  }

  private func requestNextPageIfNeeded() {
    guard !isBrowsingBranchFiles else { return }
    requestNextHistoryPageIfNeeded()
  }

  private func requestNextHistoryPageIfNeeded() {
    guard
      coordinator.state.uiState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !coordinator.selectedHistoryState.reachedEnd,
      !coordinator.selectedHistoryState.reachedLimit
    else { return }
    let visibleMaxY = scrollView.contentView.bounds.maxY
    if commits.isEmpty || visibleMaxY >= tableView.bounds.maxY - 160 {
      coordinator.loadNextHistoryPage()
    }
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()
}

extension HistoryViewController {
  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    if row >= commits.count - 3 { requestNextHistoryPageIfNeeded() }
    let commit = commits[row]
    return HistoryCommitRowView.make(
      commit: commit,
      dateFormatter: Self.dateFormatter,
      notOnUpstream: renderedHistory?.notOnUpstreamObjectIDs?.contains(commit.objectID) == true
    )
  }
}
private extension HistoryViewController {
  func showListState(_ message: String) {
    stateLabel.stringValue = message
    stateLabel.isSelectable = false
    stateLabel.isHidden = false
  }
}
