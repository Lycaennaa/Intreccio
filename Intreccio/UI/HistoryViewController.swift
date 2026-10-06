import AppKit

@MainActor
final class HistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private let coordinator: AppCoordinator
    private let summaryLabel = NSTextField(labelWithString: "")
    private let scopeControl = NSSegmentedControl(
        labels: HistoryScope.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let stateLabel = NSTextField(labelWithString: "Select a repository")
    private var commits: [Commit] = []
    private var repositoryID: UUID?
    private var renderedHistory: SelectedHistoryState?
    private var renderedSearchText: String?
    private var suppressSelectionChange = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.setAccessibilityLabel("History")

        summaryLabel.font = .preferredFont(forTextStyle: .caption1)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail

        scopeControl.selectedSegment = HistoryScope.mixed.rawValue
        scopeControl.target = self
        scopeControl.action = #selector(historyScopeChanged(_:))
        scopeControl.setAccessibilityLabel("History scope")

        searchField.placeholderString = "Filter loaded commits"
        searchField.delegate = self
        searchField.setAccessibilityLabel("Filter commits by subject, author, or hash")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Commit"))
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

        for child in [summaryLabel, scopeControl, searchField, scrollView, stateLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            summaryLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scopeControl.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            scopeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scopeControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
        ])
        view = container
    }

    func reload(_ snapshot: AppSnapshot? = nil) {
        guard isViewLoaded else { return }
        let snapshot = snapshot ?? coordinator.snapshot
        guard snapshot.state.uiState.mode == .history else { return }
        if searchField.stringValue != snapshot.state.uiState.searchText {
            searchField.stringValue = snapshot.state.uiState.searchText
        }
        scopeControl.selectedSegment = snapshot.selectedSession.historyScope.rawValue
        guard let selectedID = snapshot.state.uiState.selectedRepoID,
              let repository = snapshot.repositories.first(where: { $0.id == selectedID }) else {
            repositoryID = nil
            showState("Select a repository", summary: "History")
            return
        }
        if case .unavailable(let reason) = repository.availability {
            repositoryID = selectedID
            showState(reason, summary: repository.displayName)
            return
        }

        let history = snapshot.selectedSession.historyState
        let filteredCommits = history.filteredCommits(searchText: snapshot.state.uiState.searchText)
        let searchText = snapshot.state.uiState.searchText
        if repositoryID == selectedID,
           commits == filteredCommits,
           renderedHistory == history,
           renderedSearchText == searchText { return }

        let selectedObjectID = repositoryID == selectedID ? selectedCommit?.objectID : nil
        repositoryID = selectedID
        commits = filteredCommits
        renderedHistory = history
        renderedSearchText = searchText
        var summary = "\(history.scope.title)   \(history.commits.count) loaded"
        if commits.count != history.commits.count { summary += "   \(commits.count) matching" }
        if history.reachedEnd { summary += "   End of history" }
        if history.reachedLimit { summary += "   Load limit reached" }
        switch history.metadataCompleteness {
        case .complete:
            break
        case .truncated:
            summary += "   Metadata truncated"
        case .unavailable:
            summary += "   Metadata unavailable"
        }
        if case .loading = history.phase { summary += "   Loading" }
        summaryLabel.stringValue = summary

        suppressSelectionChange = true
        tableView.reloadData()
        if let selectedObjectID, let row = commits.firstIndex(where: { $0.objectID == selectedObjectID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        suppressSelectionChange = false

        switch history.phase {
        case .failed(let failure):
            stateLabel.stringValue = failure.title + "\n" + failure.recoverySuggestion + "\n\n" + failure.details
            stateLabel.isSelectable = true
            stateLabel.isHidden = false
        case .loading where commits.isEmpty:
            stateLabel.stringValue = "Loading history"
            stateLabel.isHidden = false
        default:
            if history.commits.isEmpty && history.reachedEnd {
                stateLabel.stringValue = history.scope.emptyMessage
                stateLabel.isHidden = false
            } else if commits.isEmpty && !snapshot.state.uiState.searchText.isEmpty {
                stateLabel.stringValue = "No loaded commits match the filter"
                stateLabel.isHidden = false
            } else {
                stateLabel.isHidden = true
            }
        }

        if selectedCommit == nil, snapshot.selectedSession.commitState.commit != nil {
            coordinator.selectCommit(nil)
        }
        requestNextPageIfNeeded()
    }

    func focusSearch() {
        _ = view
        view.window?.makeFirstResponder(searchField)
    }

    func focusCommitList() {
        _ = view
        view.window?.makeFirstResponder(tableView)
    }

    @objc private func historyScopeChanged(_ sender: NSSegmentedControl) {
        guard let scope = HistoryScope(rawValue: sender.selectedSegment) else { return }
        coordinator.setHistoryScope(scope)
    }

    private var selectedCommit: Commit? {
        let row = tableView.selectedRow
        return commits.indices.contains(row) ? commits[row] : nil
    }

    private func showState(_ message: String, summary: String) {
        commits = []
        summaryLabel.stringValue = summary
        stateLabel.stringValue = message
        stateLabel.isHidden = false
        suppressSelectionChange = true
        tableView.reloadData()
        suppressSelectionChange = false
        if coordinator.selectedCommitState.commit != nil { coordinator.selectCommit(nil) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        commits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let commit = commits[row]
        let cell = NSTableCellView()
        let subject = NSTextField(labelWithString: commit.subject.isEmpty ? "(no subject)" : commit.subject)
        let metadata = NSTextField(labelWithString: "\(commit.authorName)   \(String(commit.objectID.prefix(8)))   \(Self.dateFormatter.string(from: commit.authoredAt))")
        subject.lineBreakMode = .byTruncatingTail
        metadata.lineBreakMode = .byTruncatingTail
        metadata.font = .preferredFont(forTextStyle: .caption2)
        metadata.textColor = .secondaryLabelColor
        subject.translatesAutoresizingMaskIntoConstraints = false
        metadata.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(subject)
        cell.addSubview(metadata)
        cell.textField = subject
        NSLayoutConstraint.activate([
            subject.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            subject.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            subject.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            metadata.leadingAnchor.constraint(equalTo: subject.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: subject.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 2),
        ])
        cell.toolTip = commit.subject
        cell.setAccessibilityLabel("\(subject.stringValue), \(metadata.stringValue)")
        if row >= commits.count - 3 { requestNextPageIfNeeded() }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionChange else { return }
        coordinator.selectCommit(selectedCommit)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard commits.indices.contains(tableView.clickedRow) else { return }
        let commit = commits[tableView.clickedRow]
        let item = NSMenuItem(title: "Amend Commit", action: #selector(amendCommit(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = commit
        item.isEnabled = coordinator.mutationState != .running
            && coordinator.selectedHistoryState.headObjectID == commit.objectID
            && commit.subjectMetadata.completeness.isComplete
            && commit.bodyMetadata.completeness.isComplete
        if !commit.subjectMetadata.completeness.isComplete || !commit.bodyMetadata.completeness.isComplete {
            item.toolTip = "Commit message is truncated; reload history before amending."
        }
        menu.addItem(item)
    }

    @objc private func amendCommit(_ sender: NSMenuItem) {
        guard let commit = sender.representedObject as? Commit else { return }
        coordinator.beginAmending(commit)
    }

    func controlTextDidChange(_ obj: Notification) {
        coordinator.setSearchText(searchField.stringValue)
    }

    @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
        requestNextPageIfNeeded()
    }

    private func requestNextPageIfNeeded() {
        guard coordinator.state.uiState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !coordinator.selectedHistoryState.reachedEnd,
              !coordinator.selectedHistoryState.reachedLimit else { return }
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
