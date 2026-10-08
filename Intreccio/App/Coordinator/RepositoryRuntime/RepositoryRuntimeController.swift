import Foundation

@MainActor
struct RepositoryRuntimeContext {
    let state: PersistedState
    let repositories: [RepoDescriptor]
    let repositoryIndex: RepositoryCatalogIndex
    let isShuttingDown: Bool

    init(
        state: PersistedState,
        repositories: [RepoDescriptor],
        isShuttingDown: Bool,
        repositoryIndex: RepositoryCatalogIndex? = nil
    ) {
        self.state = state
        self.repositories = repositories
        self.repositoryIndex = repositoryIndex ?? RepositoryCatalogIndex(repositories: repositories)
        self.isShuttingDown = isShuttingDown
    }
}

@MainActor
struct RepositoryRuntimeSnapshot {
    let refreshStates: RepositorySnapshotMap<RepositoryRefreshState>
    let githubURLs: RepositorySnapshotMap<URL>
    let activeRepositoryEventWatcherIDs: Set<UUID>
    let coveredRepositoryIDs: Set<UUID>

    init(
        status: RepositoryStatusRefreshSnapshot,
        github: RepositoryGitHubResolutionSnapshot,
        eventCoverage: RepositoryFileEventCoverageSnapshot
    ) {
        refreshStates = status.refreshStates
        githubURLs = github.githubURLs
        activeRepositoryEventWatcherIDs = eventCoverage.repositoryWatcherIDs
        coveredRepositoryIDs = eventCoverage.coveredRepositoryIDs
    }

    init(
        refreshStates: [UUID: RepositoryRefreshState],
        githubURLs: [UUID: URL],
        activeRepositoryEventWatcherIDs: Set<UUID>,
        coveredRepositoryIDs: Set<UUID>
    ) {
        self.init(
            status: RepositoryStatusRefreshSnapshot(
                refreshStates: refreshStates,
                statusRequestGenerations: [:],
                hasPendingEnqueueTasks: false
            ),
            github: RepositoryGitHubResolutionSnapshot(
                githubURLs: githubURLs,
                generations: [:],
                completedRepositoryIDs: [],
                hasLookupTask: false
            ),
            eventCoverage: RepositoryFileEventCoverageSnapshot(
                sourceWatcherIDs: [],
                sourceEventStreamCount: 0,
                repositoryWatcherIDs: activeRepositoryEventWatcherIDs,
                coveredRepositoryIDs: coveredRepositoryIDs,
                liveSourceWatcherIDs: [],
                liveCoveredRepositoryIDs: []
            )
        )
    }
}

@MainActor
enum RepositoryRuntimeAction {
    case rescanSource(UUID)
}

@MainActor
enum RepositoryRuntimeChange {
    case status(RefreshSchedulerEvent, historyInvalidated: Bool)
    case githubURL
    case catalogReconciled
    case eventCoverage
    case action(RepositoryRuntimeAction)
}

@MainActor
protocol RepositoryRuntimeControllerDelegate: AnyObject {
    var repositoryRuntimeContext: RepositoryRuntimeContext { get }
    func repositoryRuntimeController(
        _ controller: RepositoryRuntimeController,
        didChange change: RepositoryRuntimeChange
    )
}

@MainActor
final class RepositoryRuntimeController {
    let gitService: GitService
    private let statusRefreshController: RepositoryStatusRefreshController
    private let githubResolutionController: RepositoryGitHubResolutionController
    private let eventCoverageController: RepositoryFileEventCoverageController
    weak var delegate: (any RepositoryRuntimeControllerDelegate)?

    private var eventForwardingTasks: [Task<Void, Never>] = []

    init(
        gitService: GitService,
        githubURLLookup: (@Sendable (URL) async throws -> URL?)? = nil
    ) {
        self.gitService = gitService
        statusRefreshController = RepositoryStatusRefreshController(gitService: gitService)
        githubResolutionController = RepositoryGitHubResolutionController(
            gitService: gitService,
            githubURLLookup: githubURLLookup
        )
        eventCoverageController = RepositoryFileEventCoverageController(gitService: gitService)
        eventForwardingTasks = []
        statusRefreshController.setStatusEventHandler { [weak self] event in
            self?.handleStatusEvent(event)
        }
        let githubResolutionController = githubResolutionController
        let eventCoverageController = eventCoverageController
        eventForwardingTasks = [
            Task { @MainActor [weak self, githubResolutionController] in
                for await event in githubResolutionController.events {
                    guard let self else { return }
                    self.handleGitHubEvent(event)
                }
            },
            Task { @MainActor [weak self, eventCoverageController] in
                for await event in eventCoverageController.events {
                    guard let self else { return }
                    self.handleFileEvent(event)
                }
            }
        ]
    }

    deinit {
        eventForwardingTasks.forEach { $0.cancel() }
    }

    var isShuttingDown: Bool { statusRefreshController.isShuttingDown }

    var snapshot: RepositoryRuntimeSnapshot {
        RepositoryRuntimeSnapshot(
            status: statusRefreshController.snapshot,
            github: githubResolutionController.snapshot,
            eventCoverage: eventCoverageController.snapshot
        )
    }

    var statusRefreshSnapshot: RepositoryStatusRefreshSnapshot {
        statusRefreshController.snapshot
    }
#if DEBUG
    var statusContentBuildCountForTesting: Int {
        statusRefreshController.statusContentBuildCountForTesting
    }

    var coverageAggregateBuildCountForTesting: Int {
        eventCoverageController.coverageAggregateBuildCountForTesting
    }
#endif

    var githubResolutionSnapshot: RepositoryGitHubResolutionSnapshot {
        githubResolutionController.snapshot
    }

    var eventCoverageSnapshot: RepositoryFileEventCoverageSnapshot {
        eventCoverageController.snapshot
    }

    func setSelectedRepository(_ repositoryID: UUID?) async {
        await statusRefreshController.setSelectedRepository(repositoryID)
    }

    func setDiffStatsEnabled(_ enabled: Bool, generation: UInt64) async {
        await statusRefreshController.setDiffStatsEnabled(enabled, generation: generation)
    }

    func cancelRefresh(repositoryID: UUID) async {
        await statusRefreshController.cancelRefresh(repositoryID: repositoryID)
    }

    func enqueueStatusRefreshes(
        for repositoryIDs: [UUID],
        refreshUpstream: Bool = false,
        requestKind: RefreshRequestKind = .explicit
    ) {
        guard let context = updateContext(),
              !isShuttingDown,
              !context.isShuttingDown else { return }
        githubResolutionController.scheduleGitHubURLLookups(
            targetRepositoryIDs: Set(repositoryIDs),
            forceRefresh: refreshUpstream
        )
        statusRefreshController.enqueueStatusRefreshes(
            for: repositoryIDs,
            refreshUpstream: refreshUpstream,
            requestKind: requestKind
        )
    }

    private func enqueueStatusRefreshesWithoutGitHub(
        for repositoryIDs: [UUID],
        refreshUpstream: Bool
    ) {
        guard let context = updateContext(),
              !isShuttingDown,
              !context.isShuttingDown else { return }
        statusRefreshController.enqueueStatusRefreshes(
            for: repositoryIDs,
            refreshUpstream: refreshUpstream,
            requestKind: .localFileChange
        )
    }

    func handleRefreshEvent(_ event: RefreshSchedulerEvent) {
        updateContext()
        guard let emitted = statusRefreshController.handleRefreshEvent(event) else { return }
        handleStatusEvent(emitted)
    }

    func scheduleGitHubURLLookups(for repositories: [RepoDescriptor], forceRefresh: Bool) {
        guard let context = updateContext(),
              !isShuttingDown,
              !context.isShuttingDown else { return }
        githubResolutionController.scheduleGitHubURLLookups(
            targetRepositoryIDs: Set(repositories.map(\.id)),
            forceRefresh: forceRefresh
        )
    }

    private func scheduleGitHubURLLookups(
        targetRepositoryIDs: Set<UUID>,
        forceRefresh: Bool,
        reconcileAll: Bool = false
    ) {
        guard let context = updateContext(),
              !isShuttingDown,
              !context.isShuttingDown else { return }
        githubResolutionController.scheduleGitHubURLLookups(
            targetRepositoryIDs: targetRepositoryIDs,
            forceRefresh: forceRefresh,
            reconcileAll: reconcileAll
        )
    }

    func invalidateGitHubURLLookup(for repositoryID: UUID) {
        guard let context = updateContext(),
              !isShuttingDown,
              !context.isShuttingDown else { return }
        githubResolutionController.invalidateGitHubURLLookup(for: repositoryID)
    }

    func refreshGitHubURLWithRetry(for repositoryID: UUID) async -> URL? {
        guard updateContext() != nil else { return nil }
        guard let result = await githubResolutionController.refreshGitHubURLWithRetry(for: repositoryID) else {
            return nil
        }
        if result.didUpdate { emit(.githubURL) }
        return result.url
    }

    func updateEventCoverage() {
        guard updateContext() != nil else { return }
        eventCoverageController.updateEventCoverage()
    }

    func updateDebounce(_ delay: Duration) {
        eventCoverageController.updateDebounce(delay)
    }

    func routeRepositoryFileEvents(
        _ batch: FileEventBatch,
        repositoryID: UUID
    ) async {
        guard !Task.isCancelled, updateContext() != nil else { return }
        let events = await eventCoverageController.routeRepositoryFileEvents(
            batch,
            repositoryID: repositoryID
        )
        guard !Task.isCancelled,
              !isShuttingDown,
              let context = delegate?.repositoryRuntimeContext,
              !context.isShuttingDown else { return }
        events.forEach { handleFileEvent($0) }
    }

    func routeSourceFileEvents(
        _ batch: FileEventBatch,
        sourceID: UUID
    ) async {
        guard !Task.isCancelled, updateContext() != nil else { return }
        let events = await eventCoverageController.routeSourceFileEvents(
            batch,
            sourceID: sourceID
        )
        guard !Task.isCancelled,
              !isShuttingDown,
              let context = delegate?.repositoryRuntimeContext,
              !context.isShuttingDown else { return }
        events.forEach { handleFileEvent($0) }
    }

    func invalidateHistory(for repositoryIDs: [UUID]) -> Bool {
        guard updateContext() != nil else { return false }
        return statusRefreshController.invalidateHistory(for: repositoryIDs)
    }

    func historyGeneration(for repositoryID: UUID) -> UInt64 {
        statusRefreshController.historyGeneration(for: repositoryID)
    }

    func applyCatalogChange(_ change: CatalogChange) async {
        for step in change.effect.runtimeSteps {
            switch step {
            case .setSelectedRepository:
                guard let context = updateContext() else { continue }
                await statusRefreshController.setSelectedRepository(context.state.uiState.selectedRepoID)

            case .scheduleGitHubURLLookups(let target, let forceRefresh):
                let targetRepositoryIDs: Set<UUID>
                switch target {
                case .changed:
                    targetRepositoryIDs = Set(change.effect.changedRepositoryIDs)
                case .all:
                    targetRepositoryIDs = Set(change.repositories.map(\.id))
                }
                scheduleGitHubURLLookups(
                    targetRepositoryIDs: targetRepositoryIDs,
                    forceRefresh: forceRefresh,
                    reconcileAll: true
                )

            case .enqueueStatusRefreshes(let target, let refreshUpstream):
                let repositoryIDs: [UUID]
                switch target {
                case .changed:
                    repositoryIDs = change.effect.changedRepositoryIDs
                case .all:
                    repositoryIDs = change.repositories.map(\.id)
                }
                enqueueStatusRefreshesWithoutGitHub(
                    for: repositoryIDs,
                    refreshUpstream: refreshUpstream
                )

            case .reconcileRepositories(let updateCoverage):
                updateContext()
                guard await statusRefreshController.reconcile(with: change.repositories) else { return }
                emit(.catalogReconciled)
                if updateCoverage { updateEventCoverage() }

            case .removeRepositories(let clearRequestState, let synchronizeSelectedRepository):
                updateContext()
                await statusRefreshController.removeRepositories(
                    change.effect.removedRepositoryIDs,
                    clearRequestState: clearRequestState
                )
                if synchronizeSelectedRepository,
                   let context = updateContext() {
                    await statusRefreshController.setSelectedRepository(context.state.uiState.selectedRepoID)
                }

            case .updateEventCoverage:
                updateEventCoverage()
            }
        }
    }

    func cancelAndDrain() async {
        updateContext()
        async let statusDrain = statusRefreshController.cancelAndDrain()
        async let githubDrain = githubResolutionController.cancelAndDrain()
        async let eventDrain = eventCoverageController.cancelAndDrain()
        _ = await (statusDrain, githubDrain, eventDrain)
    }

    func finishShutdown() async {
        await statusRefreshController.finishShutdown()
        githubResolutionController.finishShutdown()
        await eventCoverageController.cancelAndDrain()
        eventCoverageController.finishShutdown()
        let tasks = eventForwardingTasks
        await TaskCompletionDrain.waitForCompletion(tasks)
        eventForwardingTasks.removeAll()
    }

    func resumeAfterFailedShutdown() {
        statusRefreshController.resumeAfterFailedShutdown()
        githubResolutionController.resumeAfterFailedShutdown()
        eventCoverageController.resumeAfterFailedShutdown()
        updateContext()
    }

    @discardableResult
    private func updateContext() -> RepositoryRuntimeContext? {
        guard let context = delegate?.repositoryRuntimeContext else { return nil }
        statusRefreshController.update(context: context)
        githubResolutionController.update(context: context)
        eventCoverageController.update(context: context)
        return context
    }

    private func handleStatusEvent(_ event: RepositoryStatusRefreshEvent) {
        guard !isShuttingDown,
              let context = delegate?.repositoryRuntimeContext,
              !context.isShuttingDown else { return }
        switch event {
        case .status(let schedulerEvent, let historyInvalidated):
            emit(.status(schedulerEvent, historyInvalidated: historyInvalidated))
        }
    }

    private func handleGitHubEvent(_ event: RepositoryGitHubResolutionEvent) {
        guard !isShuttingDown,
              let context = delegate?.repositoryRuntimeContext,
              !context.isShuttingDown else { return }
        switch event {
        case .urlResolved:
            emit(.githubURL)
        }
    }

    private func handleFileEvent(_ event: RepositoryFileEventCoverageEvent) {
        guard let context = updateContext(),
              !isShuttingDown,
              !context.isShuttingDown else { return }
        switch event {
        case .invalidateGitHubURL(let repositoryID):
            invalidateGitHubURLLookup(for: repositoryID)
        case .rescanSource(let sourceID, let fromWatchRoot):
            if fromWatchRoot {
                guard context.state.watchRoots.contains(where: { $0.id == sourceID }) else { return }
            } else {
                guard context.repositoryIndex.containsRepository(from: sourceID) else { return }
            }
            emit(.action(.rescanSource(sourceID)))
        case .refreshStatus(let repositoryID):
            enqueueStatusRefreshes(
                for: [repositoryID],
                refreshUpstream: false,
                requestKind: .localFileChange
            )
        case .coverageChanged:
            emit(.eventCoverage)
        }
    }
    private func emit(_ change: RepositoryRuntimeChange) {
        delegate?.repositoryRuntimeController(self, didChange: change)
    }
}
