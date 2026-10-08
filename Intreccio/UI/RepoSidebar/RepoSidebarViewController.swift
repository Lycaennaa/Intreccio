import AppKit

@MainActor
final class RepoSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    struct TreeCacheKey: Equatable {
        let searchText: String
        let repositories: [RepoDescriptor]
        let watchRoots: [WatchRoot]
        let standaloneRepos: [StandaloneRepository]
        let pinnedRepositoryIDs: Set<UUID>
        let scanMessages: [UUID: String]
    }

    enum NodeKind: Equatable {
        case root(UUID)
        case folder(sourceID: UUID, relativePath: String)
        case pinnedSection
        case standaloneSection
        case repository(UUID)
    }

    final class Node {
        let title: String
        let subtitle: String?
        var badge: String?
        let kind: NodeKind
        let repositoryIsUnavailable: Bool

        init(
            title: String,
            subtitle: String? = nil,
            badge: String? = nil,
            kind: NodeKind,
            repositoryIsUnavailable: Bool = false
        ) {
            self.title = title
            self.subtitle = subtitle
            self.badge = badge
            self.kind = kind
            self.repositoryIsUnavailable = repositoryIsUnavailable
        }
    }

    let coordinator: AppCoordinator
    let menuController: RepoSidebarMenuController
    let githubMenuController: RepoSidebarGitHubMenuController
    let applicationController: RepoSidebarApplicationController
    let outlineView = NSOutlineView()
    let searchField = NSSearchField()
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let emptyLabel = NSTextField(labelWithString: "Add a folder or repository to begin.")
    var roots: [Node] = []
    var treeCacheKey: TreeCacheKey?
    var repositoryNodesByID: [UUID: Node] = [:]
#if DEBUG
    var treeBuildCountForTesting = 0
    var outlineReloadCountForTesting = 0
    var badgeUpdateCountForTesting = 0
#endif

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let githubMenuController = RepoSidebarGitHubMenuController(coordinator: coordinator)
        let applicationController = RepoSidebarApplicationController(coordinator: coordinator)
        self.githubMenuController = githubMenuController
        self.applicationController = applicationController
        self.menuController = RepoSidebarMenuController(
            coordinator: coordinator,
            githubMenuController: githubMenuController,
            applicationController: applicationController
        )
        super.init(nibName: nil, bundle: nil)

    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard outlineView.menu === menu,
              outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? Node else {
            menuController.clearMenu(menu)
            return
        }
        let repositoryIDs: [UUID]
        if case .repository = node.kind {
            if outlineView.selectedRowIndexes.contains(outlineView.clickedRow) {
                repositoryIDs = self.repositoryIDs(in: outlineView.selectedRowIndexes)
            } else {
                outlineView.selectRowIndexes(
                    IndexSet(integer: outlineView.clickedRow),
                    byExtendingSelection: false
                )
                repositoryIDs = self.repositoryIDs(in: outlineView.selectedRowIndexes)
            }
        } else {
            repositoryIDs = []
        }
        menuController.populateMenu(with: RepoSidebarMenuContext(
            menu: menu,
            node: node,
            repositoryIDs: repositoryIDs,
            presentingWindow: isViewLoaded ? view.window : nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func cancelOperationsForTermination() -> [Task<Void, Never>] {
        menuController.cancelOperationsForTermination()
            + githubMenuController.cancelOperationsForTermination()
    }

    func resumeOperationsAfterFailedTermination() {
        menuController.resumeOperationsAfterFailedTermination()
    }

    override func loadView() {
        treeCacheKey = nil
        repositoryNodesByID.removeAll(keepingCapacity: true)
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.setAccessibilityLabel("Repositories")

        searchField.placeholderString = "Search repositories"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search repositories by name or path")

        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.maximumNumberOfLines = 6
        errorLabel.isSelectable = true
        errorLabel.isHidden = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Repository"))
        column.title = "Repositories"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.indentationPerLevel = 0
        outlineView.headerView = nil
        outlineView.backgroundColor = .black
        outlineView.rowSizeStyle = .medium
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsMultipleSelection = true
        outlineView.focusRingType = .none
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel("Repository sources")

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        for child in [searchField, errorLabel, scrollView, emptyLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            errorLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            errorLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16)
        ])
        view = container
        reload()
    }

}
