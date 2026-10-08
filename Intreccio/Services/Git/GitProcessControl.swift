import Darwin
import Foundation

nonisolated final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var processGroupID: pid_t?
    private var pauseRequested = false
    private var paused = false
    private var finished = false
    private var timeoutTimer: DispatchSourceTimer?

    var isPaused: Bool {
        lock.withLock { paused }
    }

    @discardableResult
    func pause() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            pauseRequested = true
            guard let processGroupID, !paused else { return true }
            guard kill(-processGroupID, SIGSTOP) == 0 else {
                pauseRequested = false
                return false
            }
            paused = true
            timeoutTimer?.suspend()
            return true
        }
    }

    @discardableResult
    func resume() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            pauseRequested = false
            guard let processGroupID, paused else { return true }
            let processResumed = kill(-processGroupID, SIGCONT) == 0 || errno == ESRCH
            guard processResumed else { return false }
            timeoutTimer?.resume()
            paused = false
            return true
        }
    }

    func attach(to processGroupID: pid_t) {
        lock.withLock {
            guard !finished else { return }
            self.processGroupID = processGroupID
            guard pauseRequested, !paused else { return }
            if kill(-processGroupID, SIGSTOP) == 0 {
                paused = true
                timeoutTimer?.suspend()
            } else {
                pauseRequested = false
            }
        }
    }

    func installTimeoutTimer(_ timer: DispatchSourceTimer) {
        lock.withLock {
            timeoutTimer = timer
            timer.resume()
            if paused {
                timer.suspend()
            }
        }
    }

    func cancelTimeoutTimer(_ timer: DispatchSourceTimer) {
        lock.withLock {
            guard timeoutTimer != nil else {
                timer.cancel()
                return
            }
            timeoutTimer = nil
            if paused {
                timer.resume()
            }
            timer.cancel()
        }
    }

    func markFinished() {
        lock.withLock {
            processGroupID = nil
            guard paused else { return }
            paused = false
            timeoutTimer?.resume()
        }
    }

    func finish() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            finished = true
            processGroupID = nil
            pauseRequested = false
            paused = false
            let timer = timeoutTimer
            timeoutTimer = nil
            return timer
        }
        if let timer {
            timer.resume()
            timer.cancel()
        }
    }
}
