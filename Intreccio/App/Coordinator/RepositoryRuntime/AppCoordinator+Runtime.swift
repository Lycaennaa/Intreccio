import Foundation

@MainActor
extension AppCoordinator: RepositoryRuntimeControllerDelegate {
    var repositoryRuntimeContext: RepositoryRuntimeContext {
        RepositoryRuntimeContext(
            state: state,
            repositories: repositories,
            isShuttingDown: isShuttingDown,
            repositoryIndex: catalog.repositoryIndex
        )
    }

    func repositoryRuntimeController(
        _ controller: RepositoryRuntimeController,
        didChange change: RepositoryRuntimeChange
    ) {
        guard !isShuttingDown else { return }
        switch change {
        case .githubURL:
            publish(sidebarUpdate: .none)

        case .catalogReconciled:
            publish()
        case .eventCoverage:
            publish()
        case .action(let action):
            switch action {
            case .rescanSource(let sourceID):
                catalog.rescanSource(sourceID)
            }

        case .status(let event, let historyInvalidated):
            let repositoryID: UUID
            switch event {
            case .queued(let key, _),
                 .running(let key, _),
                 .completed(let key, _, _),
                 .completedWithFailure(let key, _, _, _),
                 .failed(let key, _, _),
                 .cancelled(let key, _):
                repositoryID = key.repositoryID
            }
            let isSelected = state.uiState.selectedRepoID == repositoryID
            switch event {
            case .queued, .running:
                if isSelected { _ = selectedSession.beginDiff(state: .loading) }

            case .completed(_, _, let status):
                if isSelected {
                    if state.uiState.mode == .changes { updateDefaultCommitMessage(for: status) }
                    clearSelectedDiff()
                }

            case .completedWithFailure(_, _, let status, let failure):
                if isSelected {
                    if state.uiState.mode == .changes { updateDefaultCommitMessage(for: status) }
                    clearSelectedDiff()
                    selectedDiffState = .failed(failure)
                }

            case .failed(_, _, let failure):
                if isSelected { _ = selectedSession.beginDiff(state: .failed(failure)) }

            case .cancelled:
                break
            }
            if historyInvalidated,
               state.uiState.mode == .history,
               isSelected {
                clearSelectedHistory()
                loadNextHistoryPage()
            }
            publish(sidebarUpdate: .repositoryBadge(repositoryID))
        }
    }
}
