import Foundation

nonisolated struct CatalogMessagePolicy: Sendable, Equatable {
    let clearsStatusMessage: Bool
    let clearsErrorMessage: Bool
}

nonisolated enum CatalogRepositoryUIReconciliation {
    static func removeMissingRepositories(
        from uiState: inout PersistedUIState,
        repositoryIDs: Set<UUID>
    ) {
        uiState.pinnedRepositoryIDs.formIntersection(repositoryIDs)
        if let selected = uiState.selectedRepoID, !repositoryIDs.contains(selected) {
            uiState.selectedRepoID = nil
        }
        uiState.quickOpenFileAssignments.removeAll { !repositoryIDs.contains($0.repositoryID) }
    }
}

nonisolated struct CatalogUIReconciliation: Sendable, Equatable {
    let invalidatesSelectedRepositoryWork: Bool

    func apply(to uiState: inout PersistedUIState, repositoryIDs: Set<UUID>) {
        CatalogRepositoryUIReconciliation.removeMissingRepositories(
            from: &uiState,
            repositoryIDs: repositoryIDs
        )
    }
}

nonisolated enum CatalogRuntimeStep: Sendable, Equatable {
    case setSelectedRepository
    case scheduleGitHubURLLookups(target: Target, forceRefresh: Bool)
    case enqueueStatusRefreshes(target: Target, refreshUpstream: Bool)
    case reconcileRepositories(updateEventCoverage: Bool)
    case removeRepositories(
        clearRequestState: Bool,
        synchronizeSelectedRepository: Bool
    )
    case updateEventCoverage

    enum Target: Sendable, Equatable {
        case changed
        case all
    }
}

nonisolated struct CatalogEffectPlan: Sendable, Equatable {
    let changedRepositoryIDs: [UUID]
    let removedRepositoryIDs: [UUID]
    let uiReconciliation: CatalogUIReconciliation
    let messagePolicy: CatalogMessagePolicy
    let sourceRescanCancellationID: UUID?
    let runtimeSteps: [CatalogRuntimeStep]
    var isFullSourceRescan: Bool {
        runtimeSteps.contains {
            if case .setSelectedRepository = $0 { return true }
            return false
        }
    }

    static func startupRestored(
        changedRepositoryIDs: [UUID],
        refreshUpstream: Bool,
        clearsStatusMessage: Bool
    ) -> Self {
        makeRestored(
            changedRepositoryIDs: changedRepositoryIDs,
            refreshUpstream: refreshUpstream,
            clearsStatusMessage: clearsStatusMessage,
            githubURLTarget: .all
        )
    }

    static func restored(
        changedRepositoryIDs: [UUID],
        refreshUpstream: Bool,
        clearsStatusMessage: Bool
    ) -> Self {
        makeRestored(
            changedRepositoryIDs: changedRepositoryIDs,
            refreshUpstream: refreshUpstream,
            clearsStatusMessage: clearsStatusMessage,
            githubURLTarget: .changed
        )
    }

    private static func makeRestored(
        changedRepositoryIDs: [UUID],
        refreshUpstream: Bool,
        clearsStatusMessage: Bool,
        githubURLTarget: CatalogRuntimeStep.Target
    ) -> Self {
        Self(
            changedRepositoryIDs: changedRepositoryIDs,
            removedRepositoryIDs: [],
            uiReconciliation: CatalogUIReconciliation(invalidatesSelectedRepositoryWork: true),
            messagePolicy: CatalogMessagePolicy(
                clearsStatusMessage: clearsStatusMessage,
                clearsErrorMessage: false
            ),
            sourceRescanCancellationID: nil,
            runtimeSteps: [
                .setSelectedRepository,
                .scheduleGitHubURLLookups(target: githubURLTarget, forceRefresh: true),
                .enqueueStatusRefreshes(target: .changed, refreshUpstream: refreshUpstream),
                .reconcileRepositories(updateEventCoverage: true)
            ],
        )
    }

    static func sourceRescanned(changedRepositoryIDs: [UUID]) -> Self {
        Self(
            changedRepositoryIDs: changedRepositoryIDs,
            removedRepositoryIDs: [],
            uiReconciliation: CatalogUIReconciliation(invalidatesSelectedRepositoryWork: true),
            messagePolicy: CatalogMessagePolicy(
                clearsStatusMessage: false,
                clearsErrorMessage: false
            ),
            sourceRescanCancellationID: nil,
            runtimeSteps: [
                .scheduleGitHubURLLookups(target: .changed, forceRefresh: true),
                .reconcileRepositories(updateEventCoverage: true),
                .enqueueStatusRefreshes(target: .changed, refreshUpstream: false)
            ]
        )
    }

    static func sourceAdded() -> Self {
        Self(
            changedRepositoryIDs: [],
            removedRepositoryIDs: [],
            uiReconciliation: CatalogUIReconciliation(invalidatesSelectedRepositoryWork: false),
            messagePolicy: CatalogMessagePolicy(
                clearsStatusMessage: false,
                clearsErrorMessage: true
            ),
            sourceRescanCancellationID: nil,
            runtimeSteps: [
                .scheduleGitHubURLLookups(target: .all, forceRefresh: false),
                .updateEventCoverage,
                .enqueueStatusRefreshes(target: .all, refreshUpstream: true)
            ]
        )
    }

    static func sourceRemoved(
        sourceID: UUID,
        removedRepositoryIDs: [UUID]
    ) -> Self {
        Self(
            changedRepositoryIDs: [],
            removedRepositoryIDs: removedRepositoryIDs,
            uiReconciliation: CatalogUIReconciliation(invalidatesSelectedRepositoryWork: true),
            messagePolicy: CatalogMessagePolicy(
                clearsStatusMessage: false,
                clearsErrorMessage: true
            ),
            sourceRescanCancellationID: sourceID,
            runtimeSteps: [
                .scheduleGitHubURLLookups(target: .all, forceRefresh: false),
                .removeRepositories(
                    clearRequestState: false,
                    synchronizeSelectedRepository: false
                ),
                .updateEventCoverage
            ]
        )
    }

    static func sourceExcluded(removedRepositoryIDs: [UUID]) -> Self {
        Self(
            changedRepositoryIDs: [],
            removedRepositoryIDs: removedRepositoryIDs,
            uiReconciliation: CatalogUIReconciliation(invalidatesSelectedRepositoryWork: true),
            messagePolicy: CatalogMessagePolicy(
                clearsStatusMessage: false,
                clearsErrorMessage: false
            ),
            sourceRescanCancellationID: nil,
            runtimeSteps: [
                .scheduleGitHubURLLookups(target: .all, forceRefresh: false),
                .removeRepositories(
                    clearRequestState: true,
                    synchronizeSelectedRepository: true
                ),
                .updateEventCoverage
            ]
        )
    }

    static var exclusionRestored: Self {
        Self(
            changedRepositoryIDs: [],
            removedRepositoryIDs: [],
            uiReconciliation: CatalogUIReconciliation(invalidatesSelectedRepositoryWork: false),
            messagePolicy: CatalogMessagePolicy(
                clearsStatusMessage: false,
                clearsErrorMessage: false
            ),
            sourceRescanCancellationID: nil,
            runtimeSteps: []
        )
    }

    static var sourceReauthorized: Self {
        Self(
            changedRepositoryIDs: [],
            removedRepositoryIDs: [],
            uiReconciliation: CatalogUIReconciliation(invalidatesSelectedRepositoryWork: false),
            messagePolicy: CatalogMessagePolicy(
                clearsStatusMessage: false,
                clearsErrorMessage: true
            ),
            sourceRescanCancellationID: nil,
            runtimeSteps: [.updateEventCoverage]
        )
    }

    static var scanFailed: Self {
        Self(
            changedRepositoryIDs: [],
            removedRepositoryIDs: [],
            uiReconciliation: CatalogUIReconciliation(invalidatesSelectedRepositoryWork: false),
            messagePolicy: CatalogMessagePolicy(
                clearsStatusMessage: false,
                clearsErrorMessage: false
            ),
            sourceRescanCancellationID: nil,
            runtimeSteps: []
        )
    }
}
