import Foundation

actor ProcessLimiter {
    static let shared = ProcessLimiter()

    private struct Waiter {
        let id: UUID
        let priority: ProcessPriority
        let order: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumConcurrent: Int
    private var active = 0
    private var order: UInt64 = 0
    private var waiters: [Waiter] = []
#if DEBUG
    var waitingCountForTesting: Int { waiters.count }
#endif

    init(maximumConcurrent: Int = 2) {
        self.maximumConcurrent = max(1, maximumConcurrent)
    }

    func acquire(priority: ProcessPriority) async throws {
        try Task.checkCancellation()
        if active < maximumConcurrent {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard waiters.count < 256 else {
                    continuation.resume(throwing: ProcessRunnerError.processQueueFull)
                    return
                }
                order &+= 1
                waiters.append(Waiter(id: id, priority: priority, order: order, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            active -= 1
            return
        }
        let index = waiters.indices.min { lhs, rhs in
            let left = waiters[lhs]
            let right = waiters[rhs]
            if left.priority != right.priority { return left.priority == .selectedRepository }
            return left.order < right.order
        }!
        waiters.remove(at: index).continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}