import AppKit

nonisolated enum GitHubRepositorySelectionPolicy {
    static let maximumSelectionCount = 10

    static func canClone(count: Int) -> Bool {
        count > 0 && count <= maximumSelectionCount
    }
}

@MainActor
enum GitHubRepositoryPicker {
    static func present(
        on window: NSWindow,
        repositories: [GitHubRepository],
        onSelect: @escaping @MainActor ([GitHubRepository]?) -> Void
    ) {
        let picker = GitHubRepositoryPickerController(repositories: repositories)
        let alert = NSAlert()
        alert.messageText = "Select GitHub Repositories"
        alert.informativeText = "Choose up to \(GitHubRepositorySelectionPolicy.maximumSelectionCount) repositories "
            + "to clone."
        alert.accessoryView = picker.view
        let cloneButton = alert.addButton(withTitle: "Clone Selected")
        alert.addButton(withTitle: "Cancel")
        cloneButton.isEnabled = false
        picker.cloneButton = cloneButton
        alert.beginSheetModal(for: window) { response in
            onSelect(response == .alertFirstButtonReturn ? picker.selectedRepositories : nil)
        }
    }
}

@MainActor
private final class GitHubRepositoryPickerController: NSObject,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate {
    private let repositories: [GitHubRepository]
    private var filteredRepositories: [GitHubRepository]
    private let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    weak var cloneButton: NSButton?

    var selectedRepositories: [GitHubRepository] {
        let selectedRows = tableView.selectedRowIndexes
        guard GitHubRepositorySelectionPolicy.canClone(count: selectedRows.count) else { return [] }
        return selectedRows.compactMap { index in
            guard filteredRepositories.indices.contains(index) else { return nil }
            return filteredRepositories[index]
        }
    }

    var view: NSView { rootView }

    init(repositories: [GitHubRepository]) {
        self.repositories = repositories
        filteredRepositories = repositories
        super.init()
        makeView()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredRepositories.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredRepositories.indices.contains(row) else { return nil }
        let repository = filteredRepositories[row]
        let cell = NSTableCellView()
        let visibility = repository.isPrivate ? "Private" : "Public"
        let label = NSTextField(labelWithString: "\(repository.nameWithOwner)  ·  \(visibility)")
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = repository.description
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateCloneButton()
    }

    private func updateCloneButton() {
        let selectedCount = tableView.selectedRowIndexes.count
        cloneButton?.isEnabled = GitHubRepositorySelectionPolicy.canClone(count: selectedCount)
        cloneButton?.title = selectedCount > GitHubRepositorySelectionPolicy.maximumSelectionCount
            ? "Select \(GitHubRepositorySelectionPolicy.maximumSelectionCount) or Fewer"
            : "Clone Selected"
    }

    func controlTextDidChange(_ notification: Notification) {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        filteredRepositories = query.isEmpty ? repositories : repositories.filter { repository in
            repository.nameWithOwner.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(query)
                || repository.description?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(query) == true
        }
        tableView.reloadData()
        tableView.deselectAll(nil)
        updateCloneButton()
    }

    private func makeView() {
        searchField.placeholderString = "Filter repositories"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repository"))
        column.title = "Repository"
        column.width = 500
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        rootView.addSubview(searchField)
        rootView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }
}
