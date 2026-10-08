import AppKit

@MainActor
extension ChangesViewController {
    func makeGroups(_ changes: [FileChange]) -> [Node] {
#if DEBUG
        treeBuildCountForTesting += 1
#endif
        var groups: [(String, [[FileChange]])] = [
            ("Conflicted", []),
            ("Dual State", []),
            ("Staged", []),
            ("Unstaged", []),
            ("Untracked", [])
        ]
        let rows = Dictionary(grouping: changes.filter { $0.kind != .ignored }, by: \.gitPath).values
        for row in rows {
            let index: Int
            let staged = row.contains(where: \.hasStagedChange)
            let unstaged = row.contains(where: \.hasUnstagedChange)
            if row.contains(where: { $0.kind == .unmerged }) { index = 0 } else if staged, unstaged { index = 1 } else if staged { index = 2 } else if row.allSatisfy({ $0.kind == .untracked }) { index = 4 } else { index = 3 }
            groups[index].1.append(Array(row))
        }
        return groups.compactMap { title, rows in
            guard !rows.isEmpty else { return nil }
                let children = rows.sorted { $0[0].displayPath.localizedStandardCompare($1[0].displayPath) == .orderedAscending }.map { row in
                    let change = row[0]
                    let title = change.displayOriginalPath.map { "\($0) → \(change.displayPath)" } ?? change.displayPath
                return Node(title: title, badge: stateBadge(row), kind: .changes(row))
            }
            return Node(title: title, badge: String(children.count), kind: .group, children: children)
        }
    }

    func stateBadge(_ changes: [FileChange]) -> String {
        if changes.contains(where: { $0.kind == .unmerged }) { return "U" }
        let staged = changes.first(where: \.hasStagedChange)
        let unstaged = changes.first(where: \.hasUnstagedChange)
        let index = staged.map { $0.indexState == .unmodified ? "D" : $0.indexState.rawValue } ?? "·"
        let worktree = unstaged.map { $0.kind == .untracked ? "?" : ($0.worktreeState == .unmodified ? "M" : $0.worktreeState.rawValue) } ?? "·"
        return index + worktree
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if case .group = node.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if case .changes = node.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        return Self.makeChangeCell(title: node.title, badgeText: node.badge)
    }

    static func makeChangeCell(title: String, badgeText: String?) -> NSTableCellView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: title)
        let badge = NSTextField(labelWithString: badgeText ?? "")
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.addSubview(badge)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.toolTip = title
        cell.setAccessibilityLabel(badgeText.map { "\(title), status \($0)" } ?? title)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionChange else { return }
        configureMutationControls(status: selectedStatus)
        onSelectionChange?(selectedGitPaths)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0,
              let node = outlineView.item(atRow: clickedRow) as? Node,
              case .changes(let clickedChanges) = node.kind,
              let clickedGitPath = clickedChanges.first?.gitPath else { return }
        let path = clickedGitPath.decodedString
        let displayPath = clickedGitPath.displayString

        let contextChanges = Self.contextMenuChanges(
            clickedChanges: clickedChanges,
            selectedChanges: selectedChanges,
            clickedRowIsSelected: outlineView.selectedRowIndexes.contains(clickedRow)
        )
        let contextPaths = Array(Set(contextChanges.map(\.displayPath))).sorted()
        applicationActionsController.addOpenApplicationMenu(
            to: menu,
            fileOpenAction: applicationActionsController.makeFileOpenAction(changes: contextChanges)
        )
        menu.addItem(.separator())
        let revealSelection = applicationActionsController.makeFileRevealSelection(changes: contextChanges)
        let revealItem = addContextMenuItem(
            "Reveal in Finder",
            action: #selector(ChangesApplicationActionsController.revealChange(_:)),
            representedObject: revealSelection ?? NSNull(),
            target: applicationActionsController,
            to: menu
        )
        revealItem.isEnabled = revealSelection != nil
        menu.addItem(.separator())

        let status = selectedStatus
        updateMutationContext(status: status)
        let running = coordinator.mutationState == .running
        let stageTitle = contextPaths.count == 1 ? "Stage File" : "Stage \(contextPaths.count) Files"
        let stageFile = addContextMenuItem(
            stageTitle,
            action: #selector(ChangesMutationController.stageChange(_:)),
            representedObject: contextChanges,
            target: mutationController,
            to: menu
        )
        stageFile.isEnabled = ChangesMutationPolicy.canStage(
            changes: contextChanges,
            status: status,
            mutationRunning: running
        )

        let folders = GitIgnoreWriter.ancestorFolders(for: path)
        if !folders.isEmpty {
            let folderMenu = NSMenu()
            let statusChanges = status?.changes ?? []
            for folder in folders {
                let folderChanges = ChangesMutationPolicy.changes(statusChanges, inFolder: folder)
                let item = addContextMenuItem(
                    GitPath(folder).displayString + "/",
                    action: #selector(ChangesMutationController.stageFolder(_:)),
                    representedObject: folder,
                    target: mutationController,
                    to: folderMenu
                )
                item.isEnabled = ChangesMutationPolicy.canStage(
                    changes: folderChanges,
                    status: status,
                    mutationRunning: running
                )
            }
            let item = NSMenuItem(title: "Stage Folder", action: nil, keyEquivalent: "")
            item.submenu = folderMenu
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let discardFile = addContextMenuItem(
            "Discard Changes…",
            action: #selector(ChangesMutationController.discardChange(_:)),
            representedObject: contextChanges,
            target: mutationController,
            to: menu
        )
        discardFile.isEnabled = ChangesMutationPolicy.canDiscard(
            changes: contextChanges,
            status: status,
            mutationRunning: running
        )

        guard contextPaths.count == 1,
              ChangesMutationPolicy.canIgnoreSelection(clickedChanges) else { return }
        menu.addItem(.separator())
        let ignoreMenu = NSMenu()
        if let directory = GitIgnoreWriter.directoryTarget(for: path) {
            let action = IgnoreAction(
                selectedGitPath: clickedGitPath,
                targetGitPath: GitPath(directory),
                isDirectory: true
            )
            let item = addContextMenuItem(
                "Folder — " + GitPath(directory).displayString + "/",
                action: #selector(ChangesMutationController.addToGitIgnore(_:)),
                representedObject: action,
                target: mutationController,
                to: ignoreMenu
            )
            item.isEnabled = ChangesMutationPolicy.canIgnore(
                selectedChanges: clickedChanges,
                selectedPath: path,
                targetPath: directory,
                isDirectory: true,
                status: status,
                mutationRunning: running
            )
        } else {
            let action = IgnoreAction(
                selectedGitPath: clickedGitPath,
                targetGitPath: clickedGitPath,
                isDirectory: false
            )
            let item = addContextMenuItem(
                "File — " + displayPath,
                action: #selector(ChangesMutationController.addToGitIgnore(_:)),
                representedObject: action,
                target: mutationController,
                to: ignoreMenu
            )
            item.isEnabled = ChangesMutationPolicy.canIgnore(
                selectedChanges: clickedChanges,
                selectedPath: path,
                targetPath: path,
                isDirectory: false,
                status: status,
                mutationRunning: running
            )
        }
        let statusChanges = status?.changes ?? []
        for folder in folders {
            let folderChanges = ChangesMutationPolicy.changes(statusChanges, inFolder: folder)
            let action = IgnoreAction(
                selectedGitPath: clickedGitPath,
                targetGitPath: GitPath(folder),
                isDirectory: true
            )
            let item = addContextMenuItem(
                "Folder — " + GitPath(folder).displayString + "/",
                action: #selector(ChangesMutationController.addToGitIgnore(_:)),
                representedObject: action,
                target: mutationController,
                to: ignoreMenu
            )
            item.isEnabled = ChangesMutationPolicy.canIgnore(
                selectedChanges: clickedChanges,
                selectedPath: path,
                targetPath: folder,
                isDirectory: true,
                status: status,
                mutationRunning: running,
                targetChanges: folderChanges
            )
        }
        let ignoreItem = NSMenuItem(title: "Add to .gitignore", action: nil, keyEquivalent: "")
        ignoreItem.submenu = ignoreMenu
        menu.addItem(ignoreItem)
    }

    @discardableResult
    func addContextMenuItem(
        _ title: String,
        action: Selector,
        representedObject: Any,
        target: AnyObject? = nil,
        to menu: NSMenu
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        item.representedObject = representedObject
        menu.addItem(item)
        return item
    }
}
