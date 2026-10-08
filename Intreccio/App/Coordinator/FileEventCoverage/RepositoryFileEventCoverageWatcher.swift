import Foundation

nonisolated struct SourceRepositoryFileEventDelivery: Sendable {
    let events: [SourceRepositoryFileEvent]
    let batch: FileEventBatch
    let caseSensitiveVolume: Bool
    let generation: UInt64?
}

private actor SourceRepositoryFileEventDebouncer {
    private let handler: @Sendable (SourceRepositoryFileEventDelivery) async -> Void
    private let maximumDelay: Duration
    private let clock = ContinuousClock()
    private var delay: Duration
    private var eventsByPath: [String: SourceRepositoryFileEvent] = [:]
    private var eventOrder: [String] = []
    private var rawPaths = Set<String>()
    private var rawSourceRescanPaths = Set<String>()
    private var requiresFullRescan = false
    private var hasUnrepresentedChanges = false
    private var firstEvent: ContinuousClock.Instant?
    private var pendingGeneration: UInt64?
    private var hasMixedGenerations = false
    private var pendingCaseSensitiveVolume = true
    private var generation: UInt64 = 0
    private var deliveryTask: Task<Void, Never>?
    private var isStopped = false

    init(
        delay: Duration = .milliseconds(500),
        maximumDelay: Duration = .seconds(2),
        handler: @escaping @Sendable (SourceRepositoryFileEventDelivery) async -> Void
    ) {
        self.delay = delay
        self.maximumDelay = maximumDelay
        self.handler = handler
    }

    func setDelay(_ newDelay: Duration, order: Int) {
        guard order > appliedDelayOrder else { return }
        appliedDelayOrder = order
        delay = min(newDelay, maximumDelay)
    }

    private var appliedDelayOrder = -1

    func submit(_ slice: SourceRepositoryFileEventSlice) {
        guard !isStopped,
              !slice.rawBatch.paths.isEmpty
                  || slice.rawBatch.requiresFullRescan
                  || slice.rawBatch.hasUnrepresentedChanges else { return }
        if firstEvent == nil {
            firstEvent = clock.now
            pendingGeneration = slice.generation
            pendingCaseSensitiveVolume = slice.caseSensitiveVolume
        } else if !hasMixedGenerations, pendingGeneration != slice.generation {
            hasMixedGenerations = true
        }

        for path in slice.rawBatch.paths {
            if rawPaths.contains(path) || rawPaths.count < FileEventDebouncer.maximumPaths {
                rawPaths.insert(path)
                if slice.rawBatch.sourceRescanPaths.contains(path) {
                    rawSourceRescanPaths.insert(path)
                }
            } else {
                requiresFullRescan = true
                hasUnrepresentedChanges = true
            }
        }
        requiresFullRescan = requiresFullRescan || slice.rawBatch.requiresFullRescan
        hasUnrepresentedChanges = hasUnrepresentedChanges || slice.rawBatch.hasUnrepresentedChanges

        for event in slice.events {
            guard rawPaths.contains(event.eventPath.path) else { continue }
            let key = event.eventPath.path
            if let existing = eventsByPath[key] {
                eventsByPath[key] = SourceRepositoryFileEvent(
                    eventPath: RepositoryFileEventPath(
                        path: existing.eventPath.path,
                        pathComponents: existing.eventPath.pathComponents,
                        isSourceRescan: existing.eventPath.isSourceRescan || event.eventPath.isSourceRescan
                    ),
                    repositories: existing.repositories,
                    deepestRepository: existing.deepestRepository
                )
            } else if eventsByPath.count < FileEventDebouncer.maximumPaths {
                eventsByPath[key] = event
                eventOrder.append(key)
            } else {
                requiresFullRescan = true
                hasUnrepresentedChanges = true
            }
        }

        generation &+= 1
        let scheduledGeneration = generation
        deliveryTask?.cancel()
        let elapsed = firstEvent.map { $0.duration(to: clock.now) } ?? .zero
        let remaining = maximumDelay - elapsed
        let sleep = min(delay, max(.zero, remaining))
        deliveryTask = Task { [weak self] in
            try? await Task.sleep(for: sleep)
            guard !Task.isCancelled else { return }
            await self?.deliver(generation: scheduledGeneration)
        }
    }

    func stop() {
        isStopped = true
        deliveryTask?.cancel()
        deliveryTask = nil
        eventsByPath.removeAll(keepingCapacity: false)
        eventOrder.removeAll(keepingCapacity: false)
        rawPaths.removeAll(keepingCapacity: false)
        rawSourceRescanPaths.removeAll(keepingCapacity: false)
        firstEvent = nil
        pendingGeneration = nil
        hasMixedGenerations = false
        requiresFullRescan = false
        hasUnrepresentedChanges = false
        generation &+= 1
    }

    private func deliver(generation scheduledGeneration: UInt64) async {
        guard scheduledGeneration == generation else { return }
        let delivery = SourceRepositoryFileEventDelivery(
            events: eventOrder.compactMap { eventsByPath[$0] },
            batch: FileEventBatch(
                paths: rawPaths,
                sourceRescanPaths: rawSourceRescanPaths,
                requiresFullRescan: requiresFullRescan,
                hasUnrepresentedChanges: hasUnrepresentedChanges
            ),
            caseSensitiveVolume: pendingCaseSensitiveVolume,
            generation: hasMixedGenerations ? nil : pendingGeneration
        )
        eventsByPath.removeAll(keepingCapacity: true)
        eventOrder.removeAll(keepingCapacity: true)
        rawPaths.removeAll(keepingCapacity: true)
        rawSourceRescanPaths.removeAll(keepingCapacity: true)
        firstEvent = nil
        pendingGeneration = nil
        hasMixedGenerations = false
        requiresFullRescan = false
        hasUnrepresentedChanges = false
        deliveryTask = nil
        await handler(delivery)
    }
}

nonisolated final class SourceRepositoryFileEventGroup: @unchecked Sendable {
    private final class DeliveryGate: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true

        func deactivate() {
            lock.lock()
            active = false
            lock.unlock()
        }

        func canDeliver() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }
    }

    private let gate = DeliveryGate()
    private let lock = NSLock()
    private let monitor: FileSystemEventMonitor
    private let router: SourceRepositoryFileEventGroupRouter
    private let handler: @Sendable (UUID, SourceRepositoryFileEventDelivery) async -> Void
    private var sourceDebouncers: [UUID: SourceRepositoryFileEventDebouncer] = [:]
    private var monitorSubscriptionID: UUID?

    init(
        monitor: FileSystemEventMonitor,
        sourceIndexes: [UUID: SourceRepositoryPathIndex],
        handler: @escaping @Sendable (UUID, SourceRepositoryFileEventDelivery) async -> Void
    ) {
        self.monitor = monitor
        router = SourceRepositoryFileEventGroupRouter(sourceIndexes: sourceIndexes)
        self.handler = handler
        monitorSubscriptionID = nil
        monitorSubscriptionID = monitor.addSubscriber { [weak self] events in
            await self?.receive(events)
        }
        update(sourceIndexes: sourceIndexes)
    }

    func update(sourceIndexes: [UUID: SourceRepositoryPathIndex]) {
        guard gate.canDeliver() else { return }
        router.update(sourceIndexes: sourceIndexes)
        lock.lock()
        let removed = sourceDebouncers.compactMap { sourceID, debouncer in
            sourceIndexes[sourceID] == nil ? debouncer : nil
        }
        sourceDebouncers = sourceDebouncers.filter { sourceIndexes[$0.key] != nil }
        for sourceID in sourceIndexes.keys where sourceDebouncers[sourceID] == nil {
            sourceDebouncers[sourceID] = SourceRepositoryFileEventDebouncer { [weak self] delivery in
                await self?.deliver(delivery, sourceID: sourceID)
            }
        }
        lock.unlock()
        for debouncer in removed {
            Task { await debouncer.stop() }
        }
    }

    func updateDebounce(_ delay: Duration, order: Int) {
        let debouncers = snapshotDebouncers()
        for debouncer in debouncers {
            Task { await debouncer.setDelay(delay, order: order) }
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        router.isCurrent(generation)
    }
    func currentGeneration() -> UInt64 {
        router.currentGeneration()
    }

    func stop() {
        gate.deactivate()
        let subscriptionID: UUID?
        let debouncers: [SourceRepositoryFileEventDebouncer]
        lock.lock()
        subscriptionID = monitorSubscriptionID
        monitorSubscriptionID = nil
        debouncers = Array(sourceDebouncers.values)
        sourceDebouncers.removeAll()
        lock.unlock()
        if let subscriptionID {
            monitor.removeSubscriber(subscriptionID)
        }
        for debouncer in debouncers {
            Task { await debouncer.stop() }
        }
    }

    private func snapshotDebouncers() -> [SourceRepositoryFileEventDebouncer] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sourceDebouncers.values)
    }

    private func receive(_ events: [FileSystemEvent]) async {
        guard gate.canDeliver(), !events.isEmpty else { return }
        let partition = router.partition(events)
        let debouncers: [(UUID, SourceRepositoryFileEventDebouncer)] = {
            lock.lock()
            defer { lock.unlock() }
            return sourceDebouncers.map { ($0.key, $0.value) }
        }()
        for (sourceID, debouncer) in debouncers {
            guard gate.canDeliver(), let slice = partition.slicesBySourceID[sourceID] else { continue }
            await debouncer.submit(slice)
        }
    }

    private func deliver(
        _ delivery: SourceRepositoryFileEventDelivery,
        sourceID: UUID
    ) async {
        guard gate.canDeliver() else { return }
        await handler(sourceID, delivery)
    }
}
