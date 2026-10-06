import AppKit

@MainActor
final class RepoSidebarMenuContext {
    weak var menu: NSMenu?
    let node: RepoSidebarViewController.Node
    let repositoryIDs: [UUID]
    weak var presentingWindow: NSWindow?

    init(
        menu: NSMenu,
        node: RepoSidebarViewController.Node,
        repositoryIDs: [UUID],
        presentingWindow: NSWindow?
    ) {
        self.menu = menu
        self.node = node
        self.repositoryIDs = repositoryIDs
        self.presentingWindow = presentingWindow
    }

    var repositoryID: UUID? {
        guard case .repository(let nodeRepositoryID) = node.kind,
              repositoryIDs.contains(nodeRepositoryID) else { return nil }
        return repositoryIDs.first
    }
}