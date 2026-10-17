import AppKit
import UniformTypeIdentifiers

@MainActor
extension RepoSidebarViewController {
    private struct FolderLevelEnvironment {
        let sourceID: UUID
        let sourceURL: URL
        let snapshot: AppSnapshot
    }
    func reload(_ snapshot: AppSnapshot? = nil) {
        guard isViewLoaded else { return }
        let selectedRepositoryIDsBeforeReload = repositoryIDs(in: outlineView.selectedRowIndexes)
        let snapshot = snapshot ?? coordinator.snapshot
        updateStatusLabels(snapshot)
        guard updateTree(snapshot) else { return }
        restoreSelection(selectedRepositoryIDsBeforeReload, snapshot: snapshot)
    }

    private func updateStatusLabels(_ snapshot: AppSnapshot) {
        searchField.stringValue = snapshot.state.uiState.searchText
        let banner = snapshot.errorMessage ?? snapshot.statusMessage
        errorLabel.stringValue = banner ?? ""
        errorLabel.textColor = snapshot.errorMessage == nil ? .systemOrange : .systemRed
        errorLabel.isHidden = banner == nil
        let hasVisibleStandalone = sidebarVisibleRepositories(
            snapshot.repositories,
            matchingQuery: ""
        ).contains { repository in
            if case .standalone = repository.source { return true }
            return false
        }
        emptyLabel.isHidden = !snapshot.state.watchRoots.isEmpty || hasVisibleStandalone
    }

    private func updateTree(_ snapshot: AppSnapshot) -> Bool {
        switch snapshot.sidebarUpdate {
        case .structural:
            let treeKey = makeTreeCacheKey(snapshot)
            if treeCacheKey != treeKey {
                rebuildTree(snapshot, cacheKey: treeKey)
            } else {
                updateBadgesForAllRepositories(snapshot)
            }
            return true
        case .submoduleActivity:
            rebuildTree(snapshot, cacheKey: makeTreeCacheKey(snapshot))
            return true
        case .repositoryBadge(let repositoryID):
            guard treeCacheKey != nil else {
                rebuildTree(snapshot, cacheKey: makeTreeCacheKey(snapshot))
                return true
            }
            updateBadge(for: repositoryID, snapshot: snapshot)
            return false
        case .none:
            guard treeCacheKey == nil else { return false }
            rebuildTree(snapshot, cacheKey: makeTreeCacheKey(snapshot))
            return true
        }
    }
    func makeTreeCacheKey(_ snapshot: AppSnapshot) -> TreeCacheKey {
        TreeCacheKey(
            searchText: snapshot.state.uiState.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            repositories: snapshot.repositories,
            watchRoots: snapshot.state.watchRoots,
            standaloneRepos: snapshot.state.standaloneRepos,
            pinnedRepositoryIDs: snapshot.state.uiState.pinnedRepositoryIDs,
            showCleanSubmoduleRepositoryIDs: snapshot.state.uiState.showCleanSubmoduleRepositoryIDs,
            scanMessages: snapshot.scanMessages
        )
    }

    func rebuildTree(_ snapshot: AppSnapshot, cacheKey: TreeCacheKey) {
        let expandedRepositoryIDs = repositoryNodesByID.compactMap { repositoryID, node in
            outlineView.isItemExpanded(node) ? repositoryID : nil
        }
        roots = makeNodes(snapshot)
        treeCacheKey = cacheKey
#if DEBUG
        outlineReloadCountForTesting += 1
#endif
        outlineView.reloadData()
        for repositoryID in expandedRepositoryIDs {
            guard let node = repositoryNodesByID[repositoryID] else { continue }
            expandAncestors(of: node)
            outlineView.expandItem(node)
        }
        updateBadgesForAllRepositories(snapshot)
    }

    private func restoreSelection(_ selectedRepositoryIDsBeforeReload: [UUID], snapshot: AppSnapshot) {
        let previousRows = selectedRepositoryIDsBeforeReload.compactMap { repositoryID in
            sidebarSelectionRepositoryID(for: repositoryID, snapshot: snapshot)
        }.compactMap { row(for: $0) }
        let rows: [Int]
        if !previousRows.isEmpty {
            rows = previousRows
        } else if let selectedID = snapshot.state.uiState.selectedRepoID {
            let repositoryID = sidebarSelectionRepositoryID(for: selectedID, snapshot: snapshot) ?? selectedID
            rows = row(for: repositoryID).map { [$0] } ?? []
        } else {
            rows = []
        }
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
        guard currentIDs != restoredIDs else { return }
        isSynchronizingSelection = true
        outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        isSynchronizingSelection = false
    }

    func updateBadgesForAllRepositories(_ snapshot: AppSnapshot) {
        for root in roots {
            updateBadge(for: nil, in: root, snapshot: snapshot)
        }
    }

    func updateBadge(for repositoryID: UUID, snapshot: AppSnapshot) {
        for root in roots {
            updateBadge(for: repositoryID, in: root, snapshot: snapshot)
        }
    }

    private func updateBadge(for repositoryID: UUID?, in node: Node, snapshot: AppSnapshot) {
        if case .repository(let currentRepositoryID) = node.kind,
           repositoryID == nil || repositoryID == currentRepositoryID {
#if DEBUG
            badgeUpdateCountForTesting += 1
#endif
            let newBadge = repositoryBadge(for: node, snapshot: snapshot)
            if node.badge != newBadge {
                node.badge = newBadge
                outlineView.reloadItem(node, reloadChildren: false)
            }
        }
        for child in node.children {
            updateBadge(for: repositoryID, in: child, snapshot: snapshot)
        }
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
        guard let node = item as? Node else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.children.isEmpty == false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        updateExpansionBadge(notification)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        updateExpansionBadge(notification)
    }

    private func updateExpansionBadge(_ notification: Notification) {
        guard let node = notification.userInfo?.values.compactMap({ $0 as? Node }).first,
              case .repository(let repositoryID) = node.kind else { return }
        updateBadge(for: repositoryID, snapshot: coordinator.snapshot)
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
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.toolTip = node.subtitle
        let accessibilityStatus = [isFolder ? "Folder" : nil, node.badge, node.subtitle]
            .compactMap(\.self)
            .joined(separator: ", ")
        cell.setAccessibilityLabel(accessibilityStatus.isEmpty ? node.title : "\(node.title), \(accessibilityStatus)")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSynchronizingSelection,
              let id = repositoryIDs(in: outlineView.selectedRowIndexes).first else { return }
        coordinator.selectRepository(id)
    }

    func controlTextDidChange(_ obj: Notification) {
        coordinator.setSearchText(searchField.stringValue)
    }

    private func sidebarVisibleRepositories(
        _ repositories: [RepoDescriptor],
        matchingQuery query: String
    ) -> [RepoDescriptor] {
        let matching = RepositoryCatalogIndex.firstRepositories(repositories).filter { repository in
            query.isEmpty || repository.displayName.localizedCaseInsensitiveContains(query)
                || repository.canonicalURL.path.localizedCaseInsensitiveContains(query)
        }
        let mainGitDirectories = Set(matching.compactMap { repository -> String? in
            guard !repository.isLinkedWorktree,
                  let commonGitDirectoryURL = repository.commonGitDirectoryURL else { return nil }
            return commonGitDirectoryURL.standardizedFileURL.path
        })
        var representedLinkedDirectories = Set<String>()
        return matching.filter { repository in
            guard repository.isLinkedWorktree,
                  let commonGitDirectoryURL = repository.commonGitDirectoryURL else { return true }
            let gitDirectoryPath = commonGitDirectoryURL.standardizedFileURL.path
            guard !mainGitDirectories.contains(gitDirectoryPath) else { return false }
            return representedLinkedDirectories.insert(gitDirectoryPath).inserted
        }
    }

    func makeNodes(_ snapshot: AppSnapshot) -> [Node] {
#if DEBUG
        treeBuildCountForTesting += 1
#endif
        let query = snapshot.state.uiState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleRepositories = sidebarVisibleRepositories(snapshot.repositories, matchingQuery: "")
        let matchingRepositories = sidebarVisibleRepositories(snapshot.repositories, matchingQuery: query)
        let hierarchy = makeRepositoryHierarchy(
            snapshot: snapshot,
            query: query,
            visibleRepositories: visibleRepositories,
            matchingRepositories: matchingRepositories
        )
        let topLevelRepositories = hierarchy.topLevel
        let topLevelRepositoryIDs = Set(topLevelRepositories.map(\.id))
        let repositoryTreeNodesByID = hierarchy.nodesByID

        let pinnedRepositoryIDs = snapshot.state.uiState.pinnedRepositoryIDs
        var nodes: [Node] = []
        let pinned = matchingRepositories
            .filter {
                pinnedRepositoryIDs.contains($0.id) && topLevelRepositoryIDs.contains($0.id)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { repositoryTreeNodesByID[$0.id] ?? repositoryNode($0, snapshot: snapshot) }
        if !pinned.isEmpty {
            nodes.append(Node(title: "Pinned", kind: .pinnedSection))
            nodes.append(contentsOf: pinned)
        }

        let repositoriesBySource = Dictionary(grouping: topLevelRepositories, by: { $0.source.id })
        for source in snapshot.state.watchRoots {
            let sourceURL = RepositoryPathPolicy.canonicalURL(
                URL(fileURLWithPath: source.lastResolvedPath, isDirectory: true)
            )
            let sourceRepositories = repositoriesBySource[source.id] ?? []
            let repositories = sourceRepositories.filter {
                !pinnedRepositoryIDs.contains($0.id) && repositoryTreeNodesByID[$0.id] != nil
            }
            let relativeComponentsByRepositoryID = Dictionary(uniqueKeysWithValues: repositories.map { repository in
                (repository.id, relativeComponents(for: repository, sourceURL: sourceURL))
            })
            nodes.append(Node(
                title: watchRootTitle(source, sourceURL: sourceURL, repositories: sourceRepositories),
                subtitle: snapshot.scanMessages[source.id] ?? sourceURL.path,
                badge: sourceBadge(snapshot.scanMessages[source.id]),
                kind: .root(source.id)
            ))
            let environment = FolderLevelEnvironment(sourceID: source.id, sourceURL: sourceURL, snapshot: snapshot)
            nodes.append(contentsOf: makeFolderLevel(
                environment: environment,
                relativePrefix: [],
                repositories: repositories,
                relativeComponentsByRepositoryID: relativeComponentsByRepositoryID,
                repositoryNodesByID: repositoryTreeNodesByID
            ))
        }
        nodes.append(contentsOf: standaloneSectionNodes(
            visibleRepositories: topLevelRepositories,
            pinnedRepositoryIDs: pinnedRepositoryIDs,
            repositoryNodesByID: repositoryTreeNodesByID,
            snapshot: snapshot
        ))
        repositoryNodesByID.removeAll(keepingCapacity: true)
        indexRepositoryNodes(in: nodes)
        return nodes
    }
    private func makeRepositoryHierarchy(
        snapshot: AppSnapshot,
        query: String,
        visibleRepositories: [RepoDescriptor],
        matchingRepositories: [RepoDescriptor]
    ) -> (topLevel: [RepoDescriptor], nodesByID: [UUID: Node]) {
        let repositoriesByID = Dictionary(uniqueKeysWithValues: visibleRepositories.map { ($0.id, $0) })
        let topLevel = visibleRepositories.filter { repository in
            guard let parentID = repository.submoduleParentRepositoryID else { return true }
            return repositoriesByID[parentID] == nil
        }
        var childrenByParentID: [UUID: [RepoDescriptor]] = [:]
        for repository in visibleRepositories where repository.availability == .available {
            guard let parentID = repository.submoduleParentRepositoryID,
                  repositoriesByID[parentID] != nil else { continue }
            childrenByParentID[parentID, default: []].append(repository)
        }
        let context = RepositoryTreeContext(
            snapshot: snapshot,
            childrenByParentID: childrenByParentID,
            matchingRepositoryIDs: Set(matchingRepositories.map(\.id)),
            isSearching: !query.isEmpty
        )
        var nodesByID: [UUID: Node] = [:]
        nodesByID.reserveCapacity(topLevel.count)
        for repository in topLevel {
            if let node = makeRepositoryTreeNode(repository, context: context) {
                nodesByID[repository.id] = node
            }
        }
        return (topLevel, nodesByID)
    }

    private func standaloneSectionNodes(
        visibleRepositories: [RepoDescriptor],
        pinnedRepositoryIDs: Set<UUID>,
        repositoryNodesByID: [UUID: Node],
        snapshot: AppSnapshot
    ) -> [Node] {
        let standalone = visibleRepositories
            .filter {
                if case .standalone = $0.source {
                    return !pinnedRepositoryIDs.contains($0.id) && repositoryNodesByID[$0.id] != nil
                }
                return false
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .compactMap { repositoryNodesByID[$0.id] }
        guard visibleRepositories.contains(where: {
            if case .standalone = $0.source { return true }
            return false
        }) else { return [] }
        return [Node(title: "Repositories", kind: .standaloneSection)] + standalone
    }

    func sidebarSelectionRepositoryID(for repositoryID: UUID, snapshot: AppSnapshot) -> UUID? {
        guard let repository = snapshot.repositories.first(where: { $0.id == repositoryID }),
              let commonGitDirectoryURL = repository.commonGitDirectoryURL else { return repositoryID }
        let query = snapshot.state.uiState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sidebarVisibleRepositories(snapshot.repositories, matchingQuery: query).first(where: {
            $0.commonGitDirectoryURL?.standardizedFileURL == commonGitDirectoryURL.standardizedFileURL
        })?.id ?? repositoryID
    }
    func indexRepositoryNodes(in nodes: [Node]) {
        for node in nodes {
            if case .repository(let repositoryID) = node.kind,
               repositoryNodesByID[repositoryID] == nil {
                repositoryNodesByID[repositoryID] = node
            }
            indexRepositoryNodes(in: node.children)
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

    private func makeFolderLevel(
        environment: FolderLevelEnvironment,
        relativePrefix: [String],
        repositories: [RepoDescriptor],
        relativeComponentsByRepositoryID: [UUID: [String]],
        repositoryNodesByID: [UUID: Node]
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
            .compactMap { repositoryNodesByID[$0.id] }
        for folderName in folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let folderComponents = relativePrefix + [folderName]
            let folderPath = folderComponents.joined(separator: "/")
            let folderURL = environment.sourceURL.appendingPathComponent(folderPath, isDirectory: true)
            nodes.append(Node(
                title: folderName,
                subtitle: folderURL.path,
                kind: .folder(sourceID: environment.sourceID, relativePath: folderPath)
            ))
            nodes.append(contentsOf: makeFolderLevel(
                environment: environment,
                relativePrefix: folderComponents,
                repositories: folders[folderName] ?? [],
                relativeComponentsByRepositoryID: relativeComponentsByRepositoryID,
                repositoryNodesByID: repositoryNodesByID
            ))
        }
        return nodes
    }

    func repositoryNode(
        _ repository: RepoDescriptor,
        snapshot: AppSnapshot,
        children: [Node] = []
    ) -> Node {
        let unavailable: Bool
        let subtitle: String
        switch repository.availability {
        case .available:
            unavailable = false
            let path = repository.canonicalURL.path
            if let message = standaloneScanMessage(for: repository, snapshot: snapshot) {
                subtitle = "\(message)\n\(path)"
            } else {
                subtitle = path
            }
        case .unavailable(let reason):
            unavailable = true
            subtitle = "\(reason)\nRight-click to re-authorize or remove this source.\n\(repository.canonicalURL.path)"
        }
        let node = Node(
            title: unavailable ? "\(repository.displayName) — Unavailable" : repository.displayName,
            subtitle: subtitle,
            kind: .repository(repository.id),
            repositoryIsUnavailable: unavailable,
            repositoryDescriptor: repository,
            children: children
        )
        node.badge = repositoryBadge(for: node, snapshot: snapshot)
        return node
    }

    func sourceBadge(_ message: String?) -> String? {
        guard let message else { return nil }
        if message.hasPrefix("Scan stopped") || message.hasPrefix("Submodule scan stopped") {
            return "Scan limited"
        }
        if message.hasPrefix("Access unavailable") { return "Action needed" }
        return "Warning"
    }

    private func expandAncestors(of node: Node) {
        guard let parent = node.parent else { return }
        expandAncestors(of: parent)
        outlineView.expandItem(parent)
    }
    func row(for repositoryID: UUID) -> Int? {
        guard let node = repositoryNodesByID[repositoryID] else { return nil }
        expandAncestors(of: node)
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
