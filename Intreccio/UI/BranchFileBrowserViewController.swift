import AppKit

@MainActor
final class BranchFileBrowserViewController: NSViewController, NSTableViewDataSource,
  NSTableViewDelegate {
  private let coordinator: AppCoordinator
  private let tableView = NSTableView()
  private let scrollView = NSScrollView()
  private let stateLabel = NSTextField(labelWithString: "Loading branch files")
  private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
  private var repositoryURL: URL?
  private var repositoryID: UUID?
  private var history = SelectedHistoryState()
  private var searchText = ""
  private var entries: [GitTreeEntry] = []
  private var treeObjectID: String?
  private var treeRepositoryID: UUID?
  private var treeRepositoryURL: URL?
  private var treeTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var treeGeneration: UInt64 = 0
  private var previewGeneration: UInt64 = 0
  private var selectedEntry: GitTreeEntry?
  private var previewEntry: GitTreeEntry?
  private var preview: GitBlobPreview?
  private var previewFailure: String?
  private var treeFailure: String?
  private var canRetryTree = false
  private var suppressSelectionChange = false
  private var isLoadingTree = false
  var onPresentationChange: (() -> Void)?

  var fileCount: Int { entries.count }
  var visibleFileCount: Int { visibleEntries.count }
  var presentation: BranchFileInspectorPresentation { makePresentation() }

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  deinit {
    MainActor.assumeIsolated {
      treeTask?.cancel()
      previewTask?.cancel()
    }
  }

  override func loadView() {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.cgColor
    container.setAccessibilityLabel("Committed branch files")

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("BranchFile"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.backgroundColor = .black
    tableView.rowHeight = 28
    tableView.dataSource = self
    tableView.delegate = self
    tableView.setAccessibilityLabel("Files at branch tip")

    scrollView.drawsBackground = true
    scrollView.backgroundColor = .black
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true

    stateLabel.textColor = .secondaryLabelColor
    stateLabel.alignment = .center
    stateLabel.maximumNumberOfLines = 4
    retryButton.bezelStyle = .rounded
    retryButton.target = self
    retryButton.action = #selector(retryTreeLoad(_:))
    retryButton.setAccessibilityLabel("Retry loading branch files")
    retryButton.isHidden = true

    for child in [scrollView, stateLabel, retryButton] {
      child.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(child)
    }
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      stateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      stateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
      stateLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
      stateLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
      retryButton.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      retryButton.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 8)
    ])
    view = container
  }

  func clear(message: String = "This branch has no commits to browse") {
    resetTreeState()
    history = SelectedHistoryState()
    treeFailure = message
    repositoryURL = nil
    repositoryID = nil
    if isViewLoaded {
      suppressSelectionChange = true
      tableView.reloadData()
      suppressSelectionChange = false
      updateListState()
    }
    onPresentationChange?()
  }

  func reload(
    repository: URL, repositoryID: UUID, history: SelectedHistoryState, searchText: String
  ) {
    let isUnchanged = self.repositoryURL == repository && self.repositoryID == repositoryID
      && self.history == history && self.searchText == searchText
    self.repositoryURL = repository
    self.repositoryID = repositoryID
    self.history = history
    self.searchText = searchText
    guard isViewLoaded, !isUnchanged else { return }
    guard let objectID = history.tips?.localObjectID else {
      if treeRepositoryID != repositoryID || treeObjectID != nil || treeTask != nil {
        resetTreeState()
      }
      suppressSelectionChange = true
      tableView.reloadData()
      suppressSelectionChange = false
      updateListState()
      onPresentationChange?()
      return
    }
    guard treeRepositoryID != repositoryID || treeRepositoryURL != repository
      || treeObjectID != objectID else {
      if let selectedEntry, !visibleEntries.contains(selectedEntry) { selectEntry(nil) }
      suppressSelectionChange = true
      tableView.reloadData()
      suppressSelectionChange = false
      updateListState()
      onPresentationChange?()
      return
    }
    loadTree(repository: repository, repositoryID: repositoryID, objectID: objectID)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let entry = visibleEntries[row]
    let cell = NSTableCellView()
    let path = entry.path.displayString
    let label = NSTextField(labelWithString: path)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    cell.textField = label
    cell.toolTip = path
    cell.setAccessibilityLabel(path)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !suppressSelectionChange else { return }
    let row = tableView.selectedRow
    selectEntry(visibleEntries.indices.contains(row) ? visibleEntries[row] : nil)
  }

  private var visibleEntries: [GitTreeEntry] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return entries }
    return entries.filter { $0.path.displayString.localizedCaseInsensitiveContains(query) }
  }

  private func loadTree(repository: URL, repositoryID: UUID, objectID: String) {
    resetTreeState()
    treeRepositoryID = repositoryID
    treeRepositoryURL = repository
    treeObjectID = objectID
    isLoadingTree = true
    let generation = treeGeneration
    let gitService = coordinator.gitService
    suppressSelectionChange = true
    tableView.reloadData()
    suppressSelectionChange = false
    updateListState()
    treeTask = Task { [weak self, gitService] in
      do {
        let loadedEntries = try await gitService.branchTreeEntries(
          repository: repository,
          commitObjectID: objectID
        )
        try Task.checkCancellation()
        guard let self,
          treeGeneration == generation,
          self.repositoryURL?.standardizedFileURL == repository.standardizedFileURL,
          coordinator.repositories.first(where: { $0.id == repositoryID })?.canonicalURL
            .standardizedFileURL == repository.standardizedFileURL,
          coordinator.state.uiState.selectedRepoID == repositoryID,
          coordinator.selectedHistoryState.tips?.localObjectID == objectID
        else { return }
        entries = loadedEntries
        isLoadingTree = false
        treeTask = nil
        suppressSelectionChange = true
        tableView.reloadData()
        suppressSelectionChange = false
        updateListState()
        onPresentationChange?()
      } catch {
        guard !Task.isCancelled,
          let self,
          treeGeneration == generation,
          self.repositoryURL?.standardizedFileURL == repository.standardizedFileURL,
          coordinator.repositories.first(where: { $0.id == repositoryID })?.canonicalURL
            .standardizedFileURL == repository.standardizedFileURL,
          coordinator.state.uiState.selectedRepoID == repositoryID,
          coordinator.selectedHistoryState.tips?.localObjectID == objectID
        else { return }
        treeFailure = error.localizedDescription
        canRetryTree = true
        isLoadingTree = false
        treeTask = nil
        updateListState()
        onPresentationChange?()
      }
    }
  }

  @objc private func retryTreeLoad(_ sender: Any?) {
    guard canRetryTree,
      let repositoryURL = treeRepositoryURL,
      let repositoryID = treeRepositoryID,
      let objectID = treeObjectID,
      coordinator.state.uiState.selectedRepoID == repositoryID,
      coordinator.selectedHistoryState.tips?.localObjectID == objectID,
      coordinator.repositories.first(where: { $0.id == repositoryID })?.canonicalURL
        .standardizedFileURL == repositoryURL.standardizedFileURL else { return }
    loadTree(repository: repositoryURL, repositoryID: repositoryID, objectID: objectID)
  }

  private func resetTreeState() {
    treeGeneration &+= 1
    previewGeneration &+= 1
    treeTask?.cancel()
    previewTask?.cancel()
    treeTask = nil
    previewTask = nil
    entries = []
    treeObjectID = nil
    treeRepositoryID = nil
    treeRepositoryURL = nil
    selectedEntry = nil
    previewEntry = nil
    preview = nil
    previewFailure = nil
    treeFailure = nil
    canRetryTree = false
    isLoadingTree = false
  }

  private func updateListState() {
    retryButton.isHidden = true
    if let treeFailure {
      showListState(treeFailure)
      retryButton.isHidden = !canRetryTree
    } else if history.tips?.localObjectID == nil, let historyFailureMessage {
      showListState(historyFailureMessage)
    } else if history.tips?.localObjectID == nil {
      showListState(
        isHistoryLoading ? "Loading branch tip" : "This branch has no commits to browse")
    } else if isLoadingTree {
      showListState("Loading branch files")
    } else if visibleEntries.isEmpty {
      showListState(
        searchText.isEmpty ? "No tracked files in this branch" : "No files match the filter")
    } else {
      stateLabel.isHidden = true
    }
  }

  private var isHistoryLoading: Bool {
    if case .loading = history.phase { return true }
    return false
  }

  private var historyFailureMessage: String? {
    guard case .failed(let failure) = history.phase else { return nil }
    return failure.title + "\n" + failure.recoverySuggestion + "\n\n" + failure.details
  }

  private func showListState(_ message: String) {
    stateLabel.stringValue = message
    stateLabel.isSelectable = false
    stateLabel.isHidden = false
  }

  private func makePresentation() -> BranchFileInspectorPresentation {
    BranchFileInspectorPresentation(
      branchName: displayBranchName,
      commitObjectID: history.tips?.localObjectID,
      path: selectedEntry?.path.displayString,
      state: previewState
    )
  }

  private var previewState: BranchFileInspectorState {
    if let treeFailure { return .failed(treeFailure) }
    guard history.tips?.localObjectID != nil else {
      if let historyFailureMessage { return .failed(historyFailureMessage) }
      return isHistoryLoading ? .loadingTree : .noCommit
    }
    if isLoadingTree { return .loadingTree }
    guard let selectedEntry else { return .noSelection }
    guard selectedEntry.type == "blob" else { return .submodule }
    if let previewFailure { return .failed(previewFailure) }
    guard previewEntry == selectedEntry, let preview else { return .loadingFile }
    switch preview {
    case .text(let text): return .text(text)
    case .binary: return .binary
    case .tooLarge: return .tooLarge
    }
  }

  private var displayBranchName: String {
    if let selectedBranchRef = history.selectedBranchRef,
      let branch = history.branches.first(where: { $0.refName == selectedBranchRef }) {
      return branch.name
    }
    return history.branches.first(where: \.isCurrent)?.name ?? "Current HEAD"
  }
}

private extension BranchFileBrowserViewController {
  func selectEntry(_ entry: GitTreeEntry?) {
    guard let entry,
      let repositoryID,
      let repository = coordinator.repositories.first(where: { $0.id == repositoryID })
    else {
      clearPreviewSelection()
      return
    }
    guard selectedEntry != entry else { return }
    previewGeneration &+= 1
    previewTask?.cancel()
    previewTask = nil
    selectedEntry = entry
    previewEntry = entry
    preview = nil
    previewFailure = nil
    guard entry.type == "blob" else {
      onPresentationChange?()
      return
    }
    loadPreview(entry, repositoryID: repositoryID, repositoryURL: repository.canonicalURL)
    onPresentationChange?()
  }

  func clearPreviewSelection() {
    previewGeneration &+= 1
    previewTask?.cancel()
    previewTask = nil
    selectedEntry = nil
    previewEntry = nil
    preview = nil
    previewFailure = nil
    onPresentationChange?()
  }

  func loadPreview(_ entry: GitTreeEntry, repositoryID: UUID, repositoryURL: URL) {
    let generation = previewGeneration
    let objectID = treeObjectID
    let gitService = coordinator.gitService
    previewTask = Task { [weak self, gitService] in
      do {
        let loadedPreview = try await gitService.branchBlobPreview(
          repository: repositoryURL,
          objectID: entry.objectID
        )
        try Task.checkCancellation()
        guard let self,
          isCurrentPreviewRequest(
            entry: entry,
            repositoryID: repositoryID,
            repositoryURL: repositoryURL,
            objectID: objectID,
            generation: generation
          )
        else { return }
        preview = loadedPreview
        previewTask = nil
        onPresentationChange?()
      } catch {
        guard !Task.isCancelled,
          let self,
          isCurrentPreviewRequest(
            entry: entry,
            repositoryID: repositoryID,
            repositoryURL: repositoryURL,
            objectID: objectID,
            generation: generation
          )
        else { return }
        previewFailure = error.localizedDescription
        previewTask = nil
        onPresentationChange?()
      }
    }
  }

  func isCurrentPreviewRequest(
    entry: GitTreeEntry,
    repositoryID: UUID,
    repositoryURL: URL,
    objectID: String?,
    generation: UInt64
  ) -> Bool {
    previewGeneration == generation
      && selectedEntry == entry
      && self.repositoryURL?.standardizedFileURL == repositoryURL.standardizedFileURL
      && coordinator.repositories.first(where: { $0.id == repositoryID })?.canonicalURL
        .standardizedFileURL == repositoryURL.standardizedFileURL
      && coordinator.state.uiState.selectedRepoID == repositoryID
      && coordinator.selectedHistoryState.tips?.localObjectID == objectID
  }
}
