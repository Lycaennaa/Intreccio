import Foundation

nonisolated enum GitHubURLRefreshError: Error, Sendable {
    case superseded
}

@MainActor
final class AppCoordinator {
    struct AmendSession {
        let repositoryID: UUID
        let commit: Commit
        let previousMessage: String
        let previousUsesDefaultMessage: Bool
    }


    let gitService: GitService
    let catalog: RepositoryCatalog
    let runtime: RepositoryRuntimeController
    let selectedSession = SelectedRepositorySession()
    private(set) var snapshot: AppSnapshot

    var startupTask: Task<Void, Never>?
    var mutationTask: Task<Void, Never>?
    var mutationID: UUID?
    var mutationGeneration: UInt64 = 0

    var isShuttingDown = false
    var uiSaveTask: Task<Void, Never>?
    var rememberedApplicationSaveTask: Task<Void, Never>?

    var state = PersistedState()
    var repositories: [RepoDescriptor] { catalog.repositories }
    var githubURLs: RepositorySnapshotMap<URL> { runtime.snapshot.githubURLs }
    var errorMessage: String?
    var stateSaveErrorMessage: String?
    var statusMessage: String?
    var scanMessages: [UUID: String] { catalog.scanMessages }
    var repositoryRefreshStates: RepositorySnapshotMap<RepositoryRefreshState> { runtime.snapshot.refreshStates }
    var selectedDiffState: SelectedDiffState {
        get { selectedSession.diffState }
        set { selectedSession.diffState = newValue }
    }
    var historyScope: HistoryScope {
        get { selectedSession.historyScope }
        set { selectedSession.historyScope = newValue }
    }
    var selectedHistoryState: SelectedHistoryState {
        get { selectedSession.historyState }
        set { selectedSession.historyState = newValue }
    }
    var selectedCommitState: SelectedCommitState {
        get { selectedSession.commitState }
        set { selectedSession.commitState = newValue }
    }
    var mutationState: RepositoryMutationState = .idle
    var commitMessage = ""
    var usesDefaultCommitMessage = true
    var amendSession: AmendSession?
    var hasLoadedState = false
    var hasStarted = false
    static let activationRescanStaleness: Duration = .seconds(60)
    var lastFullRescanAt: ContinuousClock.Instant?
    private var snapshotHandlers: [UUID: (AppSnapshot) -> Void] = [:]

    @discardableResult
    func addSnapshotHandler(_ handler: @escaping (AppSnapshot) -> Void) -> UUID {
        let id = UUID()
        snapshotHandlers[id] = handler
        return id
    }

    func removeSnapshotHandler(_ id: UUID) {
        snapshotHandlers[id] = nil
    }

    #if DEBUG
    var snapshotHandlerCountForTesting: Int { snapshotHandlers.count }
    #endif

    func publishSnapshot(_ snapshot: AppSnapshot) {
        self.snapshot = snapshot
        for handler in Array(snapshotHandlers.values) { handler(snapshot) }
    }

    var hasActiveMutation: Bool { mutationTask != nil }
    var isAmendingCommit: Bool { amendSession != nil }
    var selectedDiffRenderGeneration: UInt64 { selectedSession.diffGeneration }
    var selectedCommitRenderGeneration: UInt64 { selectedSession.commitGeneration }
    var activeRepositoryEventWatcherIDs: Set<UUID> { runtime.snapshot.activeRepositoryEventWatcherIDs }

    var selectedRepositoryIsAvailable: Bool {
        guard let selectedID = state.uiState.selectedRepoID else { return false }
        return repositories.contains { $0.id == selectedID && $0.availability == .available }
    }

    init(
        stateStore: StateStore = StateStore(),
        bookmarkStore: BookmarkStore = BookmarkStore(),
        scanner: RepoScanner = RepoScanner(),
        gitService: GitService = GitService(),
        repositoryCatalogFixture: RepositoryCatalogFixture? = nil
    ) {
        self.gitService = gitService
        catalog = RepositoryCatalog(
            stateStore: stateStore,
            bookmarkStore: bookmarkStore,
            scanner: scanner,
            gitService: gitService,
            fixture: repositoryCatalogFixture
        )
        runtime = RepositoryRuntimeController(gitService: gitService)
        snapshot = AppSnapshot(
            state: state,
            repositories: catalog.repositories,
            scanMessages: catalog.scanMessages,
            runtime: runtime.snapshot,
            selectedSession: selectedSession.snapshot,
            mutationState: mutationState,
            commitMessage: commitMessage,
            usesDefaultCommitMessage: usesDefaultCommitMessage,
            amendSession: amendSession,
            errorMessage: errorMessage,
            stateSaveErrorMessage: stateSaveErrorMessage,
            statusMessage: statusMessage,
            hasLoadedState: hasLoadedState,
            hasStarted: hasStarted
        )
        catalog.delegate = self
        runtime.delegate = self

    }

    deinit {
        startupTask?.cancel()
        mutationTask?.cancel()
        uiSaveTask?.cancel()
        rememberedApplicationSaveTask?.cancel()
    }

    func start() {
        guard !isShuttingDown else { return }
        hasStarted = true
        startupTask?.cancel()
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await catalog.startup()
            } catch is CancellationError {
            } catch {
                guard !isShuttingDown else { return }
                setStateSaveError("Sources loaded, but updated state could not be saved: \(error)")
            }
            startupTask = nil
        }
    }
}

