import Foundation
import XCTest
@testable import Intreccio


actor FileBatchRecorder {
    private(set) var batches: [FileEventBatch] = []
    var count: Int { batches.count }
    var first: FileEventBatch? { batches.first }
    func firstValue() -> FileEventBatch? { batches.first }

    func record(_ batch: FileEventBatch) {
        batches.append(batch)
    }
}

actor StringRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

actor AsyncTestGate {
    var openNames = Set<String>()
    var continuations: [String: CheckedContinuation<Void, Never>] = [:]

    func wait(_ name: String) async {
        if openNames.remove(name) != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            continuations[name] = continuation
        }
    }

    func open(_ name: String) {
        if let continuation = continuations.removeValue(forKey: name) {
            continuation.resume()
        } else {
            openNames.insert(name)
        }
    }
}

actor RefreshOperationProbe {
    private(set) var started: [String] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    var continuations: [String: CheckedContinuation<Void, Error>] = [:]
    var cancelled = Set<String>()
    private var pendingCancellations = Set<String>()

    func run(_ name: String) async throws -> RepoStatus {
        started.append(name)
        active += 1
        maximumActive = max(maximumActive, active)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if pendingCancellations.remove(name) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuations[name] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancel(name) }
            }
            active -= 1
            return RepoStatus()
        } catch {
            active -= 1
            throw error
        }
    }

    func complete(_ name: String) {
        continuations.removeValue(forKey: name)?.resume()
    }

    func activeValue() -> Int { active }

    func cancel(_ name: String) {
        cancelled.insert(name)
        if let continuation = continuations.removeValue(forKey: name) {
            continuation.resume(throwing: CancellationError())
        } else {
            pendingCancellations.insert(name)
        }
    }
}

actor ShutdownOperationProbe {
    private(set) var started: [String] = []
    var continuation: CheckedContinuation<Void, Never>?

    func run(_ name: String) async throws -> RepoStatus {
        started.append(name)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
        return RepoStatus()
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }

    func startedValues() -> [String] { started }
}

actor ConcurrentRefreshProbe {
    var active = 0
    private(set) var maximumActive = 0

    func run() async throws -> RepoStatus {
        active += 1
        maximumActive = max(maximumActive, active)
        try await Task.sleep(for: .milliseconds(2))
        active -= 1
        return RepoStatus()
    }
}

enum RefreshProbeError: Error {
    case failed
}
