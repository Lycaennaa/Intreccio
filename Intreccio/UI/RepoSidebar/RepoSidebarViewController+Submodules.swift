import AppKit

@MainActor
extension RepoSidebarViewController {
    struct RepositoryTreeContext {
        let snapshot: AppSnapshot
        let childrenByParentID: [UUID: [RepoDescriptor]]
        let matchingRepositoryIDs: Set<UUID>
        let isSearching: Bool
    }

    func makeRepositoryTreeNode(
        _ repository: RepoDescriptor,
        context: RepositoryTreeContext,
        showCleanSubmodules: Bool = false,
        isSubmodule: Bool = false
    ) -> Node? {
        guard !isSubmodule || repository.availability == .available else { return nil }
        let snapshot = context.snapshot
        let revealsCleanSubmodules = showCleanSubmodules
            || snapshot.state.uiState.showCleanSubmoduleRepositoryIDs.contains(repository.id)
        let children = (context.childrenByParentID[repository.id] ?? [])
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .compactMap { child in
                makeRepositoryTreeNode(
                    child,
                    context: context,
                    showCleanSubmodules: revealsCleanSubmodules,
                    isSubmodule: true
                )
            }
        let matchesSearch = context.matchingRepositoryIDs.contains(repository.id)
        if context.isSearching, !matchesSearch, children.isEmpty { return nil }
        let hasSubmoduleActivity = isSubmodule && submoduleActivity(
            for: repository,
            snapshot: snapshot
        ).hasActivity
        let showRepository = !isSubmodule
            || revealsCleanSubmodules
            || hasSubmoduleActivity
            || snapshot.state.uiState.pinnedRepositoryIDs.contains(repository.id)
            || (context.isSearching && matchesSearch)
        guard showRepository || !children.isEmpty else { return nil }
        return repositoryNode(repository, snapshot: snapshot, children: children)
    }

    func repositoryBadge(for node: Node, snapshot: AppSnapshot) -> String? {
        guard case .repository(let repositoryID) = node.kind else { return nil }
        var indicators = [String]()
        if node.repositoryIsUnavailable {
            indicators.append("Unavailable")
        } else {
            if let statusBadge = repositoryContentBadge(for: node, snapshot: snapshot) {
                indicators.append(statusBadge)
            }
            switch snapshot.runtime.refreshStates[repositoryID]?.phase {
            case .queued: indicators.append("Queued")
            case .running: indicators.append("Refreshing")
            case .failed: indicators.append("Error")
            case .idle, .none: break
            }
        }
        if !node.repositoryIsUnavailable,
           let repository = node.repositoryDescriptor,
           let message = standaloneScanMessage(for: repository, snapshot: snapshot),
           let badge = sourceBadge(message) {
            indicators.append(badge)
        }
        if !outlineView.isItemExpanded(node) {
            let affectedDescendantCount = descendantActivityCount(for: node, snapshot: snapshot)
            if affectedDescendantCount > 0 {
                let label = affectedDescendantCount == 1 ? "submodule" : "submodules"
                indicators.append("\(affectedDescendantCount) \(label)")
            }
        }
        return indicators.isEmpty ? nil : indicators.joined(separator: " · ")
    }

    private func repositoryContentBadge(for node: Node, snapshot: AppSnapshot) -> String? {
        guard case .repository(let repositoryID) = node.kind else { return nil }
        if let repository = node.repositoryDescriptor,
           repository.submoduleParentRepositoryID != nil {
            return submoduleActivity(for: repository, snapshot: snapshot).sidebarBadge
        }
        return snapshot.runtime.refreshStates[repositoryID]?.sidebarBadge
    }
    func standaloneScanMessage(
        for repository: RepoDescriptor,
        snapshot: AppSnapshot
    ) -> String? {
        guard repository.submoduleParentRepositoryID == nil,
              case .standalone = repository.source else { return nil }
        return snapshot.scanMessages[repository.source.id]
    }

    func submoduleActivity(
        for repository: RepoDescriptor,
        snapshot: AppSnapshot
    ) -> RepositorySubmoduleActivity {
        let parentState = repository.submoduleParentRepositoryID
            .flatMap { snapshot.runtime.refreshStates[$0] }
        return RepositorySubmoduleActivity(
            childState: snapshot.runtime.refreshStates[repository.id],
            parentState: parentState,
            submodulePath: repository.submodulePath
        )
    }

    func descendantActivityCount(for node: Node, snapshot: AppSnapshot) -> Int {
        node.children.reduce(into: 0) { count, child in
            if let repository = child.repositoryDescriptor,
               repository.submoduleParentRepositoryID != nil,
               submoduleActivity(for: repository, snapshot: snapshot).hasActivity {
                count += 1
            }
            count += descendantActivityCount(for: child, snapshot: snapshot)
        }
    }
}
