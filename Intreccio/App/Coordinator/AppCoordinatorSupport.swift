import Foundation


nonisolated enum TaskCompletionDrain {
    static func waitForCompletion(_ tasks: [Task<Void, Never>]) async {
        await withTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask { await task.value }
            }
        }
    }
}
nonisolated final class BoundedKeyedAsyncStream<Element: Sendable, Key: Hashable & Sendable>: @unchecked Sendable {
    private struct CapacityWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private enum SendAction {
        case finished
        case delivered(CheckedContinuation<Element?, Never>)
        case sent
        case wait(UInt64)
    }

    private enum NextAction {
        case deliver(Element, CapacityWaiter?)
        case finish
        case wait
        case noConsumer
    }

    private let maximumPendingElements: Int
    private let keyForElement: @Sendable (Element) -> Key
    private let lock = NSLock()
    private var pendingElements: [Key: Element] = [:]
    private var pendingOrder: [Key] = []
    private var pendingOrderHead = 0
    private var nextContinuation: CheckedContinuation<Element?, Never>?
    private var capacityWaiters: [CapacityWaiter] = []
    private var capacityGeneration: UInt64 = 0
    private var isFinished = false
    private var stream: AsyncStream<Element>?

    init(
        maximumPendingElements: Int,
        key: @escaping @Sendable (Element) -> Key
    ) {
        self.maximumPendingElements = max(1, maximumPendingElements)
        keyForElement = key
    }

    var asyncStream: AsyncStream<Element> {
        withLock {
            if let stream = self.stream { return stream }
            let stream = AsyncStream<Element>(
                unfolding: { [weak self] in
                    await self?.next()
                },
                onCancel: { [weak self] in
                    self?.cancelConsumer()
                }
            )
            self.stream = stream
            return stream
        }
    }
    private func cancelConsumer() {
        let result: (
            CheckedContinuation<Element?, Never>?,
            [CapacityWaiter]
        ) = withLock {
            guard !isFinished else { return (nil, []) }
            isFinished = true
            pendingElements.removeAll(keepingCapacity: false)
            pendingOrder.removeAll(keepingCapacity: false)
            pendingOrderHead = 0
            let next = nextContinuation
            nextContinuation = nil
            let waiters = capacityWaiters
            capacityWaiters.removeAll(keepingCapacity: false)
            return (next, waiters)
        }
        result.0?.resume(returning: nil)
        result.1.forEach { $0.continuation.resume(returning: false) }
    }


    var pendingCount: Int {
        withLock { pendingElements.count }
    }

    var waitingProducerCount: Int {
        withLock { capacityWaiters.count }
    }

    func send(_ element: Element) async {
        let key = keyForElement(element)
        while !Task.isCancelled {
            switch prepareSend(element, key: key) {
            case .finished, .sent:
                return
            case .delivered(let continuation):
                continuation.resume(returning: element)
                return
            case .wait(let generation):
                guard await waitForCapacity(after: generation) else { return }
            }
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let next = nextContinuation
        nextContinuation = nil
        let waiters = capacityWaiters
        capacityWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        next?.resume(returning: nil)
        waiters.forEach { $0.continuation.resume(returning: false) }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private func prepareSend(_ element: Element, key: Key) -> SendAction {
        withLock {
            if isFinished { return .finished }
            if let continuation = nextContinuation {
                nextContinuation = nil
                return .delivered(continuation)
            }
            if pendingElements[key] != nil {
                pendingElements[key] = element
                return .sent
            }
            if pendingElements.count < maximumPendingElements {
                pendingElements[key] = element
                pendingOrder.append(key)
                return .sent
            }
            return .wait(capacityGeneration)
        }
    }

    private func next() async -> Element? {
        await withTaskCancellationHandler {
            if Task.isCancelled {
                cancelConsumer()
                return nil
            }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
                switch prepareNext(continuation) {
                case .deliver(let element, let capacityWaiter):
                    capacityWaiter?.continuation.resume(returning: true)
                    continuation.resume(returning: element)
                case .finish, .noConsumer:
                    continuation.resume(returning: nil)
                case .wait:
                    break
                }
            }
        } onCancel: { [weak self] in
            self?.cancelConsumer()
        }
    }

    private func prepareNext(
        _ continuation: CheckedContinuation<Element?, Never>
    ) -> NextAction {
        withLock {
            if let element = dequeuePendingElement() {
                return .deliver(element, dequeueCapacityWaiter())
            }
            if isFinished || Task.isCancelled { return .finish }
            if nextContinuation == nil {
                nextContinuation = continuation
                return .wait
            }
            return .noConsumer
        }
    }

    private func waitForCapacity(after generation: UInt64) async -> Bool {
        guard !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let result = prepareCapacityWaiter(
                    id: id,
                    generation: generation,
                    continuation: continuation
                )
                if let result {
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { [weak self] in
            self?.cancelCapacityWaiter(id)
        }
    }

    private func prepareCapacityWaiter(
        id: UUID,
        generation: UInt64,
        continuation: CheckedContinuation<Bool, Never>
    ) -> Bool? {
        withLock {
            if isFinished || Task.isCancelled { return false }
            if pendingElements.count < maximumPendingElements
                || capacityGeneration != generation {
                return true
            }
            capacityWaiters.append(CapacityWaiter(id: id, continuation: continuation))
            return nil
        }
    }

    private func dequeuePendingElement() -> Element? {
        while pendingOrderHead < pendingOrder.count {
            let key = pendingOrder[pendingOrderHead]
            pendingOrderHead += 1
            if let element = pendingElements.removeValue(forKey: key) {
                if pendingOrderHead >= 64,
                   pendingOrderHead * 2 >= pendingOrder.count {
                    pendingOrder.removeFirst(pendingOrderHead)
                    pendingOrderHead = 0
                }
                capacityGeneration &+= 1
                return element
            }
        }
        pendingOrder.removeAll(keepingCapacity: true)
        pendingOrderHead = 0
        return nil
    }

    private func dequeueCapacityWaiter() -> CapacityWaiter? {
        guard !capacityWaiters.isEmpty else { return nil }
        return capacityWaiters.removeFirst()
    }


    private func cancelCapacityWaiter(_ id: UUID) {
        let waiter: CapacityWaiter? = withLock {
            guard let index = capacityWaiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return capacityWaiters.remove(at: index)
        }
        waiter?.continuation.resume(returning: false)
    }
}





nonisolated enum CoordinatorError: Error, CustomStringConvertible {
    case invalidRepository(String)

    var description: String {
        switch self {
        case .invalidRepository(let message): message
        }
    }
}
