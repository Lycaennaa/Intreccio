import Foundation

nonisolated struct FileEventBatch: Sendable, Equatable {
    var paths: Set<String>
    var sourceRescanPaths: Set<String>
    var requiresFullRescan: Bool
    var hasUnrepresentedChanges = false
}

actor FileEventDebouncer {
    static let maximumPaths = 4_096

    private var delay: Duration
    private let maximumDelay: Duration
    private let handler: @Sendable (FileEventBatch) async -> Void
    private let clock = ContinuousClock()
    private var paths = Set<String>()
    private var requiresFullRescan = false
    private var hasUnrepresentedChanges = false
    private var sourceRescanPaths = Set<String>()
    private var firstEvent: ContinuousClock.Instant?
    private var generation: UInt64 = 0
    private var deliveryTask: Task<Void, Never>?
    private var isStopped = false

    init(
        delay: Duration = .milliseconds(500),
        maximumDelay: Duration = .seconds(2),
        handler: @escaping @Sendable (FileEventBatch) async -> Void
    ) {
        self.delay = delay
        self.maximumDelay = maximumDelay
        self.handler = handler
    }

    private var appliedDelayOrder = -1

    /// `order` guards against out-of-order application when callers spawn one
    /// Task per change; only the highest order wins.
    func setDelay(_ newDelay: Duration, order: Int) {
        guard order > appliedDelayOrder else { return }
        appliedDelayOrder = order
        delay = min(newDelay, maximumDelay)
    }

    func submit(_ events: [FileSystemEvent]) {
        guard !isStopped, !events.isEmpty else { return }
        if firstEvent == nil { firstEvent = clock.now }
        for event in events {
            requiresFullRescan = requiresFullRescan || event.requiresFullRescan
            hasUnrepresentedChanges = hasUnrepresentedChanges || event.hasUnrepresentedChanges
            if paths.contains(event.path) || paths.count < Self.maximumPaths {
                paths.insert(event.path)
                if event.requiresSourceRescan { sourceRescanPaths.insert(event.path) }
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
        paths.removeAll(keepingCapacity: false)
        firstEvent = nil
        requiresFullRescan = false
        hasUnrepresentedChanges = false
        sourceRescanPaths.removeAll(keepingCapacity: false)
        generation &+= 1
    }

    private func deliver(generation scheduledGeneration: UInt64) async {
        guard scheduledGeneration == generation else { return }
        let batch = FileEventBatch(
            paths: paths,
            sourceRescanPaths: sourceRescanPaths,
            requiresFullRescan: requiresFullRescan,
            hasUnrepresentedChanges: hasUnrepresentedChanges
        )
        paths.removeAll(keepingCapacity: true)
        firstEvent = nil
        requiresFullRescan = false
        hasUnrepresentedChanges = false
        sourceRescanPaths.removeAll(keepingCapacity: true)
        deliveryTask = nil
        await handler(batch)
    }
}
