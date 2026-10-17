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
        case .catalogReconciled, .eventCoverage:
            publish()
        case .action(.rescanSource(let sourceID)):
            catalog.rescanSource(sourceID)
        case .status(let event, let historyInvalidated):
            handleStatusEvent(event, historyInvalidated: historyInvalidated)
        }
    }

    private func handleStatusEvent(_ event: RefreshSchedulerEvent, historyInvalidated: Bool) {
        let repositoryID = event.repositoryID
        let isSelected = state.uiState.selectedRepoID == repositoryID
        handleSelectedStatusEvent(event, isSelected: isSelected)
        if historyInvalidated,
           state.uiState.mode == .history,
           isSelected {
            clearSelectedHistory()
            loadNextHistoryPage()
        }
        publish(sidebarUpdate: sidebarUpdate(for: event, repositoryID: repositoryID))
    }

    private func handleSelectedStatusEvent(_ event: RefreshSchedulerEvent, isSelected: Bool) {
        guard isSelected else { return }
        switch event {
        case .queued, .running:
            _ = selectedSession.beginDiff(state: .loading)
        case .completed(_, _, let status, _):
            if state.uiState.mode == .changes { updateDefaultCommitMessage(for: status) }
            clearSelectedDiff()
        case .completedWithFailure(_, _, let status, let failure, _):
            if state.uiState.mode == .changes { updateDefaultCommitMessage(for: status) }
            clearSelectedDiff()
            selectedDiffState = .failed(failure)
        case .failed(_, _, let failure, _):
            _ = selectedSession.beginDiff(state: .failed(failure))
        case .cancelled:
            break
        }
    }
    private func sidebarUpdate(
        for event: RefreshSchedulerEvent,
        repositoryID: UUID
    ) -> SidebarSnapshotUpdate {
        let isSubmoduleRelated = repositories.contains {
            $0.id == repositoryID && $0.submoduleParentRepositoryID != nil
        } || repositories.contains {
            $0.submoduleParentRepositoryID == repositoryID
        }
        guard isSubmoduleRelated else { return .repositoryBadge(repositoryID) }
        switch event {
        case .queued, .running:
            return .repositoryBadge(repositoryID)
        case .completed, .completedWithFailure, .failed, .cancelled:
            return .submoduleActivity
        }
    }
}

private extension RefreshSchedulerEvent {
    var repositoryID: UUID {
        switch self {
        case .queued(let key, _),
             .running(let key, _),
             .completed(let key, _, _, _),
             .completedWithFailure(let key, _, _, _, _),
             .failed(let key, _, _, _),
             .cancelled(let key, _, _):
            key.repositoryID
        }
    }
}
