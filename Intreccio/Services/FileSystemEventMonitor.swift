import CoreServices
import Foundation

nonisolated struct FileSystemEvent: Sendable, Equatable {
    let path: String
    let requiresFullRescan: Bool
    let requiresSourceRescan: Bool
    let hasUnrepresentedChanges: Bool

    init(
        path: String,
        requiresFullRescan: Bool,
        requiresSourceRescan: Bool = false,
        hasUnrepresentedChanges: Bool = false
    ) {
        self.path = path
        self.requiresFullRescan = requiresFullRescan
        self.requiresSourceRescan = requiresSourceRescan
        self.hasUnrepresentedChanges = hasUnrepresentedChanges
    }
}

nonisolated final class FileSystemEventMonitor: @unchecked Sendable {
    typealias EventHandler = @Sendable ([FileSystemEvent]) async -> Void
    typealias ReadinessHandler = @Sendable (Bool) -> Void
    typealias StreamCreator = (
        [String],
        FSEventStreamCallback,
        UnsafeMutablePointer<FSEventStreamContext>
    ) -> FSEventStreamRef?
    typealias StreamStarter = (FSEventStreamRef) -> Bool

    private let queue = DispatchQueue(label: "Intreccio.fsevents", qos: .utility)
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueID = UUID()
    private let handler: EventHandler
    private let streamCreator: StreamCreator
    private let streamStarter: StreamStarter
    private let retryDelay: TimeInterval
    private let readinessHandler: @Sendable (Bool) -> Void
    private let streamFailureHandler: @Sendable () -> Void
    private var subscribers: [UUID: EventHandler] = [:]
    private var readinessSubscribers: [UUID: ReadinessHandler] = [:]
    private var stream: FSEventStreamRef?
    private var coveragePaths: [String] = []
    private var requestedCoveragePaths: [String] = []
    private var retryWorkItem: DispatchWorkItem?
    private var streamIsReady = false
    private var isStopped = false
    private var pendingEvents: [String: FileSystemEvent] = [:]
    private var pendingEventOrder: [String] = []
    private var deliveryInFlight = false
    private var deliveryTask: Task<Void, Never>?

    init(
        handler: @escaping EventHandler,
        streamCreator: @escaping StreamCreator = { paths, callback, context in
            FSEventStreamCreate(
                nil,
                callback,
                context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.25,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
            )
        },
        streamStarter: @escaping StreamStarter = { FSEventStreamStart($0) },
        retryDelay: TimeInterval = 1,
        readinessHandler: @escaping @Sendable (Bool) -> Void = { _ in },
        streamFailureHandler: @escaping @Sendable () -> Void = {}
    ) {
        self.handler = handler
        self.streamCreator = streamCreator
        self.streamStarter = streamStarter
        self.retryDelay = max(0.01, retryDelay)
        self.readinessHandler = readinessHandler
        self.streamFailureHandler = streamFailureHandler
        queue.setSpecific(key: queueKey, value: queueID)
    }

    var isReady: Bool {
        if DispatchQueue.getSpecific(key: queueKey) == queueID {
            return streamIsReady
        }
        return queue.sync { streamIsReady }
    }
    @discardableResult
    func addReadinessSubscriber(_ handler: @escaping ReadinessHandler) -> UUID {
        let id = UUID()
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.readinessSubscribers[id] = handler
            handler(self.streamIsReady)
        }
        return id
    }

    func removeReadinessSubscriber(_ id: UUID) {
        if DispatchQueue.getSpecific(key: queueKey) == queueID {
            readinessSubscribers.removeValue(forKey: id)
        } else {
            queue.sync { _ = readinessSubscribers.removeValue(forKey: id) }
        }
    }

    deinit {
        stop()
    }

    func addSubscriber(_ handler: @escaping EventHandler) -> UUID {
        let id = UUID()
        if DispatchQueue.getSpecific(key: queueKey) == queueID {
            subscribers[id] = handler
        } else {
            queue.sync { subscribers[id] = handler }
        }
        return id
    }

    func removeSubscriber(_ id: UUID) {
        if DispatchQueue.getSpecific(key: queueKey) == queueID {
            subscribers.removeValue(forKey: id)
        } else {
            queue.sync { _ = subscribers.removeValue(forKey: id) }
        }
    }

    func updateCoverage(_ urls: [URL]) {
        let paths = Self.normalizedCoverage(urls).map(\.path)
        queue.async { [weak self] in self?.requestCoverage(paths) }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == queueID {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    static func normalizedCoverage(_ urls: [URL]) -> [URL] {
        let sorted = Set(urls.map { RepositoryPathPolicy.canonicalURL($0).path })
            .map { path -> (path: String, pathComponents: [String]) in
                let url = URL(fileURLWithPath: path, isDirectory: true)
                return (path: path, pathComponents: url.pathComponents)
            }
            .sorted {
                let lhsCount = $0.pathComponents.count
                let rhsCount = $1.pathComponents.count
                return lhsCount == rhsCount ? $0.path < $1.path : lhsCount < rhsCount
            }
        var caseSensitivityByPath: [String: Bool] = [:]
        func caseSensitive(for path: String) -> Bool {
            if let cached = caseSensitivityByPath[path] { return cached }
            let value = RepositoryPathPolicy.isCaseSensitiveVolume(
                at: URL(fileURLWithPath: path, isDirectory: true)
            )
            caseSensitivityByPath[path] = value
            return value
        }

        var caseSensitiveRoots = RepositoryFileEventPathPrefixIndex()
        var caseInsensitiveRoots = RepositoryFileEventPathPrefixIndex()
        var allCaseInsensitiveRoots = RepositoryFileEventPathPrefixIndex()
        var result: [URL] = []
        for root in sorted {
            let caseSensitive = caseSensitive(for: root.path)
            let caseInsensitivePathComponents = root.pathComponents.map {
                $0.folding(options: .caseInsensitive, locale: nil)
            }
            let hasAncestor: Bool
            if caseSensitive {
                hasAncestor = caseSensitiveRoots.firstValue(
                    onPrefixOf: root.pathComponents
                ) != nil || caseInsensitiveRoots.firstValue(
                    onPrefixOf: caseInsensitivePathComponents
                ) != nil
            } else {
                hasAncestor = allCaseInsensitiveRoots.firstValue(
                    onPrefixOf: caseInsensitivePathComponents
                ) != nil
            }
            guard !hasAncestor else { continue }

            result.append(URL(fileURLWithPath: root.path, isDirectory: true))
            let value = result.count - 1
            if caseSensitive {
                caseSensitiveRoots.insert(root.pathComponents, value: value)
            } else {
                caseInsensitiveRoots.insert(caseInsensitivePathComponents, value: value)
            }
            allCaseInsensitiveRoots.insert(caseInsensitivePathComponents, value: value)
        }
        return result
    }

    private func requestCoverage(_ paths: [String]) {
        guard !isStopped, paths != requestedCoveragePaths else { return }
        requestedCoveragePaths = paths
        retryWorkItem?.cancel()
        retryWorkItem = nil
        replaceStream(paths: paths)
    }

    private func replaceStream(paths: [String]) {
        guard !isStopped else { return }
        retryWorkItem = nil
        guard !paths.isEmpty else {
            requestedCoveragePaths = []
            tearDownStream()
            setStreamReady(false)
            return
        }
        guard paths != coveragePaths else {
            setStreamReady(stream != nil)
            return
        }
        setStreamReady(false)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<FileSystemEventMonitor>.fromOpaque(info).takeUnretainedValue()
            let pathPointers = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            let limit = min(count, FileEventDebouncer.maximumPaths)
            var events: [FileSystemEvent] = []
            events.reserveCapacity(limit)
            for index in 0..<limit {
                guard let pointer = pathPointers[index] else { continue }
                let flag = flags[index]
                let requiresFullRescan = flag & (
                    FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
                ) != 0
                let hasUnrepresentedChanges = flag & (
                    FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
                ) != 0 || count > limit
                events.append(FileSystemEvent(
                    path: RepositoryPathPolicy.standardizedURL(URL(fileURLWithPath: String(cString: pointer))).path,
                    requiresFullRescan: requiresFullRescan || count > limit,
                    requiresSourceRescan: flag & (
                        FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
                    ) != 0,
                    hasUnrepresentedChanges: hasUnrepresentedChanges
                ))
            }
            monitor.accept(events)
        }
        guard let stream = streamCreator(paths, callback, &context) else {
            reportStreamFailure(paths: paths)
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard streamStarter(stream) else {
            tearDown(stream)
            reportStreamFailure(paths: paths)
            return
        }
        let previous = self.stream
        self.stream = stream
        coveragePaths = paths
        setStreamReady(true)
        if let previous { tearDown(previous) }
    }

    private func reportStreamFailure(paths: [String]) {
        setStreamReady(false)
        streamFailureHandler()
        scheduleRetry(paths: paths)
    }

    private func scheduleRetry(paths: [String]) {
        guard !isStopped,
              retryWorkItem == nil,
              requestedCoveragePaths == paths else { return }
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.requestedCoveragePaths == paths else { return }
            self.retryWorkItem = nil
            self.replaceStream(paths: paths)
        }
        retryWorkItem = retry
        queue.asyncAfter(
            deadline: .now() + retryDelay,
            execute: retry
        )
    }

    private func setStreamReady(_ ready: Bool) {
        guard streamIsReady != ready else { return }
        streamIsReady = ready
        readinessHandler(ready)
        for handler in Array(readinessSubscribers.values) {
            handler(ready)
        }
    }

    private func tearDownStream() {
        if let stream { tearDown(stream) }
        coveragePaths = []
        self.stream = nil
    }

    private func stopOnQueue() {
        isStopped = true
        requestedCoveragePaths = []
        retryWorkItem?.cancel()
        retryWorkItem = nil
        tearDownStream()
        setStreamReady(false)
        deliveryTask?.cancel()
        deliveryTask = nil
        pendingEvents.removeAll(keepingCapacity: false)
        pendingEventOrder.removeAll(keepingCapacity: false)
        subscribers.removeAll(keepingCapacity: false)
        readinessSubscribers.removeAll(keepingCapacity: false)
        deliveryInFlight = false
    }

    private func tearDown(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func accept(_ events: [FileSystemEvent]) {
        for event in events {
            if let existing = pendingEvents[event.path] {
                pendingEvents[event.path] = FileSystemEvent(
                    path: event.path,
                    requiresFullRescan: existing.requiresFullRescan || event.requiresFullRescan,
                    requiresSourceRescan: existing.requiresSourceRescan || event.requiresSourceRescan,
                    hasUnrepresentedChanges: existing.hasUnrepresentedChanges || event.hasUnrepresentedChanges
                )
            } else if pendingEvents.count < FileEventDebouncer.maximumPaths {
                pendingEvents[event.path] = event
                pendingEventOrder.append(event.path)
            } else if let key = pendingEventOrder.first, let existing = pendingEvents[key] {
                pendingEvents[key] = FileSystemEvent(
                    path: existing.path,
                    requiresFullRescan: true,
                    requiresSourceRescan: existing.requiresSourceRescan,
                    hasUnrepresentedChanges: true
                )
            }
        }
        deliverIfNeeded()
    }

    private func deliverIfNeeded() {
        guard !deliveryInFlight, !pendingEvents.isEmpty else { return }
        deliveryInFlight = true
        let events = pendingEventOrder.compactMap { pendingEvents[$0] }
        let handlers = [handler] + subscribers.values
        pendingEvents.removeAll(keepingCapacity: true)
        pendingEventOrder.removeAll(keepingCapacity: true)
        deliveryTask = Task { [weak self, handlers] in
            guard !Task.isCancelled else { return }
            for handler in handlers {
                guard !Task.isCancelled else { return }
                await handler(events)
            }
            self?.queue.async { [weak self] in
                guard let self else { return }
                deliveryTask = nil
                guard !Task.isCancelled else { return }
                deliveryInFlight = false
                deliverIfNeeded()
            }
        }
    }
}

nonisolated final class FileEventWatcher: @unchecked Sendable {
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

    private let gate: DeliveryGate
    private let debouncer: FileEventDebouncer
    private let monitor: FileSystemEventMonitor
    private let monitorSubscriptionID: UUID?

    init(handler: @escaping @Sendable (FileEventBatch) async -> Void) {
        let gate = DeliveryGate()
        let debouncer = FileEventDebouncer { [weak gate] batch in
            guard gate?.canDeliver() == true else { return }
            await handler(batch)
        }
        self.gate = gate
        self.debouncer = debouncer
        monitor = FileSystemEventMonitor { events in
            await debouncer.submit(events)
        }
        monitorSubscriptionID = nil
    }

    init(
        monitor: FileSystemEventMonitor,
        handler: @escaping @Sendable (FileEventBatch) async -> Void
    ) {
        let gate = DeliveryGate()
        let debouncer = FileEventDebouncer { [weak gate] batch in
            guard gate?.canDeliver() == true else { return }
            await handler(batch)
        }
        self.gate = gate
        self.debouncer = debouncer
        self.monitor = monitor
        monitorSubscriptionID = monitor.addSubscriber { events in
            await debouncer.submit(events)
        }
    }

    var isReady: Bool { monitor.isReady }
    func updateCoverage(_ url: URL) {
        guard monitorSubscriptionID == nil else { return }
        monitor.updateCoverage([url])
    }

    func updateDebounce(_ delay: Duration, order: Int) {
        let debouncer = debouncer
        Task { await debouncer.setDelay(delay, order: order) }
    }

    func stop() {
        gate.deactivate()
        if let monitorSubscriptionID {
            monitor.removeSubscriber(monitorSubscriptionID)
        } else {
            monitor.stop()
        }
        let debouncer = debouncer
        Task { await debouncer.stop() }
    }

    deinit {
        stop()
    }
}
