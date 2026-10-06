import Foundation

nonisolated enum SidebarSnapshotUpdate: Sendable, Equatable {
    case structural
    case repositoryBadge(UUID)
    case none
}

@MainActor
struct AppSnapshot {
    let state: PersistedState
    let repositories: [RepoDescriptor]
    let scanMessages: [UUID: String]
    let runtime: RepositoryRuntimeSnapshot
    let selectedSession: SelectedRepositorySessionSnapshot
    let mutationState: RepositoryMutationState
    let commitMessage: String
    let usesDefaultCommitMessage: Bool
    let amendSession: AppCoordinator.AmendSession?
    let errorMessage: String?
    let stateSaveErrorMessage: String?
    let statusMessage: String?
    let hasLoadedState: Bool
    let hasStarted: Bool
    let sidebarUpdate: SidebarSnapshotUpdate

    init(
        state: PersistedState,
        repositories: [RepoDescriptor],
        scanMessages: [UUID: String],
        runtime: RepositoryRuntimeSnapshot,
        selectedSession: SelectedRepositorySessionSnapshot,
        mutationState: RepositoryMutationState,
        commitMessage: String,
        usesDefaultCommitMessage: Bool,
        amendSession: AppCoordinator.AmendSession?,
        errorMessage: String?,
        stateSaveErrorMessage: String?,
        statusMessage: String?,
        hasLoadedState: Bool,
        hasStarted: Bool,
        sidebarUpdate: SidebarSnapshotUpdate = .structural
    ) {
        self.state = state
        self.repositories = repositories
        self.scanMessages = scanMessages
        self.runtime = runtime
        self.selectedSession = selectedSession
        self.mutationState = mutationState
        self.commitMessage = commitMessage
        self.usesDefaultCommitMessage = usesDefaultCommitMessage
        self.amendSession = amendSession
        self.errorMessage = errorMessage
        self.stateSaveErrorMessage = stateSaveErrorMessage
        self.statusMessage = statusMessage
        self.hasLoadedState = hasLoadedState
        self.hasStarted = hasStarted
        self.sidebarUpdate = sidebarUpdate
    }
}