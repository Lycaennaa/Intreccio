import Foundation

@MainActor
struct RepositoryStatusRefreshSnapshot {
    let refreshStates: RepositorySnapshotMap<RepositoryRefreshState>
    let statusRequestGenerations: RepositorySnapshotMap<UInt64>
    let hasPendingEnqueueTasks: Bool

    init(
        refreshStates: RepositorySnapshotMap<RepositoryRefreshState>,
        statusRequestGenerations: RepositorySnapshotMap<UInt64>,
        hasPendingEnqueueTasks: Bool
    ) {
        self.refreshStates = refreshStates
        self.statusRequestGenerations = statusRequestGenerations
        self.hasPendingEnqueueTasks = hasPendingEnqueueTasks
    }

    init(
        refreshStates: [UUID: RepositoryRefreshState],
        statusRequestGenerations: [UUID: UInt64],
        hasPendingEnqueueTasks: Bool
    ) {
        self.init(
            refreshStates: RepositorySnapshotMap(refreshStates),
            statusRequestGenerations: RepositorySnapshotMap(statusRequestGenerations),
            hasPendingEnqueueTasks: hasPendingEnqueueTasks
        )
    }
}

nonisolated enum RepositoryStatusRefreshEvent: Sendable, Equatable {
    case status(RefreshSchedulerEvent, historyInvalidated: Bool)
}

@MainActor
final class RepositoryStatusRefreshController {
    let gitService: GitService

    private var refreshStates = RepositorySnapshotMap<RepositoryRefreshState>()
#if DEBUG
    private(set) var statusContentBuildCountForTesting = 0
#endif
    private var statusRequestGenerations = RepositorySnapshotMap<UInt64>()
    private var statusEnqueueTasks: [UUID: Task<Void, Never>] = [:]
    private var statusEnqueueTaskIDs: [UUID: UUID] = [:]
    private var pendingUpstreamStatusRefreshes: [UUID: Bool] = [:]
    private var context: RepositoryRuntimeContext?
    private(set) var isShuttingDown = false

    private var statusEventHandler: ((RepositoryStatusRefreshEvent) -> Void)?
    lazy var scheduler = RefreshScheduler(
        operation: { [gitService] request in
            try await gitService.status(
                repository: request.url,
                refreshUpstream: request.refreshUpstream,
                priority: request.isSelected ? .selectedRepository : .normal,
                includeDiffStats: request.includeDiffStats,
                expandUntrackedDirectories: request.isSelected
            )
        },
        eventHandler: { [weak self] event in
            await MainActor.run {
                guard let self, let emitted = self.handleRefreshEvent(event) else { return }
                self.statusEventHandler?(emitted)
            }
        }
    )

    init(gitService: GitService) {
        self.gitService = gitService
    }

    func setStatusEventHandler(_ handler: @escaping (RepositoryStatusRefreshEvent) -> Void) {
        statusEventHandler = handler
    }

    deinit {
        statusEnqueueTasks.values.forEach { $0.cancel() }
    }

    var snapshot: RepositoryStatusRefreshSnapshot {
        RepositoryStatusRefreshSnapshot(
            refreshStates: refreshStates,
            statusRequestGenerations: statusRequestGenerations,
            hasPendingEnqueueTasks: !statusEnqueueTasks.isEmpty
        )
    }

    func update(context: RepositoryRuntimeContext) {
        self.context = context
    }

    func setSelectedRepository(_ repositoryID: UUID?) async {
        await scheduler.setSelectedRepository(repositoryID)
    }

    func setDiffStatsEnabled(_ enabled: Bool, generation: UInt64) async {
        await scheduler.setDiffStatsEnabled(enabled, generation: generation)
    }

    func cancelRefresh(repositoryID: UUID) async {
        await scheduler.cancel(repositoryID: repositoryID)
    }

    func enqueueStatusRefreshes(
        for repositoryIDs: [UUID],
        refreshUpstream: Bool = false,
        requestKind: RefreshRequestKind = .explicit
    ) {
        guard let context,
              !isShuttingDown,
              !context.isShuttingDown else { return }
        let available = context.repositoryIndex.availableRepositories(for: Set(repositoryIDs))
        guard !available.isEmpty else { return }
        for repository in available {
            let shouldRefreshUpstream = refreshUpstream
                || pendingUpstreamStatusRefreshes[repository.id] == true
            pendingUpstreamStatusRefreshes[repository.id] = shouldRefreshUpstream
            let generation = nextStatusRequestGeneration(for: repository.id)
            let repositoryID = repository.id
            let url = repository.canonicalURL
            let taskID = UUID()
            statusEnqueueTasks[repositoryID]?.cancel()
            statusEnqueueTaskIDs[repositoryID] = taskID
            statusEnqueueTasks[repositoryID] = Task { [weak self, scheduler] in
                await self?.runStatusEnqueueTask(
                    repositoryID: repositoryID,
                    url: url,
                    generation: generation,
                    refreshUpstream: shouldRefreshUpstream,
                    requestKind: requestKind,
                    taskID: taskID,
                    scheduler: scheduler
                )
            }
        }
    }

    private func runStatusEnqueueTask(
        repositoryID: UUID,
        url: URL,
        generation: UInt64,
        refreshUpstream: Bool,
        requestKind: RefreshRequestKind,
        taskID: UUID,
        scheduler: RefreshScheduler
    ) async {
        defer {
            clearStatusEnqueueTask(
                repositoryID: repositoryID,
                generation: generation,
                taskID: taskID
            )
        }
        guard let context,
              !isShuttingDown,
              !context.isShuttingDown,
              !Task.isCancelled,
              let current = context.repositoryIndex.repository(for: repositoryID),
              current.availability == .available,
              current.canonicalURL == url else { return }
        let includeDiffStats = context.state.uiState.mode == .changes
            && context.state.uiState.selectedRepoID == repositoryID
        guard !Task.isCancelled else { return }
        await scheduler.enqueue(
            repositoryID: repositoryID,
            url: url,
            refreshUpstream: refreshUpstream,
            includeDiffStats: includeDiffStats,
            requestKind: requestKind
        )
        guard statusRequestGenerations[repositoryID] == generation else { return }
        pendingUpstreamStatusRefreshes[repositoryID] = nil
    }

    private func clearStatusEnqueueTask(
        repositoryID: UUID,
        generation: UInt64,
        taskID: UUID
    ) {
        guard statusRequestGenerations[repositoryID] == generation,
              statusEnqueueTaskIDs[repositoryID] == taskID else { return }
        statusEnqueueTasks[repositoryID] = nil
        statusEnqueueTaskIDs[repositoryID] = nil
    }

    private func nextStatusRequestGeneration(for repositoryID: UUID) -> UInt64 {
        let generation = (statusRequestGenerations[repositoryID] ?? 0) &+ 1
        statusRequestGenerations = statusRequestGenerations.setting(generation, for: repositoryID)
        return generation
    }

    @discardableResult
    func handleRefreshEvent(_ event: RefreshSchedulerEvent) -> RepositoryStatusRefreshEvent? {
        guard let context,
              !isShuttingDown,
              !context.isShuttingDown else { return nil }
        let key: RefreshKey
        let generation: UInt64
        switch event {
        case .queued(let value, let valueGeneration),
             .running(let value, let valueGeneration),
             .completed(let value, let valueGeneration, _, _),
             .completedWithFailure(let value, let valueGeneration, _, _, _),
             .failed(let value, let valueGeneration, _, _),
             .cancelled(let value, let valueGeneration, _):
            key = value
            generation = valueGeneration
        }
        guard let repository = context.repositoryIndex.repository(for: key.repositoryID),
              repository.availability == .available else { return nil }
        var state = refreshStates[key.repositoryID] ?? RepositoryRefreshState()
        guard generation >= state.statusGeneration else { return nil }
        state.statusGeneration = generation
        let historyInvalidated: Bool
        switch event {
        case .queued:
            state.phase = .queued
            historyInvalidated = false
        case .running:
            state.phase = .running
            historyInvalidated = false
        case .completed(_, _, let status, let upstreamRefreshAttempted):
            historyInvalidated = shouldInvalidateHistory(
                previousStatus: state.status,
                currentStatus: status,
                upstreamRefreshAttempted: upstreamRefreshAttempted
            )
            applyStatus(status, to: &state)
            state.phase = .idle
        case .completedWithFailure(_, _, let status, let failure, let upstreamRefreshAttempted):
            historyInvalidated = shouldInvalidateHistory(
                previousStatus: state.status,
                currentStatus: status,
                upstreamRefreshAttempted: upstreamRefreshAttempted
            )
            applyStatus(status, to: &state)
            state.phase = .failed(failure)
        case .failed(_, _, let failure, let upstreamRefreshAttempted):
            historyInvalidated = shouldInvalidateHistory(
                previousStatus: state.status,
                currentStatus: nil,
                upstreamRefreshAttempted: upstreamRefreshAttempted
            )
            state.phase = .failed(failure)
        case .cancelled(_, _, let upstreamRefreshAttempted):
            state.phase = .idle
            historyInvalidated = upstreamRefreshAttempted
        }
        if historyInvalidated { state.historyGeneration &+= 1 }
        refreshStates = refreshStates.setting(state, for: key.repositoryID)
        return .status(event, historyInvalidated: historyInvalidated)
    }
    private func applyStatus(_ status: RepoStatus, to state: inout RepositoryRefreshState) {
        let contentChanged = state.status?.changes != status.changes
        let content: RepositoryStatusContent
        if contentChanged {
            content = RepositoryStatusContent(status: status)
#if DEBUG
            statusContentBuildCountForTesting += 1
#endif
        } else if let cached = state.statusContent {
            content = cached
        } else {
            content = RepositoryStatusContent(status: status)
#if DEBUG
            statusContentBuildCountForTesting += 1
#endif
        }
        if contentChanged { state.statusContentGeneration &+= 1 }
        state.updateStatus(status, content: content)
    }
    private func shouldInvalidateHistory(
        previousStatus: RepoStatus?,
        currentStatus: RepoStatus?,
        upstreamRefreshAttempted: Bool
    ) -> Bool {
        guard !upstreamRefreshAttempted else { return true }
        guard let currentStatus else { return previousStatus == nil }
        guard let previousStatus else { return true }
        return previousStatus.branch != currentStatus.branch
    }

    func reconcile(with repositories: [RepoDescriptor]) async -> Bool {
        guard let context,
              !isShuttingDown,
              !context.isShuttingDown,
              !Task.isCancelled else { return false }
        let repositoryIDs = Set(repositories.map(\.id))
        refreshStates = refreshStates.filtering { repositoryID, _ in repositoryIDs.contains(repositoryID) }
        statusRequestGenerations = statusRequestGenerations.filtering { repositoryID, _ in repositoryIDs.contains(repositoryID) }
        pendingUpstreamStatusRefreshes = pendingUpstreamStatusRefreshes.filter { repositoryIDs.contains($0.key) }
        let removedTaskIDs = statusEnqueueTasks.keys.filter { !repositoryIDs.contains($0) }
        for repositoryID in removedTaskIDs {
            statusEnqueueTaskIDs[repositoryID] = nil
            statusEnqueueTasks.removeValue(forKey: repositoryID)?.cancel()
        }
        for repository in repositories where repository.availability != .available {
            statusEnqueueTaskIDs[repository.id] = nil
            statusEnqueueTasks.removeValue(forKey: repository.id)?.cancel()
            pendingUpstreamStatusRefreshes[repository.id] = nil
            await scheduler.cancel(repositoryID: repository.id)
            guard !isShuttingDown, !Task.isCancelled else { return false }
            guard var state = refreshStates[repository.id] else { continue }
            if state.status != nil || state.statusContent != nil {
                state.statusContentGeneration &+= 1
            }
            state.updateStatus(nil, content: nil)
            state.phase = .idle
            state.statusGeneration &+= 1
            refreshStates = refreshStates.setting(state, for: repository.id)
        }
        return true
    }

    func removeRepositories(
        _ repositoryIDs: [UUID],
        clearRequestState: Bool
    ) async {
        for repositoryID in repositoryIDs {
            if clearRequestState {
                refreshStates = refreshStates.setting(nil, for: repositoryID)
                statusRequestGenerations = statusRequestGenerations.setting(nil, for: repositoryID)
                pendingUpstreamStatusRefreshes[repositoryID] = nil
            } else {
                refreshStates = refreshStates.setting(nil, for: repositoryID)
            }
            statusEnqueueTaskIDs[repositoryID] = nil
            statusEnqueueTasks.removeValue(forKey: repositoryID)?.cancel()
            await scheduler.cancel(repositoryID: repositoryID)
        }
    }

    func invalidateHistory(for repositoryIDs: [UUID]) -> Bool {
        guard let context else { return false }
        var reloadSelectedHistory = false
        for repositoryID in repositoryIDs {
            var state = refreshStates[repositoryID] ?? RepositoryRefreshState()
            state.historyGeneration &+= 1
            refreshStates = refreshStates.setting(state, for: repositoryID)
            reloadSelectedHistory = reloadSelectedHistory
                || (context.state.uiState.mode == .history
                    && repositoryID == context.state.uiState.selectedRepoID)
        }
        return reloadSelectedHistory
    }

    func historyGeneration(for repositoryID: UUID) -> UInt64 {
        refreshStates[repositoryID]?.historyGeneration ?? 0
    }

    func cancelAndDrain() async {
        isShuttingDown = true
        for repositoryID in statusRequestGenerations.keys {
            _ = nextStatusRequestGeneration(for: repositoryID)
        }
        let tasks = Array(statusEnqueueTasks.values)
        tasks.forEach { $0.cancel() }
        statusEnqueueTasks.removeAll()
        statusEnqueueTaskIDs.removeAll()
        await TaskCompletionDrain.waitForCompletion(tasks)
    }

    func finishShutdown() async {
        isShuttingDown = true
        await scheduler.stop()
    }

    func resumeAfterFailedShutdown() {
        isShuttingDown = false
    }
}
