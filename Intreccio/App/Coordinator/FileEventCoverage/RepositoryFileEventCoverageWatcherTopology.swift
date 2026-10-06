import Foundation

@MainActor
final class RepositoryFileEventCoverageWatcherTopology {
    typealias SourceEventHandler = @Sendable (
        UUID,
        SourceRepositoryFileEventDelivery,
        RepositoryFileEventSourceGroupKey
    ) async -> Void
    typealias RepositoryEventHandler = @Sendable (FileEventBatch, UUID) async -> Void

    private let monitorFactory: () -> FileSystemEventMonitor
    private let caseSensitivityProvider: (URL) -> Bool
    private let readiness: RepositoryFileEventCoverageReadiness
    private var sourceEventHandler: SourceEventHandler?
    private var repositoryEventHandler: RepositoryEventHandler?
    private var debounceOrder = 0

    private(set) var repositoryCoverageOwners: [UUID: RepositoryFileEventCoverageOwner] = [:]
    private(set) var sourceEventWatcherGroups: [UUID: RepositoryFileEventSourceGroupKey] = [:]
    private(set) var sourceEventMonitors: [RepositoryFileEventSourceGroupKey: FileSystemEventMonitor] = [:]
    private(set) var sourceEventGroups: [RepositoryFileEventSourceGroupKey: SourceRepositoryFileEventGroup] = [:]
    private(set) var repositoryEventMonitors: [UUID: FileSystemEventMonitor] = [:]
    private(set) var repositoryEventWatchers: [UUID: FileEventWatcher] = [:]
    private(set) var sourceRepositoryPathIndexes: [UUID: SourceRepositoryPathIndex] = [:]

    init(
        monitorFactory: @escaping () -> FileSystemEventMonitor,
        caseSensitivityProvider: @escaping (URL) -> Bool,
        readiness: RepositoryFileEventCoverageReadiness
    ) {
        self.monitorFactory = monitorFactory
        self.caseSensitivityProvider = caseSensitivityProvider
        self.readiness = readiness
    }

    func setEventHandlers(
        source: @escaping SourceEventHandler,
        repository: @escaping RepositoryEventHandler
    ) {
        sourceEventHandler = source
        repositoryEventHandler = repository
    }

    func update(context: RepositoryRuntimeContext) {
        let sources = context.state.watchRoots
        let sourceIDs = Set(sources.map(\.id))
        for sourceID in Array(sourceEventWatcherGroups.keys) where !sourceIDs.contains(sourceID) {
            sourceEventWatcherGroups.removeValue(forKey: sourceID)
        }

        let sourceIndexes = RepositoryFileEventCoveragePlanner.makeSourceIndexes(
            sources,
            repositories: context.repositories,
            caseSensitivityProvider: caseSensitivityProvider
        )
        sourceRepositoryPathIndexes = sourceIndexes

        let sourceGroupPlans = RepositoryFileEventCoveragePlanner.makeSourceEventGroupPlans(
            sources,
            indexes: sourceIndexes
        )
        let plannedGroupKeys = Set(sourceGroupPlans.map(\.key))
        for key in Array(sourceEventGroups.keys) where !plannedGroupKeys.contains(key) {
            removeSourceGroup(for: key)
        }
        for plan in sourceGroupPlans {
            let monitor: FileSystemEventMonitor
            if let existing = sourceEventMonitors[plan.key] {
                monitor = existing
            } else {
                monitor = monitorFactory()
                sourceEventMonitors[plan.key] = monitor
                readiness.observeSourceMonitor(monitor, groupKey: plan.key)
            }
            monitor.updateCoverage(plan.coverageURLs)

            let planIndexes = plan.sources.reduce(into: [UUID: SourceRepositoryPathIndex]()) {
                indexes, source in
                if let index = sourceIndexes[source.id] {
                    indexes[source.id] = index
                }
            }
            let group: SourceRepositoryFileEventGroup
            if let existing = sourceEventGroups[plan.key] {
                group = existing
                group.update(sourceIndexes: planIndexes)
            } else {
                let groupKey = plan.key
                group = SourceRepositoryFileEventGroup(
                    monitor: monitor,
                    sourceIndexes: planIndexes
                ) { [weak self] sourceID, delivery in
                    await self?.deliverSourceEvents(
                        delivery,
                        sourceID: sourceID,
                        groupKey: groupKey
                    )
                }
                sourceEventGroups[plan.key] = group
            }
            group.updateDebounce(
                Duration.milliseconds(context.state.uiState.fileWatchDebounceMilliseconds),
                order: 0
            )
            for source in plan.sources {
                sourceEventWatcherGroups[source.id] = plan.key
            }
        }

        let coverageOwners = RepositoryFileEventCoveragePlanner.makeCoverageOwners(
            repositories: context.repositories,
            sourceIDs: sourceIDs,
            indexes: sourceIndexes
        )
        repositoryCoverageOwners = coverageOwners

        let independentlyWatchedRepositoryIDs = Set(coverageOwners.compactMap { repositoryID, owner in
            if case .independentRepository = owner { return repositoryID }
            return nil
        })
        for repositoryID in Array(repositoryEventWatchers.keys)
            where !independentlyWatchedRepositoryIDs.contains(repositoryID) {
            removeRepositoryWatcher(for: repositoryID)
        }
        for repository in context.repositories
            where repository.availability == .available
                && independentlyWatchedRepositoryIDs.contains(repository.id) {
            let repositoryID = repository.id
            let watcher: FileEventWatcher
            if let existing = repositoryEventWatchers[repositoryID] {
                watcher = existing
            } else {
                let monitor = monitorFactory()
                repositoryEventMonitors[repositoryID] = monitor
                readiness.observeRepositoryMonitor(monitor, repositoryID: repositoryID)
                watcher = FileEventWatcher(
                    monitor: monitor,
                    handler: { [weak self] batch in
                        await self?.deliverRepositoryEvents(batch, repositoryID: repositoryID)
                    }
                )
            }
            repositoryEventWatchers[repositoryID] = watcher
            repositoryEventMonitors[repositoryID]?.updateCoverage([repository.canonicalURL])
            watcher.updateDebounce(
                Duration.milliseconds(context.state.uiState.fileWatchDebounceMilliseconds),
                order: 0
            )
        }
    }

    func updateDebounce(_ delay: Duration) {
        debounceOrder &+= 1
        sourceEventGroups.values.forEach {
            $0.updateDebounce(delay, order: debounceOrder)
        }
        repositoryEventWatchers.values.forEach {
            $0.updateDebounce(delay, order: debounceOrder)
        }
    }

    func isCurrent(sourceID: UUID, groupKey: RepositoryFileEventSourceGroupKey) -> Bool {
        sourceEventWatcherGroups[sourceID] == groupKey && sourceEventGroups[groupKey] != nil
    }
    func currentSourceGroupKey(for sourceID: UUID) -> RepositoryFileEventSourceGroupKey? {
        sourceEventWatcherGroups[sourceID]
    }

    func isCurrent(
        groupKey: RepositoryFileEventSourceGroupKey,
        generation: UInt64
    ) -> Bool {
        sourceEventGroups[groupKey]?.isCurrent(generation) == true
    }
    func currentGeneration(groupKey: RepositoryFileEventSourceGroupKey) -> UInt64? {
        sourceEventGroups[groupKey]?.currentGeneration()
    }

    func stop() {
        readiness.stop()
        sourceEventGroups.values.forEach { $0.stop() }
        repositoryEventWatchers.values.forEach { $0.stop() }
        sourceEventMonitors.values.forEach { $0.stop() }
        repositoryEventMonitors.values.forEach { $0.stop() }
        sourceEventWatcherGroups.removeAll()
        repositoryEventWatchers.removeAll()
        repositoryEventMonitors.removeAll()
        sourceEventMonitors.removeAll()
        sourceEventGroups.removeAll()
        repositoryCoverageOwners.removeAll()
        sourceRepositoryPathIndexes.removeAll()
        sourceEventHandler = nil
        repositoryEventHandler = nil
    }

    private func removeSourceGroup(for key: RepositoryFileEventSourceGroupKey) {
        readiness.removeSourceMonitor(groupKey: key)
        sourceEventGroups.removeValue(forKey: key)?.stop()
        sourceEventMonitors.removeValue(forKey: key)?.stop()
    }

    private func removeRepositoryWatcher(for repositoryID: UUID) {
        readiness.removeRepositoryMonitor(repositoryID: repositoryID)
        repositoryEventWatchers.removeValue(forKey: repositoryID)?.stop()
        repositoryEventMonitors.removeValue(forKey: repositoryID)?.stop()
    }

    private func deliverSourceEvents(
        _ delivery: SourceRepositoryFileEventDelivery,
        sourceID: UUID,
        groupKey: RepositoryFileEventSourceGroupKey
    ) async {
        await sourceEventHandler?(sourceID, delivery, groupKey)
    }

    private func deliverRepositoryEvents(
        _ batch: FileEventBatch,
        repositoryID: UUID
    ) async {
        await repositoryEventHandler?(batch, repositoryID)
    }
    deinit {
        sourceEventGroups.values.forEach { $0.stop() }
        repositoryEventWatchers.values.forEach { $0.stop() }
        sourceEventMonitors.values.forEach { $0.stop() }
        repositoryEventMonitors.values.forEach { $0.stop() }
    }

}
