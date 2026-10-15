import AppKit

nonisolated struct PushToOriginCandidate: Sendable {
    let repository: RepoDescriptor
    let status: RepoStatus
    let displayName: String

    init(repository: RepoDescriptor, status: RepoStatus, displayName: String? = nil) {
        self.repository = repository
        self.status = status
        self.displayName = displayName ?? repository.displayName
    }
}

nonisolated enum PushToOriginPolicy {
    static func candidates(
        repositories: [RepoDescriptor],
        refreshStates: RepositorySnapshotMap<RepositoryRefreshState>
    ) -> [PushToOriginCandidate] {
        let displayNames = RepoDescriptor.disambiguatedDisplayNames(for: repositories)
        return repositories.compactMap { repository in
            guard repository.availability == .available,
                  let status = refreshStates[repository.id]?.status,
                  hasOutgoingOriginCommits(status: status) else { return nil }
            return PushToOriginCandidate(
                repository: repository,
                status: status,
                displayName: displayNames[repository.id]
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func hasOutgoingOriginCommits(status: RepoStatus) -> Bool {
        status.branch.ahead > 0 && status.branch.upstream?.hasPrefix("origin/") == true
    }

    static func isReady(status: RepoStatus) -> Bool {
        status.branch.upstream?.hasPrefix("origin/") == true
            && ChangesMutationPolicy.pushControlAvailability(
                status: status,
                mutationRunning: false
            ).isAvailable
    }

    static func unavailableReason(status: RepoStatus) -> String {
        guard hasOutgoingOriginCommits(status: status) else { return "No outgoing commits to origin." }
        return ChangesMutationPolicy.pushControlAvailability(
            status: status,
            mutationRunning: false
        ).message
    }
}

@MainActor
enum PushToOriginPanel {
    static func present(
        on window: NSWindow,
        candidates: [PushToOriginCandidate],
        onSelect: @escaping @MainActor ([PushToOriginCandidate]?) -> Void
    ) {
        let picker = PushToOriginPickerController()
        let alert = NSAlert()
        alert.messageText = "Push Repositories to Origin"
        alert.informativeText = "Choose repositories using the latest status and push-access checks."
        alert.accessoryView = picker.view
        let pushButton = alert.addButton(withTitle: "Push Selected (0)")
        alert.addButton(withTitle: "Cancel")
        picker.pushButton = pushButton
        picker.setCandidates(candidates)

        alert.beginSheetModal(for: window) { response in
            onSelect(response == .alertFirstButtonReturn ? picker.selectedCandidates : nil)
        }
    }
}

@MainActor
final class PushToOriginPickerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Entry {
        case ready(PushToOriginCandidate)
        case unavailable(candidate: PushToOriginCandidate, reason: String)

        var candidate: PushToOriginCandidate {
            switch self {
            case .ready(let candidate), .unavailable(let candidate, _): candidate
            }
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var failure: String? {
            guard case .unavailable(_, let reason) = self else { return nil }
            return reason
        }
    }

    private let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
    private let statusLabel = NSTextField(labelWithString: "")
    private let selectAllButton = NSButton(checkboxWithTitle: "Select All Ready", target: nil, action: nil)
    private let selectedCountLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private var entries = [Entry]()
    private var selectedRepositoryIDs = Set<UUID>()
    weak var pushButton: NSButton?

    var view: NSView { rootView }

    var selectedCandidates: [PushToOriginCandidate] {
        entries.compactMap { entry in
            guard selectedRepositoryIDs.contains(entry.candidate.repository.id), entry.isReady else {
                return nil
            }
            return entry.candidate
        }
    }

    var selectionSummary: String { selectedCountLabel.stringValue }

    override init() {
        super.init()
        makeView()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let tableColumn else { return nil }
        let entry = entries[row]
        let cell = NSTableCellView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        if tableColumn.identifier.rawValue == "selection" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRepository(_:)))
            checkbox.tag = row
            checkbox.identifier = NSUserInterfaceItemIdentifier(
                "push-repository-\(entry.candidate.repository.id.uuidString)"
            )
            checkbox.state = selectedRepositoryIDs.contains(entry.candidate.repository.id) ? .on : .off
            checkbox.isEnabled = entry.isReady
            checkbox.setAccessibilityLabel("Push \(entry.candidate.displayName) to origin")
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(checkbox)
            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        let label: NSTextField
        if tableColumn.identifier.rawValue == "repository" {
            let branch = entry.candidate.status.branch.head ?? "Unknown branch"
            label = NSTextField(labelWithString: "\(entry.candidate.displayName)  ·  \(branch)")
        } else if entry.isReady {
            let ahead = entry.candidate.status.branch.ahead
            label = NSTextField(labelWithString: "\(ahead) local commit\(ahead == 1 ? "" : "s")")
        } else {
            label = NSTextField(labelWithString: "Not ready: \(entry.failure ?? "Push unavailable")")
        }
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = entry.failure.map { "\(entry.candidate.displayName) — \($0)" }
            ?? entry.candidate.displayName
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func setCandidates(_ candidates: [PushToOriginCandidate]) {
        entries = candidates.map { candidate in
            PushToOriginPolicy.isReady(status: candidate.status)
                ? .ready(candidate)
                : .unavailable(
                    candidate: candidate,
                    reason: PushToOriginPolicy.unavailableReason(status: candidate.status)
                )
        }
        selectedRepositoryIDs = Set(entries.compactMap { entry in
            entry.isReady ? entry.candidate.repository.id : nil
        })
        let readyCount = entries.filter(\.isReady).count
        let unavailableCount = entries.count - readyCount
        statusLabel.stringValue = unavailableCount == 0
            ? "\(readyCount) repositories ready from the latest status and push-access check."
            : "\(readyCount) ready · \(unavailableCount) unavailable; unavailable rows are disabled."
        tableView.reloadData()
        updateSelectionControls()
    }

    @objc private func toggleRepository(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let repositoryID = entries[sender.tag].candidate.repository.id
        if sender.state == .on {
            selectedRepositoryIDs.insert(repositoryID)
        } else {
            selectedRepositoryIDs.remove(repositoryID)
        }
        updateSelectionControls()
    }

    @objc private func toggleAllReady(_ sender: NSButton) {
        if sender.state == .off {
            selectedRepositoryIDs.removeAll()
        } else {
            selectedRepositoryIDs = Set(entries.compactMap { entry in
                entry.isReady ? entry.candidate.repository.id : nil
            })
        }
        tableView.reloadData()
        updateSelectionControls()
    }

    private func updateSelectionControls() {
        let candidates = selectedCandidates
        let commitCount = candidates.reduce(0) { $0 + $1.status.branch.ahead }
        selectedCountLabel.stringValue = "\(candidates.count) selected · \(commitCount) commits"
        if let pushButton {
            pushButton.title = "Push Selected (\(candidates.count))"
            pushButton.isEnabled = !candidates.isEmpty
        }
        let readyCount = entries.filter(\.isReady).count
        if candidates.isEmpty {
            selectAllButton.state = .off
        } else if candidates.count == readyCount {
            selectAllButton.state = .on
        } else {
            selectAllButton.state = .mixed
        }
    }

    private func makeView() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        selectAllButton.target = self
        selectAllButton.action = #selector(toggleAllReady(_:))
        selectAllButton.allowsMixedState = true
        selectAllButton.translatesAutoresizingMaskIntoConstraints = false
        selectedCountLabel.alignment = .right
        selectedCountLabel.translatesAutoresizingMaskIntoConstraints = false

        let selectionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("selection"))
        selectionColumn.width = 32
        let repositoryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repository"))
        repositoryColumn.width = 330
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.width = 190
        tableView.addTableColumn(selectionColumn)
        tableView.addTableColumn(repositoryColumn)
        tableView.addTableColumn(statusColumn)
        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView

        let selectionRow = NSStackView(views: [selectAllButton, selectedCountLabel])
        selectionRow.alignment = .centerY
        selectionRow.distribution = .fill
        selectionRow.spacing = 8
        selectionRow.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(statusLabel)
        rootView.addSubview(selectionRow)
        rootView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: rootView.topAnchor),
            selectionRow.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            selectionRow.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            selectionRow.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: selectionRow.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
        updateSelectionControls()
    }
}
