import AppKit

@MainActor
final class HistoryHeaderView: NSView, NSSearchFieldDelegate, NSMenuDelegate {
  let summaryLabel = NSTextField(labelWithString: "")
  let branchControl = NSPopUpButton(frame: .zero, pullsDown: false)
  let scopeControl = NSSegmentedControl(
    labels: HistoryScope.allCases.map(\.title),
    trackingMode: .selectOne,
    target: nil,
    action: nil
  )
  let contentControl = NSSegmentedControl(
    labels: ["Commits", "Files"],
    trackingMode: .selectOne,
    target: nil,
    action: nil
  )
  let searchField = NSSearchField()
  let worktreeButton = NSButton(title: "Open Current Worktree", target: nil, action: nil)
  let retryHistoryButton = NSButton(title: "Retry History", target: nil, action: nil)
  var onBranchSelection: ((String?) -> Void)?
  var onScopeSelection: ((HistoryScope) -> Void)?
  var onContentSelection: ((Bool) -> Void)?
  var onSearchTextChange: ((String) -> Void)?
  var onOpenWorktree: ((String?) -> Void)?
  var onRetryHistory: (() -> Void)?
  var onBranchMenuOpening: (() -> Void)?
  private let stackView = NSStackView()
  private var selectedBranchRef: String?
  private var isOpeningWorktree = false
  private var hasRepository = false
  var isBrowsingFiles: Bool { contentControl.selectedSegment == 1 }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func render(
    history: SelectedHistoryState, scope: HistoryScope, summary: String, searchText: String
  ) {
    hasRepository = true
    if searchField.stringValue != searchText { searchField.stringValue = searchText }
    scopeControl.selectedSegment = scope.rawValue
    let scopeIsHidden = isBrowsingFiles || history.selectedBranchRef != nil
    scopeControl.isHidden = scopeIsHidden
    scopeControl.isEnabled = !scopeIsHidden
    searchField.placeholderString =
      isBrowsingFiles ? "Filter branch files" : "Filter loaded commits"
    searchField.setAccessibilityLabel(
      isBrowsingFiles ? "Filter branch files by path" : "Filter commits by subject, author, or hash"
    )
    summaryLabel.stringValue = summary
    selectedBranchRef = history.selectedBranchRef
    updateBranchControl(history)
    updateWorktreeButton()
    if case .failed = history.phase {
      retryHistoryButton.isHidden = false
    } else {
      retryHistoryButton.isHidden = true
    }
  }

  func historySummary(
    for history: SelectedHistoryState,
    filteredCommitCount: Int,
    fileCount: Int,
    visibleFileCount: Int
  ) -> String {
    let branchName = history.selectedBranchRef.flatMap { reference in
      history.branches.first { $0.refName == reference }?.name
    } ?? history.branches.first(where: \.isCurrent)?.name ?? "Current HEAD"
    var summary = isBrowsingFiles
      ? "\(branchName)   \(fileCount) files"
      : "\(branchName) · \(history.scope.title) · \(history.commits.count) loaded"
    if isBrowsingFiles, visibleFileCount != fileCount {
      summary += "   \(visibleFileCount) matching"
    } else if !isBrowsingFiles, filteredCommitCount != history.commits.count {
      summary += "   \(filteredCommitCount) matching"
    }
    if !isBrowsingFiles, history.reachedEnd { summary += "   End of history" }
    if !isBrowsingFiles, history.reachedLimit { summary += "   Load limit reached" }
    if !isBrowsingFiles {
      switch history.metadataCompleteness {
      case .complete: break
      case .truncated: summary += "   Metadata truncated"
      case .unavailable: summary += "   Metadata unavailable"
      }
    }
    if case .loading = history.phase { summary += "   Loading" }
    return summary
  }
  func updateSummary(_ summary: String) {
    summaryLabel.stringValue = summary
  }
  func setWorktreeOpening(_ isOpening: Bool) {
    isOpeningWorktree = isOpening
    updateWorktreeButton()
  }

  func clearRepositoryContext() {
    hasRepository = false
    selectedBranchRef = nil
    branchControl.removeAllItems()
    updateWorktreeButton()
  }

  private func configure() {
    summaryLabel.font = .preferredFont(forTextStyle: .caption1)
    summaryLabel.textColor = .secondaryLabelColor
    summaryLabel.lineBreakMode = .byTruncatingTail
    branchControl.target = self
    branchControl.action = #selector(branchChanged(_:))
    branchControl.setAccessibilityLabel("History branch")
    branchControl.menu?.delegate = self
    worktreeButton.target = self
    worktreeButton.action = #selector(worktreeButtonPressed(_:))
    worktreeButton.setAccessibilityLabel("Open selected branch worktree")
    updateWorktreeButton()
    retryHistoryButton.target = self
    retryHistoryButton.action = #selector(retryHistory(_:))
    retryHistoryButton.setAccessibilityLabel("Retry loading history")
    retryHistoryButton.isHidden = true
    contentControl.selectedSegment = 0
    contentControl.target = self
    contentControl.action = #selector(contentChanged(_:))
    contentControl.setAccessibilityLabel("History content")
    scopeControl.selectedSegment = HistoryScope.mixed.rawValue
    scopeControl.target = self
    scopeControl.action = #selector(scopeChanged(_:))
    scopeControl.setAccessibilityLabel("History scope")
    searchField.placeholderString = "Filter loaded commits"
    searchField.delegate = self
    searchField.setAccessibilityLabel("Filter commits by subject, author, or hash")

    stackView.orientation = .vertical
    stackView.alignment = .width
    stackView.spacing = 8
    stackView.translatesAutoresizingMaskIntoConstraints = false
    for arrangedView in [
      summaryLabel, retryHistoryButton, branchControl, worktreeButton, contentControl, scopeControl,
      searchField
    ] {
      stackView.addArrangedSubview(arrangedView)
    }
    addSubview(stackView)
    NSLayoutConstraint.activate([
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard let branchMenu = branchControl.menu, menu === branchMenu else { return }
    onBranchMenuOpening?()
  }

  private func updateBranchControl(_ history: SelectedHistoryState) {
    branchControl.removeAllItems()
    let currentName = history.branches.first(where: \.isCurrent)?.name
    branchControl.addItem(withTitle: currentName.map { "Current HEAD (\($0))" } ?? "Current HEAD")
    branchControl.lastItem?.representedObject = ""
    for branch in history.branches {
      var title = branch.name
      if branch.isRemote { title += " (remote)" }
      if branch.isCurrent { title += " (checked out)" }
      branchControl.addItem(withTitle: title)
      branchControl.lastItem?.representedObject = branch.refName
    }
    let selectedRef = history.selectedBranchRef ?? ""
    let selectedIndex =
      branchControl.itemArray.firstIndex {
        ($0.representedObject as? String) == selectedRef
      } ?? 0
    branchControl.selectItem(at: selectedIndex)
  }

  private func updateWorktreeButton() {
    worktreeButton.title = selectedBranchRef == nil ? "Open Current Worktree" : "Open Branch Worktree"
    let isLocalBranch = selectedBranchRef?.hasPrefix("refs/heads/") ?? true
    worktreeButton.isEnabled = hasRepository && isLocalBranch && !isOpeningWorktree
  }
  @objc private func branchChanged(_ sender: NSPopUpButton) {
    let selectedRef = sender.selectedItem?.representedObject as? String
    onBranchSelection?(selectedRef?.isEmpty == true ? nil : selectedRef)
  }

  @objc private func contentChanged(_ sender: NSSegmentedControl) {
    onContentSelection?(isBrowsingFiles)
  }

  @objc private func scopeChanged(_ sender: NSSegmentedControl) {
    guard !isBrowsingFiles,
      let scope = HistoryScope(rawValue: sender.selectedSegment)
    else { return }
    onScopeSelection?(scope)
  }
  @objc private func worktreeButtonPressed(_ sender: NSButton) {
    onOpenWorktree?(selectedBranchRef)
  }

  @objc private func retryHistory(_ sender: NSButton) {
    onRetryHistory?()
  }

  func controlTextDidChange(_ notification: Notification) {
    onSearchTextChange?(searchField.stringValue)
  }
}
