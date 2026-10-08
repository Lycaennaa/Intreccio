import AppKit

@MainActor
final class ChangesViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private struct TreeCacheKey: Equatable {
        let repositoryID: UUID
        let statusContentGeneration: UInt64
    }
    typealias PlaceholderTextView = ChangesCommitController.PlaceholderTextView
    typealias IgnoreAction = ChangesMutationController.IgnoreAction
    typealias FileOpenAction = ChangesApplicationActionsController.FileOpenAction

    final class Node {
        enum Kind {
            case group
            case changes([FileChange])
        }

        let title: String
        let badge: String?
        let kind: Kind
        let children: [Node]

        init(title: String, badge: String? = nil, kind: Kind, children: [Node] = []) {
            self.title = title
            self.badge = badge
            self.kind = kind
            self.children = children
        }
    }

    let coordinator: AppCoordinator
    let summaryLabel = NSTextField(labelWithString: "")
    let stateLabel = NSTextField(labelWithString: "Select a repository")
    let outlineView = NSOutlineView()
    let commitCompositionController: ChangesCommitController
    let mutationController: ChangesMutationController
    let applicationActionsController: ChangesApplicationActionsController
    let worktreeSelectorController: ChangesWorktreeSelectorController
    var roots: [Node] = []
    var repositoryID: UUID?
    var suppressSelectionChange = false
    private var treeCacheKey: TreeCacheKey?
#if DEBUG
    var treeBuildCountForTesting = 0
    var outlineReloadCountForTesting = 0
#endif

    var onSelectionChange: (([GitPath]) -> Void)?

    var canStageSelected: Bool { isViewLoaded && mutationController.canStageSelected }
    var canStageAll: Bool { isViewLoaded && mutationController.canStageAll }
    var canUnstageSelected: Bool { isViewLoaded && mutationController.canUnstageSelected }
    var canUnstageAll: Bool { isViewLoaded && mutationController.canUnstageAll }
    var canStash: Bool { isViewLoaded && mutationController.canStash }
    var canRestoreStash: Bool { isViewLoaded && mutationController.canRestoreStash }
    var canCommit: Bool { isViewLoaded && commitCompositionController.canCommit }

    var selectedGitPaths: [GitPath] {
        outlineView.selectedRowIndexes.compactMap { row in
            guard let node = outlineView.item(atRow: row) as? Node,
                  case .changes(let changes) = node.kind else { return nil }
            return changes.first?.gitPath
        }
    }

    var selectedChanges: [FileChange] {
        outlineView.selectedRowIndexes.flatMap { row -> [FileChange] in
            guard let node = outlineView.item(atRow: row) as? Node,
                  case .changes(let changes) = node.kind else { return [] }
            return changes
        }
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        commitCompositionController = ChangesCommitController(coordinator: coordinator)
        mutationController = ChangesMutationController(coordinator: coordinator)
        applicationActionsController = ChangesApplicationActionsController(coordinator: coordinator)
        worktreeSelectorController = ChangesWorktreeSelectorController(coordinator: coordinator)
        super.init(nibName: nil, bundle: nil)

        applicationActionsController.windowProvider = { [weak self] in
            guard let self, self.isViewLoaded else { return nil }
            return self.view.window
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.setAccessibilityLabel("Changes")

        let headerStack = makeHeaderStack()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Change"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.backgroundColor = .black
        outlineView.rowSizeStyle = .medium
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel("Changed files")

        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true

        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .center
        stateLabel.maximumNumberOfLines = 3

        let controls = mutationController.makeControlsView(commitView: commitCompositionController.view)
        for child in [headerStack, scrollView, stateLabel, controls] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            stateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20)
        ])
        view = container
    }

    private func makeHeaderStack() -> NSStackView {
        summaryLabel.font = .preferredFont(forTextStyle: .caption1)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.distribution = .fill
        headerStack.spacing = 8
        headerStack.addArrangedSubview(summaryLabel)
        headerStack.addArrangedSubview(worktreeSelectorController.button)
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        worktreeSelectorController.button.setContentHuggingPriority(.required, for: .horizontal)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        return headerStack
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        commitCompositionController.updateLayout()
    }

    static func changeSummary(for status: RepoStatus) -> String {
        changeSummary(for: status, content: RepositoryStatusContent(status: status))
    }

    static func changeSummary(for status: RepoStatus, content: RepositoryStatusContent) -> String {
        let stagedStats = status.stagedLineStats.map { lineStatsSummary($0) } ?? ""
        let unstagedStats = status.unstagedLineStats.map { lineStatsSummary($0) } ?? ""
        return "\(content.stagedCount) staged\(stagedStats)   \(content.unstagedCount) unstaged\(unstagedStats)"
    }

    private static func lineStatsSummary(_ stats: DiffLineStats) -> String {
        guard stats.hasNonCodeFiles,
              stats.hasCodeFiles,
              stats.slocAvailability == .available else {
            return " (+\(stats.additions) -\(stats.deletions))"
        }
        return " (+\(stats.additions) -\(stats.deletions), +\(stats.slocAdditions) SLOC -\(stats.slocDeletions) SLOC)"
    }

    func reload(_ snapshot: AppSnapshot? = nil) {
        guard isViewLoaded else { return }
        let snapshot = snapshot ?? coordinator.snapshot
        guard snapshot.state.uiState.mode == .changes else {
            worktreeSelectorController.clear()
            showState("History", summary: "Commit history")
            return
        }
        guard let selectedID = snapshot.state.uiState.selectedRepoID,
              let repository = snapshot.repositories.first(where: { $0.id == selectedID }) else {
            worktreeSelectorController.clear()
            repositoryID = nil
            showState("Select a repository", summary: "Changes")
            return
        }
        if case .unavailable(let reason) = repository.availability {
            worktreeSelectorController.clear()
            repositoryID = selectedID
            showState(reason, summary: repository.displayName)
            return
        }
        worktreeSelectorController.reload(repository: repository)

        let oldPaths = repositoryID == selectedID ? Set(selectedGitPaths) : []
        repositoryID = selectedID
        let refresh = snapshot.runtime.refreshStates[selectedID, default: RepositoryRefreshState()]
        let treeKey = TreeCacheKey(
            repositoryID: selectedID,
            statusContentGeneration: refresh.statusContentGeneration
        )
        let needsTreeReload = treeCacheKey != treeKey
        guard let status = refresh.status else {
            let message = switch refresh.phase {
            case .queued: "Waiting to refresh changes"
            case .running: "Loading changes"
            case .failed(let error): error.title + " " + error.recoverySuggestion
            case .idle: "No status loaded"
            }
            showState(message, summary: repository.displayName)
            return
        }

        let content = refresh.statusContent ?? RepositoryStatusContent(status: status)
        if needsTreeReload {
            roots = makeGroups(status.changes)
            treeCacheKey = treeKey
        }
        var summary = Self.changeSummary(for: status, content: content)
        if content.conflictCount > 0 { summary += "   \(content.conflictCount) conflicted" }
        if status.isRebaseInProgress { summary += "   Rebase in progress" }
        if status.hasStash { summary += "   Stash available" }
        switch refresh.phase {
        case .queued: summary += "   Line counts queued"
        case .running: summary += "   Calculating line counts"
        case .failed: summary += "   Status may be stale"
        case .idle: break
        }
        summaryLabel.stringValue = "\(repository.displayName) · \(summary)"
        stateLabel.stringValue = status.isClean && !status.isRebaseInProgress ? "Working tree clean" : ""
        stateLabel.isHidden = !status.isClean || status.isRebaseInProgress
        configureMutationControls(status: status, snapshot: snapshot, statusContent: content)

        if needsTreeReload {
            suppressSelectionChange = true
#if DEBUG
            outlineReloadCountForTesting += 1
#endif
            outlineView.reloadData()
            roots.forEach { outlineView.expandItem($0) }
            var restored = IndexSet()
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? Node,
                      case .changes(let changes) = node.kind,
                      let path = changes.first?.gitPath,
                      oldPaths.contains(path) else { continue }
                restored.insert(row)
            }
            outlineView.selectRowIndexes(restored, byExtendingSelection: false)
            suppressSelectionChange = false
            let restoredPaths = Set(selectedGitPaths)
            configureMutationControls(status: status, snapshot: snapshot, statusContent: content)
            if restoredPaths != oldPaths { onSelectionChange?(selectedGitPaths) }
        }
    }

    func showState(_ message: String, summary: String) {
        let hadSelection = !selectedGitPaths.isEmpty
        let hadNodes = !roots.isEmpty
        roots = []
        treeCacheKey = nil
        summaryLabel.stringValue = summary
        stateLabel.stringValue = message
        stateLabel.isHidden = false
        if hadNodes {
            suppressSelectionChange = true
#if DEBUG
            outlineReloadCountForTesting += 1
#endif
            outlineView.reloadData()
            suppressSelectionChange = false
        }
        configureMutationControls(status: nil)
        if hadSelection { onSelectionChange?([]) }
    }

    func updateMutationContext(status: RepoStatus?) {
        mutationController.updateContext(
            selectedChanges: selectedChanges,
            status: status,
            repositoryID: repositoryID,
            window: isViewLoaded ? view.window : nil
        )
    }

    func configureMutationControls(
        status: RepoStatus?,
        snapshot: AppSnapshot? = nil,
        statusContent: RepositoryStatusContent? = nil
    ) {
        let snapshot = snapshot ?? coordinator.snapshot
        let content = statusContent
            ?? repositoryID.flatMap { snapshot.runtime.refreshStates[$0]?.statusContent }
            ?? status.map { RepositoryStatusContent(status: $0) }
        updateMutationContext(status: status)
        mutationController.configure(
            status: status,
            snapshot: snapshot,
            selectedChanges: selectedChanges,
            statusContent: content
        )
        commitCompositionController.configure(status: status, snapshot: snapshot, statusContent: content)
    }

    func focusChangeList() {
        _ = view
        view.window?.makeFirstResponder(outlineView)
    }

    func focusCommitMessage() {
        commitCompositionController.focusMessage(in: view.window)
    }

    func textDidChange(_ notification: Notification) {
        commitCompositionController.textDidChange(notification)
    }

    func updateCommitMessage() {
        commitCompositionController.updateCommitMessage()
    }

    func updateSummaryEditorLayout() {
        commitCompositionController.updateSummaryEditorLayout()
    }

    func makeFileOpenAction(paths: [String], applicationURL: URL? = nil) -> FileOpenAction? {
        applicationActionsController.makeFileOpenAction(paths: paths, applicationURL: applicationURL)
    }

    func addOpenApplicationMenu(to menu: NSMenu, fileOpenAction: FileOpenAction?) {
        applicationActionsController.addOpenApplicationMenu(to: menu, fileOpenAction: fileOpenAction)
    }

    var selectedStatus: RepoStatus? {
        guard let repositoryID = coordinator.state.uiState.selectedRepoID else { return nil }
        return coordinator.repositoryRefreshStates[repositoryID]?.status
    }

    var selectedRepositoryURL: URL? {
        applicationActionsController.selectedRepositoryURL
    }

    nonisolated static func contextMenuChanges(
        clickedChanges: [FileChange],
        selectedChanges: [FileChange],
        clickedRowIsSelected: Bool
    ) -> [FileChange] {
        clickedRowIsSelected ? selectedChanges : clickedChanges
    }

    nonisolated static func commitMessageComponents(_ message: String) -> (summary: String, description: String) {
        ChangesCommitController.commitMessageComponents(message)
    }
}
