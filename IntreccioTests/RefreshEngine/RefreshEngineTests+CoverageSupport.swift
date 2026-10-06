import Foundation

internal actor MonitorFailureProbe {
    private(set) var failureCount = 0

    func recordFailure() {
        failureCount += 1
    }
}

internal actor MonitorReadinessProbe {
    private var transitions: [Bool] = []

    func record(_ ready: Bool) {
        transitions.append(ready)
    }

    func contains(_ ready: Bool) -> Bool {
        transitions.contains(ready)
    }

    func values() -> [Bool] {
        transitions
    }
}

internal final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
