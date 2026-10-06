import AppKit

@MainActor
final class RepoSidebarJustMenuController: NSObject {
    typealias RecipeTarget = RepoSidebarJustMenuSingleImplementation.RecipeTarget
    typealias CreateTarget = RepoSidebarJustMenuSingleImplementation.CreateTarget
    typealias CreateAllTarget = RepoSidebarJustMenuImplementation.CreateAllTarget
    typealias SelectedRecipeTarget = RepoSidebarJustMenuImplementation.SelectedRecipeTarget

    static let justWebsiteURLString = RepoSidebarJustMenuSingleImplementation.justWebsiteURLString

    private let implementation: RepoSidebarJustMenuImplementation

    init(
        coordinator: AppCoordinator,
        applicationController: RepoSidebarApplicationController
    ) {
        implementation = RepoSidebarJustMenuImplementation(
            coordinator: coordinator,
            applicationController: applicationController
        )
        super.init()
    }

    func updateMenuContext(_ context: RepoSidebarMenuContext) {
        implementation.updateMenuContext(context)
    }

    func clearMenuContext(for menu: NSMenu) {
        implementation.clearMenuContext(for: menu)
    }

    func waitForPendingDiscovery() async {
        await implementation.waitForPendingDiscovery()
    }

    func cancelOperationsForTermination() -> [Task<Void, Never>] {
        implementation.cancelOperationsForTermination()
    }

    func resumeOperationsAfterFailedTermination() {
        implementation.resumeOperationsAfterFailedTermination()
    }

    func addMenuItems(
        to menu: NSMenu,
        repositoryID: UUID,
        context: RepoSidebarMenuContext
    ) {
        implementation.addMenuItems(to: menu, repositoryID: repositoryID, context: context, owner: self)
    }

    func addMenuItems(
        to menu: NSMenu,
        repositoryIDs: [UUID],
        context: RepoSidebarMenuContext
    ) {
        implementation.addMenuItems(to: menu, repositoryIDs: repositoryIDs, context: context, owner: self)
    }

    @objc func runRecipe(_ sender: NSMenuItem) {
        implementation.runRecipe(sender)
    }

    @objc func runSelectedRecipe(_ sender: NSMenuItem) {
        implementation.runSelectedRecipe(sender)
    }

    @objc func createJustfile(_ sender: NSMenuItem) {
        implementation.createJustfile(sender)
    }

    @objc func createJustfiles(_ sender: NSMenuItem) {
        implementation.createJustfiles(sender)
    }

    @objc func showJustInfo(_ sender: NSMenuItem) {
        implementation.showJustInfo(sender)
    }

    @objc func showJustInfoForSelection(_ sender: NSMenuItem) {
        implementation.showJustInfoForSelection(sender)
    }
}