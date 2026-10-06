import Foundation

@MainActor
struct RepositoryFileEventCoverageSnapshot {
    let sourceWatcherIDs: Set<UUID>
    let sourceEventStreamCount: Int
    let repositoryWatcherIDs: Set<UUID>
    let coveredRepositoryIDs: Set<UUID>
    let liveSourceWatcherIDs: Set<UUID>
    let liveCoveredRepositoryIDs: Set<UUID>
}

nonisolated enum RepositoryFileEventCoverageEventKey: Hashable, Sendable {
    case invalidateGitHubURL(UUID)
    case refreshStatus(UUID)
    case coverageChanged
    case lossless(UUID)
}

nonisolated enum RepositoryFileEventCoverageEvent: Sendable, Equatable, Hashable {
    case invalidateGitHubURL(UUID)
    case rescanSource(UUID, fromWatchRoot: Bool)
    case refreshStatus(UUID)
    case coverageChanged

    var coalescingKey: RepositoryFileEventCoverageEventKey {
        switch self {
        case .invalidateGitHubURL(let repositoryID):
            return .invalidateGitHubURL(repositoryID)
        case .rescanSource:
            return .lossless(UUID())
        case .refreshStatus(let repositoryID):
            return .refreshStatus(repositoryID)
        case .coverageChanged:
            return .coverageChanged
        }
    }
}

@MainActor
final class RepositoryFileEventCoverageController {
    private var context: RepositoryRuntimeContext?

    private let eventStream: BoundedKeyedAsyncStream<
        RepositoryFileEventCoverageEvent,
        RepositoryFileEventCoverageEventKey
    >
    private let readiness: RepositoryFileEventCoverageReadiness
    private let topology: RepositoryFileEventCoverageWatcherTopology
    private let eventRouter: RepositoryFileEventCoverageEventRouter
    private let aggregate: RepositoryFileEventCoverageAggregate
    private let shutdown: RepositoryFileEventCoverageShutdown
    private var eventRoutingTasks: [UUID: Task<Void, Never>] = [:]
    private struct RoutedSourceEvents: Sendable {
        let events: [RepositoryFileEventCoverageEvent]
        let groupKey: RepositoryFileEventSourceGroupKey
        let generation: UInt64
    }

    var events: AsyncStream<RepositoryFileEventCoverageEvent> { eventStream.asyncStream }

    init(
        gitService: GitService = GitService(),
        monitorFactory: @escaping () -> FileSystemEventMonitor = { FileSystemEventMonitor(handler: { _ in }) },
        caseSensitivityProvider: @escaping (URL) -> Bool = RepositoryPathPolicy.isCaseSensitiveVolume
    ) {
        let eventStream = BoundedKeyedAsyncStream<
            RepositoryFileEventCoverageEvent,
            RepositoryFileEventCoverageEventKey
        >(
            maximumPendingElements: 128,
            key: { $0.coalescingKey }
        )
        self.eventStream = eventStream


        let readiness = RepositoryFileEventCoverageReadiness()
        self.readiness = readiness
        let topology = RepositoryFileEventCoverageWatcherTopology(
            monitorFactory: monitorFactory,
            caseSensitivityProvider: caseSensitivityProvider,
            readiness: readiness
        )
        self.topology = topology
        let eventRouter = RepositoryFileEventCoverageEventRouter(
            topology: topology,
            caseSensitivityProvider: caseSensitivityProvider,
            ignoredPathResolver: { [gitService] repository, relativePaths in
                // Ignore checks fail open so real changes still refresh.
                guard !Task.isCancelled else { return [] }
                do {
                    let ignoredPaths = try await gitService.ignoredPaths(
                        repository: repository,
                        relativePaths: relativePaths
                    )
                    guard !Task.isCancelled else { return [] }
                    return ignoredPaths
                } catch is CancellationError {
                    return []
                } catch {
                    return []
                }
            }
        )
        self.eventRouter = eventRouter
        let aggregate = RepositoryFileEventCoverageAggregate(
            topology: topology,
            readiness: readiness
        )
        self.aggregate = aggregate
        self.shutdown = RepositoryFileEventCoverageShutdown(
            stopResources: {
                topology.stop()
                aggregate.invalidate()
            },
            finishEventStream: {
                eventStream.finish()
            }
        )

        readiness.setChangeHandler { [weak self] in
            await self?.handleReadinessChange()
        }
        topology.setEventHandlers(
            source: { [weak self] sourceID, delivery, groupKey in
                await self?.receiveSourceFileEvents(
                    delivery,
                    sourceID: sourceID,
                    groupKey: groupKey
                )
            },
            repository: { [weak self] batch, repositoryID in
                await self?.receiveRepositoryFileEvents(batch, repositoryID: repositoryID)
            }
        )
    }

    deinit {
        eventRoutingTasks.values.forEach { $0.cancel() }
    }
    var isShuttingDown: Bool { shutdown.isShuttingDown }

    var snapshot: RepositoryFileEventCoverageSnapshot {
        aggregate.snapshot
    }

#if DEBUG
    var coverageAggregateBuildCountForTesting: Int {
        aggregate.buildCountForTesting
    }

    var pendingEventCountForTesting: Int { eventStream.pendingCount }
#endif

    func update(context: RepositoryRuntimeContext) {
        self.context = context
        eventRouter.update(context: context)
    }

    func updateEventCoverage() {
        guard let context,
              !isShuttingDown,
              !context.isShuttingDown else { return }
        topology.update(context: context)
        eventRouter.updateCoverage(context: context)
        aggregate.invalidate()
    }

    func updateDebounce(_ delay: Duration) {
        topology.updateDebounce(delay)
    }

    func routeRepositoryFileEvents(
        _ batch: FileEventBatch,
        repositoryID: UUID
    ) async -> [RepositoryFileEventCoverageEvent] {
        guard activeContext != nil else { return [] }
        return await eventRouter.routeRepositoryFileEvents(batch, repositoryID: repositoryID)
    }

    func routeSourceFileEvents(
        _ batch: FileEventBatch,
        sourceID: UUID
    ) async -> [RepositoryFileEventCoverageEvent] {
        guard activeContext != nil else { return [] }
        return await eventRouter.routeSourceFileEvents(batch, sourceID: sourceID)
    }

    func cancelAndDrain() async {
        await shutdown.cancelAndDrain()
        await cancelAndDrainEventRoutingTasks()
    }

    func finishShutdown() {
        eventRoutingTasks.values.forEach { $0.cancel() }
        shutdown.finishShutdown()
    }

    func resumeAfterFailedShutdown() {
        shutdown.resumeAfterFailedShutdown()
    }

    private var activeContext: RepositoryRuntimeContext? {
        guard !isShuttingDown,
              let context,
              !context.isShuttingDown else { return nil }
        return context
    }

    private func receiveRepositoryFileEvents(
        _ batch: FileEventBatch,
        repositoryID: UUID
    ) async {
        guard !Task.isCancelled, activeContext != nil else { return }
        await withTrackedRoutingTask { [weak self] in
            guard let self else { return }
            let events = await self.eventRouter.routeRepositoryFileEvents(batch, repositoryID: repositoryID)
            guard !Task.isCancelled, self.activeContext != nil else { return }
            for event in events {
                guard !Task.isCancelled else { return }
                await self.eventStream.send(event)
            }
        }
    }

    private func receiveSourceFileEvents(
        _ delivery: SourceRepositoryFileEventDelivery,
        sourceID: UUID,
        groupKey: RepositoryFileEventSourceGroupKey
    ) async {
        guard !Task.isCancelled, activeContext != nil else { return }
        await withTrackedRoutingTask { [weak self] in
            guard let self else { return }
            while true {
                guard !Task.isCancelled, self.activeContext != nil else { return }
                guard let routed = await self.routeCurrentSourceFileEvents(
                    delivery,
                    sourceID: sourceID,
                    initialGroupKey: groupKey
                ) else { return }
                guard !Task.isCancelled, self.activeContext != nil else { return }
                guard self.topology.isCurrent(sourceID: sourceID, groupKey: routed.groupKey),
                      self.topology.isCurrent(
                          groupKey: routed.groupKey,
                          generation: routed.generation
                      ) else { continue }
                for event in routed.events {
                    guard !Task.isCancelled else { return }
                    await self.eventStream.send(event)
                }
                return
            }
        }
    }

    private func routeCurrentSourceFileEvents(
        _ delivery: SourceRepositoryFileEventDelivery,
        sourceID: UUID,
        initialGroupKey: RepositoryFileEventSourceGroupKey
    ) async -> RoutedSourceEvents? {
        var useDeliveredEvents = false
        if let currentGroupKey = topology.currentSourceGroupKey(for: sourceID),
           currentGroupKey == initialGroupKey,
           let generation = delivery.generation,
           topology.isCurrent(groupKey: initialGroupKey, generation: generation) {
            useDeliveredEvents = true
        }

        while true {
            guard !Task.isCancelled,
                  activeContext != nil,
                  let currentGroupKey = topology.currentSourceGroupKey(for: sourceID),
                  let generation = topology.currentGeneration(groupKey: currentGroupKey) else { return nil }
            let events: [RepositoryFileEventCoverageEvent]
            if useDeliveredEvents,
               currentGroupKey == initialGroupKey,
               delivery.generation == generation {
                events = await eventRouter.routeSourceFileEvents(
                    delivery.batch,
                    sourceID: sourceID,
                    relevantEvents: delivery.events,
                    caseSensitive: delivery.caseSensitiveVolume
                )
            } else {
                useDeliveredEvents = false
                events = await eventRouter.routeSourceFileEvents(delivery.batch, sourceID: sourceID)
            }
            guard !Task.isCancelled, activeContext != nil else { return nil }
            guard topology.currentSourceGroupKey(for: sourceID) == currentGroupKey else {
                useDeliveredEvents = false
                continue
            }
            guard topology.isCurrent(sourceID: sourceID, groupKey: currentGroupKey) else { return nil }
            guard topology.currentGeneration(groupKey: currentGroupKey) == generation else {
                useDeliveredEvents = false
                continue
            }
            return RoutedSourceEvents(
                events: events,
                groupKey: currentGroupKey,
                generation: generation
            )
        }
    }

    private func withTrackedRoutingTask(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let taskID = UUID()
        let task = Task { @MainActor in
            await operation()
        }
        eventRoutingTasks[taskID] = task
        await task.value
        eventRoutingTasks.removeValue(forKey: taskID)
    }

    private func cancelAndDrainEventRoutingTasks() async {
        let tasks = Array(eventRoutingTasks.values)
        tasks.forEach { $0.cancel() }
        await TaskCompletionDrain.waitForCompletion(tasks)
        eventRoutingTasks.removeAll()
    }



    private func handleReadinessChange() async {
        aggregate.invalidate()
        await eventStream.send(.coverageChanged)
    }
}