import Foundation

nonisolated struct RefreshOperationRequest: Sendable {
    let url: URL
    let isSelected: Bool
    let refreshUpstream: Bool
    let includeDiffStats: Bool
}

nonisolated enum RefreshKind: Sendable, Hashable {
    case status
}

nonisolated enum RefreshRequestKind: Sendable, Hashable {
    case localFileChange
    case explicit
    case destructiveOperation

    var cancelsActiveOperation: Bool {
        switch self {
        case .localFileChange: false
        case .explicit, .destructiveOperation: true
        }
    }
}

nonisolated struct RefreshKey: Sendable, Hashable {
    let repositoryID: UUID
    let kind: RefreshKind
}

nonisolated enum RefreshSchedulerEvent: Sendable, Equatable {
    case queued(RefreshKey, UInt64)
    case running(RefreshKey, UInt64)
    case completed(
        RefreshKey, UInt64, RepoStatus, upstreamRefreshAttempted: Bool = false
    )
    case completedWithFailure(
        RefreshKey, UInt64, RepoStatus, OperationFailure, upstreamRefreshAttempted: Bool = false
    )
    case failed(
        RefreshKey, UInt64, OperationFailure, upstreamRefreshAttempted: Bool = false
    )
    case cancelled(RefreshKey, UInt64, upstreamRefreshAttempted: Bool = false)
}

nonisolated struct RefreshSchedulerMetrics: Sendable, Equatable {
    var startedCount = 0
    var completedCount = 0
    var failedCount = 0
    var cancelledCount = 0
    var maximumConcurrentObserved = 0
    var maximumPendingObserved = 0
    var totalQueueWait: Duration = .zero
    var totalRunTime: Duration = .zero
}

actor RefreshScheduler {
    private struct Request: Sendable {
        let key: RefreshKey
        let url: URL
        let generation: UInt64
        let order: UInt64
        let enqueuedAt: ContinuousClock.Instant
        let refreshUpstream: Bool
        var upstreamRefreshAttempted: Bool
        let includeDiffStats: Bool
        let requestKind: RefreshRequestKind

        var cancelsActiveOperation: Bool {
            requestKind.cancelsActiveOperation || refreshUpstream
        }
    }

    private struct Running {
        let generation: UInt64
        let task: Task<Void, Never>
        let startedAt: ContinuousClock.Instant
        let refreshUpstream: Bool
        let upstreamRefreshAttempted: Bool
    }

    static let maximumPending = 128

    private let maximumConcurrent: Int
    private let operation: @Sendable (RefreshOperationRequest) async throws -> RepoStatus
    private let eventHandler: @Sendable (RefreshSchedulerEvent) async -> Void
    private var selectedRepositoryID: UUID?
    private var diffStatsEnabled = true
    private var diffStatsGeneration: UInt64 = 0
    private var pending: [RefreshKey: Request] = [:]
    private var replacements: [RefreshKey: Request] = [:]
    private var running: [RefreshKey: Running] = [:]
    private var queuedNotificationKeys: Set<RefreshKey> = []
    private var preservedFailures: [RefreshKey: OperationFailure] = [:]
    private var generations: [RefreshKey: UInt64] = [:]
    private var nextGeneration: UInt64 = 0
    private var order: UInt64 = 0
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStopped = false
    private let clock = ContinuousClock()
    private var performance = RefreshSchedulerMetrics()

    init(
        maximumConcurrent: Int = 2,
        operation: @escaping @Sendable (RefreshOperationRequest) async throws -> RepoStatus,
        eventHandler: @escaping @Sendable (RefreshSchedulerEvent) async -> Void
    ) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.operation = operation
        self.eventHandler = eventHandler
    }

    func setSelectedRepository(_ repositoryID: UUID?) {
        guard !isStopped else { return }
        selectedRepositoryID = repositoryID
        pump()
    }
    func setDiffStatsEnabled(_ enabled: Bool, generation: UInt64) {
        guard !isStopped, generation >= diffStatsGeneration else { return }
        diffStatsGeneration = generation
        diffStatsEnabled = enabled
    }

    func enqueue(
        repositoryID: UUID,
        url: URL,
        kind: RefreshKind = .status,
        refreshUpstream: Bool = false,
        includeDiffStats: Bool = false,
        requestKind: RefreshRequestKind = .localFileChange
    ) async {
        guard !isStopped, !Task.isCancelled else { return }
        let key = RefreshKey(repositoryID: repositoryID, kind: kind)
        let queuedRequest: Request?
        if let replacement = replacements[key], replacement.cancelsActiveOperation {
            queuedRequest = replacement
        } else if let pending = pending[key], pending.cancelsActiveOperation {
            queuedRequest = pending
        } else {
            queuedRequest = nil
        }
        let pendingUpstreamRefresh = refreshUpstream
            || pending[key]?.refreshUpstream == true
            || replacements[key]?.refreshUpstream == true
        let upstreamRefreshAttempted = refreshUpstream
            || pending[key]?.upstreamRefreshAttempted == true
            || replacements[key]?.upstreamRefreshAttempted == true
            || running[key]?.upstreamRefreshAttempted == true
        let isLocalFileChange = requestKind == .localFileChange && !refreshUpstream
        let effectiveRequestKind: RefreshRequestKind
        if isLocalFileChange, let queuedRequest {
            effectiveRequestKind = queuedRequest.requestKind
        } else {
            effectiveRequestKind = requestKind
        }
        if refreshUpstream { preservedFailures[key] = nil }
        nextGeneration &+= 1
        let generation = nextGeneration
        generations[key] = generation
        order &+= 1
        let requestRefreshUpstream = pendingUpstreamRefresh
            || (!isLocalFileChange && running[key]?.refreshUpstream == true)
        let request = Request(
            key: key,
            url: url,
            generation: generation,
            order: order,
            enqueuedAt: clock.now,
            refreshUpstream: requestRefreshUpstream,
            upstreamRefreshAttempted: upstreamRefreshAttempted,
            includeDiffStats: includeDiffStats,
            requestKind: effectiveRequestKind
        )
        if let runningRequest = running[key] {
            replacements[key] = request
            if request.cancelsActiveOperation {
                runningRequest.task.cancel()
            }
            if queuedNotificationKeys.insert(key).inserted {
                await eventHandler(.queued(key, generation))
            }
            return
        }
        guard pending[key] != nil || pending.count < Self.maximumPending else {
            await eventHandler(.failed(
                key,
                generation,
                .message(
                    "Refresh queue is full.",
                    title: "Refresh could not start",
                    recoverySuggestion: "Wait for queued refreshes to finish, then refresh again."
                )
            ))
            generations[key] = nil
            return
        }
        pending[key] = request
        performance.maximumPendingObserved = max(performance.maximumPendingObserved, pending.count)
        if queuedNotificationKeys.insert(key).inserted {
            await eventHandler(.queued(key, generation))
        }
        guard !isStopped,
              !Task.isCancelled,
              generations[key] == generation,
              pending[key]?.generation == generation else { return }
        pump()
    }

    func metrics() -> RefreshSchedulerMetrics {
        performance
    }

    func cancel(repositoryID: UUID) async {
        let keys = Set(
            pending.keys.filter { $0.repositoryID == repositoryID }
                + replacements.keys.filter { $0.repositoryID == repositoryID }
                + running.keys.filter { $0.repositoryID == repositoryID }
                + preservedFailures.keys.filter { $0.repositoryID == repositoryID }
        )
        for key in keys {
            nextGeneration &+= 1
            let generation = nextGeneration
            generations[key] = generation
            pending[key] = nil
            replacements[key] = nil
            queuedNotificationKeys.remove(key)
            preservedFailures[key] = nil
            running[key]?.task.cancel()
            await eventHandler(.cancelled(
                key,
                generation,
                upstreamRefreshAttempted: running[key]?.upstreamRefreshAttempted ?? false
            ))
            if running[key] == nil { generations[key] = nil }
        }
        pump()
    }

    func stop() async {
        isStopped = true
        let keys = Set(pending.keys).union(running.keys).union(replacements.keys).union(preservedFailures.keys)
        pending.removeAll()
        replacements.removeAll()
        queuedNotificationKeys.removeAll()
        preservedFailures.removeAll()
        for key in keys {
            nextGeneration &+= 1
            let generation = nextGeneration
            generations[key] = generation
            running[key]?.task.cancel()
            await eventHandler(.cancelled(
                key,
                generation,
                upstreamRefreshAttempted: running[key]?.upstreamRefreshAttempted ?? false
            ))
        }
        guard !running.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopWaiters.append(continuation)
        }
    }

    private func pump() {
        guard !isStopped else { return }
        while running.count < maximumConcurrent, let request = nextRequest() {
            pending[request.key] = nil
            start(request)
        }
    }

    private func start(_ request: Request) {
        queuedNotificationKeys.remove(request.key)
        let selected = request.key.repositoryID == selectedRepositoryID
        let includeDiffStats = request.includeDiffStats && selected && diffStatsEnabled
        let startedAt = clock.now
        performance.startedCount += 1
        performance.totalQueueWait += request.enqueuedAt.duration(to: startedAt)
        let task = Task { [operation, eventHandler] in
            await eventHandler(.running(request.key, request.generation))
            let result: Result<RepoStatus, Error>
            do { result = .success(try await operation(RefreshOperationRequest(url: request.url, isSelected: selected, refreshUpstream: request.refreshUpstream, includeDiffStats: includeDiffStats))) } catch { result = .failure(error) }
            await self.finished(request, result: result)
        }
        running[request.key] = Running(
            generation: request.generation,
            task: task,
            startedAt: startedAt,
            refreshUpstream: request.refreshUpstream,
            upstreamRefreshAttempted: request.upstreamRefreshAttempted
        )
        performance.maximumConcurrentObserved = max(performance.maximumConcurrentObserved, running.count)
    }

    private func nextRequest() -> Request? {
        pending.values.min {
            let lhsSelected = $0.key.repositoryID == selectedRepositoryID
            let rhsSelected = $1.key.repositoryID == selectedRepositoryID
            if lhsSelected != rhsSelected { return lhsSelected }
            return $0.order < $1.order
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? ProcessRunnerError else { return false }
        if case .cancelled = error { return true }
        return false
    }

    private func finished(_ request: Request, result: Result<RepoStatus, Error>) async {
        guard let runningRequest = running[request.key], runningRequest.generation == request.generation else { return }
        performance.totalRunTime += runningRequest.startedAt.duration(to: clock.now)
        running[request.key] = nil
        if !isStopped, var replacement = replacements.removeValue(forKey: request.key) {
            replacement.upstreamRefreshAttempted =
                replacement.upstreamRefreshAttempted || runningRequest.upstreamRefreshAttempted
            if runningRequest.refreshUpstream,
               !replacement.refreshUpstream,
               case .failure(let error) = result,
                !isCancellation(error) {
                preservedFailures[request.key] = .git(error, title: "Could not refresh repository status")
                performance.failedCount += 1
            }
            if let next = nextRequest(),
               next.key.repositoryID == selectedRepositoryID,
               replacement.key.repositoryID != selectedRepositoryID {
                pending[next.key] = nil
                pending[replacement.key] = replacement
                start(next)
            } else {
                start(replacement)
            }
            return
        }
        if running.isEmpty {
            let waiters = stopWaiters
            stopWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard generations[request.key] == request.generation else {
            pump()
            if running[request.key] == nil, pending[request.key] == nil, replacements[request.key] == nil {
                generations[request.key] = nil
            }
            return
        }
        if Task.isCancelled {
            preservedFailures[request.key] = nil
            performance.cancelledCount += 1
            await eventHandler(.cancelled(
                request.key,
                request.generation,
                upstreamRefreshAttempted: request.upstreamRefreshAttempted
            ))
        } else {
            switch result {
            case .success(let status):
                let preservedFailure = preservedFailures[request.key]
                performance.completedCount += 1
                if let preservedFailure {
                    await eventHandler(.completedWithFailure(
                        request.key,
                        request.generation,
                        status,
                        preservedFailure,
                        upstreamRefreshAttempted: true
                    ))
                } else {
                    await eventHandler(.completed(
                        request.key,
                        request.generation,
                        status,
                        upstreamRefreshAttempted: request.upstreamRefreshAttempted
                    ))
                }
            case .failure(let error):
                if isCancellation(error) {
                    preservedFailures[request.key] = nil
                    performance.cancelledCount += 1
                    await eventHandler(.cancelled(
                        request.key,
                        request.generation,
                        upstreamRefreshAttempted: request.upstreamRefreshAttempted
                    ))
                } else {
                    let failure = OperationFailure.git(error, title: "Could not refresh repository status")
                    preservedFailures[request.key] = request.refreshUpstream ? failure : nil
                    performance.failedCount += 1
                    await eventHandler(.failed(
                        request.key,
                        request.generation,
                        failure,
                        upstreamRefreshAttempted: request.upstreamRefreshAttempted
                    ))
                }
            }
        }
        pump()
        if running[request.key] == nil, pending[request.key] == nil, replacements[request.key] == nil {
            generations[request.key] = nil
        }
    }

}
