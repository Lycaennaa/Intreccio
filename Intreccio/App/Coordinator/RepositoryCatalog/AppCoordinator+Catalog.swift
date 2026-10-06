import Foundation

@MainActor
extension AppCoordinator: RepositoryCatalogDelegate {
    var repositoryCatalogState: PersistedState { state }

    func repositoryCatalogWillBeginSourceCommand() {
        uiSaveTask?.cancel()
    }

    func repositoryCatalog(didLoad result: StateLoadResult) -> PersistedState? {
        guard !Task.isCancelled, !isShuttingDown else { return nil }
        state = result.state
        errorMessage = result.recoveryMessage
        hasLoadedState = true
        seedDefaultFolderApplicationsIfNeeded()
        guard !Task.isCancelled, !isShuttingDown else { return nil }
        publish()
        return state
    }

    func repositoryCatalog(reconcile change: CatalogChange) -> PersistedState {
        if let selected = state.uiState.selectedRepoID,
           !change.repositoryIDs.contains(selected) {
            cancelSelectedMutation(clearMessage: true)
        }
        assignPersistedState(change.state) {
            change.effect.uiReconciliation.apply(to: &$0, repositoryIDs: change.repositoryIDs)
        }
        if change.effect.messagePolicy.clearsStatusMessage {
            statusMessage = nil
        }
        if change.effect.messagePolicy.clearsErrorMessage {
            errorMessage = nil
        }
        if change.effect.uiReconciliation.invalidatesSelectedRepositoryWork {
            invalidateSelectedRepositoryWorkIfUnavailable(in: change.repositories)
        }
        publish()
        if let sourceID = change.effect.sourceRescanCancellationID {
            catalog.cancelSourceRescan(sourceID)
        }
        return state
    }

    func repositoryCatalog(didCommit result: CatalogCommitResult) async {
        await runtime.applyCatalogChange(result.change)
        if result.change.effect.isFullSourceRescan {
            lastFullRescanAt = ContinuousClock.now
        }
        if result.persistenceStatus == .succeeded,
           result.clearsPersistenceErrorOnSuccess,
           !isShuttingDown {
            clearStateSaveError()
        }
    }

    func repositoryCatalog(didFail failure: RepositoryCatalogFailure) {
        guard !isShuttingDown else { return }
        switch failure {
        case .sourcesPersistence(let message):
            setStateSaveError("Sources loaded, but updated state could not be saved: \(message)")
        case .sourceRescanPersistence(let message):
            setStateSaveError("Source rescanned, but updated state could not be saved: \(message)")
        }
    }
}
