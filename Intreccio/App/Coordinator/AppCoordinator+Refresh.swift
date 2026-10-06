import Foundation

@MainActor
extension AppCoordinator {
    func invalidateSelectedRepositoryWorkIfUnavailable(in repositories: [RepoDescriptor]) {
        let selectedRepositoryIsAvailable = state.uiState.selectedRepoID.map { selectedID in
            repositories.contains {
                $0.id == selectedID && $0.availability == .available
            }
        } ?? false
        guard !selectedRepositoryIsAvailable else { return }
        selectedSession.replaceLoadTask(with: nil)
        clearSelectedDiff()
        clearSelectedHistory()
    }
}
