import AppKit
import UniformTypeIdentifiers

@MainActor
extension RepoSidebarViewController {
    func reload(_ snapshot: AppSnapshot? = nil) {
        guard isViewLoaded else { return }
        let selectedRepositoryIDsBeforeReload = repositoryIDs(in: outlineView.selectedRowIndexes)
        let snapshot = snapshot ?? coordinator.snapshot
        searchField.stringValue = snapshot.state.uiState.searchText
        let banner = snapshot.errorMessage ?? snapshot.statusMessage
        errorLabel.stringValue = banner ?? ""
        errorLabel.textColor = snapshot.errorMessage == nil ? .systemOrange : .systemRed
        errorLabel.isHidden = banner == nil
        emptyLabel.isHidden = !snapshot.state.watchRoots.isEmpty || !snapshot.state.standaloneRepos.isEmpty

        var synchronizeSelection = false
        switch snapshot.sidebarUpdate {
        case .structural:
            let treeKey = makeTreeCacheKey(snapshot)
            if treeCacheKey != treeKey {
                rebuildTree(snapshot, cacheKey: treeKey)
            } else {
                updateBadgesForAllRepositories(snapshot)
            }
            synchronizeSelection = true

        case .repositoryBadge(let repositoryID):
            if treeCacheKey == nil {
                let treeKey = makeTreeCacheKey(snapshot)
                rebuildTree(snapshot, cacheKey: treeKey)
                synchronizeSelection = true
            } else {
                updateBadge(for: repositoryID, snapshot: snapshot)
            }

        case .none:
            if treeCacheKey == nil {
                let treeKey = makeTreeCacheKey(snapshot)
                rebuildTree(snapshot, cacheKey: treeKey)
                synchronizeSelection = true
            }
        }

        guard synchronizeSelection else { return }
        let candidateIDs: [UUID]
        if selectedRepositoryIDsBeforeReload.isEmpty {
            candidateIDs = snapshot.state.uiState.selectedRepoID.map { [$0] } ?? []
        } else {
            candidateIDs = selectedRepositoryIDsBeforeReload
        }
        let rows = candidateIDs.compactMap { row(for: $0) }
        guard !rows.isEmpty else {
            outlineView.deselectAll(nil)
            return
        }
        let currentIDs = repositoryIDs(in: outlineView.selectedRowIndexes)
        let restoredIDs = rows.compactMap { row -> UUID? in
            guard let node = outlineView.item(atRow: row) as? Node,
                  case .repository(let id) = node.kind else { return nil }
            return id
        }
        if currentIDs != restoredIDs {
            outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        }
    }

    func makeTreeCacheKey(_ snapshot: AppSnapshot) -> TreeCacheKey {
        TreeCacheKey(
            searchText: snapshot.state.uiState.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            repositories: snapshot.repositories,
            watchRoots: snapshot.state.watchRoots,
            standaloneRepos: snapshot.state.standaloneRepos,
            pinnedRepositoryIDs: snapshot.state.uiState.pinnedRepositoryIDs,
            scanMessages: snapshot.scanMessages
        )
    }

    func rebuildTree(_ snapshot: AppSnapshot, cacheKey: TreeCacheKey) {
        roots = makeNodes(snapshot)
        treeCacheKey = cacheKey
#if DEBUG
        outlineReloadCountForTesting += 1
#endif
        outlineView.reloadData()
    }

    func updateBadgesForAllRepositories(_ snapshot: AppSnapshot) {
        for repositoryID in repositoryNodesByID.keys {
            updateBadge(for: repositoryID, snapshot: snapshot)
        }
    }

    func updateBadge(for repositoryID: UUID, snapshot: AppSnapshot) {
        guard let node = repositoryNodesByID[repositoryID] else { return }
#if DEBUG
        badgeUpdateCountForTesting += 1
#endif
        let newBadge = repositoryBadge(
            repositoryID: repositoryID,
            isUnavailable: node.repositoryIsUnavailable,
            snapshot: snapshot
        )
        guard node.badge != newBadge else { return }
        node.badge = newBadge
        outlineView.reloadItem(node, reloadChildren: false)
    }

    func focusSearch() {
        _ = view
        view.window?.makeFirstResponder(searchField)
    }

    func focusRepositoryList() {
        _ = view
        view.window?.makeFirstResponder(outlineView)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? roots.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if case .repository = node.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return switch node.kind {
            case .root, .folder, .repository: false
            case .pinnedSection, .standaloneSection: true
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: node.title)
        let icon = NSImageView()
        let titleStack = NSStackView(views: [icon, label])
        let badge = NSTextField(labelWithString: node.badge ?? "")
        let isFolder = switch node.kind {
        case .root, .folder: true
        default: false
        }
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .white
        if isFolder {
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        }
        icon.image = isFolder ? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder") : nil
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = isFolder ? .systemYellow : .secondaryLabelColor
        icon.isHidden = !isFolder
        icon.setContentHuggingPriority(.required, for: .horizontal)
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 6
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        badge.textColor = .white
        badge.font = .preferredFont(forTextStyle: .caption1)
        badge.isHidden = node.badge == nil
        badge.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(titleStack)
        cell.addSubview(badge)
        cell.textField = label
        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
            titleStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = node.subtitle
        let accessibilityStatus = [isFolder ? "Folder" : nil, node.badge, node.subtitle]
            .compactMap { $0 }
            .joined(separator: ", ")
        cell.setAccessibilityLabel(accessibilityStatus.isEmpty ? node.title : "\(node.title), \(accessibilityStatus)")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let id = repositoryIDs(in: outlineView.selectedRowIndexes).first else { return }
        coordinator.selectRepository(id)
    }

    func controlTextDidChange(_ obj: Notification) {
        coordinator.setSearchText(searchField.stringValue)
    }

    func makeNodes(_ snapshot: AppSnapshot) -> [Node] {
#if DEBUG
        treeBuildCountForTesting += 1
#endif
        let query = snapshot.state.uiState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let uniqueRepositories = RepositoryCatalogIndex.firstRepositories(snapshot.repositories)
        let filtered = uniqueRepositories.filter { repository in
            query.isEmpty || repository.displayName.localizedCaseInsensitiveContains(query)
                || repository.canonicalURL.path.localizedCaseInsensitiveContains(query)
        }
        let repositoriesBySource = Dictionary(grouping: uniqueRepositories, by: { $0.source.id })
        let filteredRepositoriesBySource = Dictionary(grouping: filtered, by: { $0.source.id })
        let pinnedRepositoryIDs = snapshot.state.uiState.pinnedRepositoryIDs
        var nodes: [Node] = []
        let pinned = filtered
            .filter { pinnedRepositoryIDs.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { repositoryNode($0, snapshot: snapshot) }
        if !pinned.isEmpty {
            nodes.append(Node(title: "Pinned", kind: .pinnedSection))
            nodes.append(contentsOf: pinned)
        }
        for source in snapshot.state.watchRoots {
            let sourceURL = RepositoryPathPolicy.canonicalURL(
                URL(fileURLWithPath: source.lastResolvedPath, isDirectory: true)
            )
            let sourceRepositories = repositoriesBySource[source.id] ?? []
            let repositories = (filteredRepositoriesBySource[source.id] ?? [])
                .filter { !pinnedRepositoryIDs.contains($0.id) }
            let relativeComponentsByRepositoryID = Dictionary(uniqueKeysWithValues: repositories.map { repository in
                (repository.id, relativeComponents(for: repository, sourceURL: sourceURL))
            })
            nodes.append(Node(
                title: watchRootTitle(source, sourceURL: sourceURL, repositories: sourceRepositories),
                subtitle: snapshot.scanMessages[source.id] ?? sourceURL.path,
                badge: sourceBadge(snapshot.scanMessages[source.id]),
                kind: .root(source.id)
            ))
            nodes.append(contentsOf: makeFolderLevel(
                sourceID: source.id,
                sourceURL: sourceURL,
                relativePrefix: [],
                repositories: repositories,
                relativeComponentsByRepositoryID: relativeComponentsByRepositoryID,
                snapshot: snapshot
            ))
        }
        let standalone = filtered
            .filter {
                if case .standalone = $0.source { return !pinnedRepositoryIDs.contains($0.id) }
                return false
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { repositoryNode($0, snapshot: snapshot) }
        if !snapshot.state.standaloneRepos.isEmpty {
            nodes.append(Node(title: "Repositories", kind: .standaloneSection))
            nodes.append(contentsOf: standalone)
        }
        repositoryNodesByID.removeAll(keepingCapacity: true)
        indexRepositoryNodes(in: nodes)
        return nodes
    }

    func indexRepositoryNodes(in nodes: [Node]) {
        for node in nodes {
            if case .repository(let repositoryID) = node.kind {
                repositoryNodesByID[repositoryID] = node
            }
        }
    }

    func watchRootTitle(_ source: WatchRoot, sourceURL: URL, repositories: [RepoDescriptor]) -> String {
        let sourceName = sourceURL.lastPathComponent.isEmpty ? source.displayName : sourceURL.lastPathComponent
        guard repositories.contains(where: { repository in
            RepositoryPathPolicy.canonicalURL(repository.canonicalURL) == sourceURL
        }) else {
            return sourceName
        }
        let parentURL = sourceURL.deletingLastPathComponent()
        return parentURL.lastPathComponent.isEmpty ? sourceName : parentURL.lastPathComponent
    }

    func relativeComponents(for repository: RepoDescriptor, sourceURL: URL) -> [String] {
        let relativePath = RepositoryPathPolicy.relativePath(
            from: sourceURL,
            to: RepositoryPathPolicy.canonicalURL(repository.canonicalURL)
        ) ?? repository.relativePath ?? ""
        return relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func makeFolderLevel(
        sourceID: UUID,
        sourceURL: URL,
        relativePrefix: [String],
        repositories: [RepoDescriptor],
        relativeComponentsByRepositoryID: [UUID: [String]],
        snapshot: AppSnapshot
    ) -> [Node] {
        var directRepositories: [RepoDescriptor] = []
        var folders: [String: [RepoDescriptor]] = [:]

        for repository in repositories {
            let components = relativeComponentsByRepositoryID[repository.id] ?? []
            guard components.starts(with: relativePrefix) else {
                directRepositories.append(repository)
                continue
            }
            let remaining = components.dropFirst(relativePrefix.count)
            if remaining.count <= 1 {
                directRepositories.append(repository)
            } else {
                folders[remaining[remaining.startIndex], default: []].append(repository)
            }
        }

        var nodes = directRepositories
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { repositoryNode($0, snapshot: snapshot) }
        for folderName in folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let folderComponents = relativePrefix + [folderName]
            let folderPath = folderComponents.joined(separator: "/")
            let folderURL = sourceURL.appendingPathComponent(folderPath, isDirectory: true)
            nodes.append(Node(
                title: folderName,
                subtitle: folderURL.path,
                kind: .folder(sourceID: sourceID, relativePath: folderPath)
            ))
            nodes.append(contentsOf: makeFolderLevel(
                sourceID: sourceID,
                sourceURL: sourceURL,
                relativePrefix: folderComponents,
                repositories: folders[folderName] ?? [],
                relativeComponentsByRepositoryID: relativeComponentsByRepositoryID,
                snapshot: snapshot
            ))
        }
        return nodes
    }

    func repositoryNode(_ repository: RepoDescriptor, snapshot: AppSnapshot) -> Node {
        let unavailable: Bool
        let subtitle: String
        switch repository.availability {
        case .available:
            unavailable = false
            subtitle = repository.canonicalURL.path
        case .unavailable(let reason):
            unavailable = true
            subtitle = "\(reason)\nRight-click to re-authorize or remove this source.\n\(repository.canonicalURL.path)"
        }
        return Node(
            title: unavailable ? "\(repository.displayName) — Unavailable" : repository.displayName,
            subtitle: subtitle,
            badge: repositoryBadge(
                repositoryID: repository.id,
                isUnavailable: unavailable,
                snapshot: snapshot
            ),
            kind: .repository(repository.id),
            repositoryIsUnavailable: unavailable
        )
    }

    func repositoryBadge(
        repositoryID: UUID,
        isUnavailable: Bool,
        snapshot: AppSnapshot
    ) -> String? {
        let refreshState = snapshot.runtime.refreshStates[repositoryID]
        switch (isUnavailable, refreshState?.phase) {
        case (true, _): return "Unavailable"
        case (false, .queued): return "Queued"
        case (false, .running): return "Refreshing"
        case (false, .failed): return "Error"
        case (false, .idle), (false, nil): return refreshState?.sidebarBadge
        }
    }

    func sourceBadge(_ message: String?) -> String? {
        guard let message else { return nil }
        if message.hasPrefix("Scan stopped") { return "Scan limited" }
        if message.hasPrefix("Access unavailable") { return "Action needed" }
        return "Warning"
    }

    func row(for repositoryID: UUID) -> Int? {
        guard let node = repositoryNodesByID[repositoryID] else { return nil }
        let row = outlineView.row(forItem: node)
        return row >= 0 ? row : nil
    }

    func repositoryIDs(in rowIndexes: IndexSet) -> [UUID] {
        rowIndexes.compactMap { row in
            guard let node = outlineView.item(atRow: row) as? Node,
                  case .repository(let id) = node.kind else { return nil }
            return id
        }
    }
}
