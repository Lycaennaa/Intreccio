import Foundation

nonisolated final class LockedPipeReader: @unchecked Sendable {
    private enum State {
        case open
        case closed
    }

    let pipe = Pipe()
    private let lock = NSLock()
    private var state = State.open

    func installHandler(_ consume: @escaping @Sendable (Data) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data: Data? = self.lock.withLock {
                guard self.state == .open else { return nil }
                return handle.availableData
            }
            if let data { consume(data) }
        }
    }

    func disableAndClose() {
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.withLock {
            guard state == .open else { return }
            state = .closed
            try? pipe.fileHandleForReading.close()
        }
    }
}

nonisolated extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
