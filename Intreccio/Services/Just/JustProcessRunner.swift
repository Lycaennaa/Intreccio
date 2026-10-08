import Darwin
import Foundation

nonisolated final class JustProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var processGroupID: pid_t?
    private var processGeneration: UUID?
    private var forceKillScheduled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func install(_ processGroupID: pid_t) -> (generation: UUID, accepted: Bool) {
        lock.lock()
        let generation = UUID()
        self.processGroupID = processGroupID
        processGeneration = generation
        forceKillScheduled = false
        let wasCancelled = isCancelled
        lock.unlock()
        if wasCancelled { requestTermination(processGroupID, generation: generation) }
        return (generation, !wasCancelled)
    }

    func clear(_ processGroupID: pid_t, generation: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if self.processGroupID == processGroupID, processGeneration == generation {
            self.processGroupID = nil
            processGeneration = nil
            forceKillScheduled = false
        }
    }

    func requestTermination(_ processGroupID: pid_t, generation: UUID) {
        lock.lock()
        guard self.processGroupID == processGroupID, processGeneration == generation else {
            lock.unlock()
            return
        }
        _ = kill(-processGroupID, SIGTERM)
        let shouldScheduleForceKill = !forceKillScheduled
        forceKillScheduled = true
        lock.unlock()

        if shouldScheduleForceKill {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.forceTerminate(processGroupID, generation: generation)
            }
        }
    }

    func forceTerminate(_ processGroupID: pid_t, generation: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard self.processGroupID == processGroupID, processGeneration == generation else { return }
        _ = kill(-processGroupID, SIGKILL)
    }

    func terminateRemainingProcesses(_ processGroupID: pid_t, generation: UUID) -> Bool {
        lock.lock()
        guard self.processGroupID == processGroupID, processGeneration == generation else {
            lock.unlock()
            return false
        }
        let hasRemainingProcesses = processGroupExists(processGroupID)
        if hasRemainingProcesses { _ = kill(-processGroupID, SIGTERM) }
        lock.unlock()
        guard hasRemainingProcesses else { return true }

        let gracePeriod = DispatchSemaphore(value: 0)
        _ = gracePeriod.wait(timeout: .now() + 0.1)
        lock.lock()
        guard self.processGroupID == processGroupID, processGeneration == generation else {
            lock.unlock()
            return false
        }
        let stillRunning = processGroupExists(processGroupID)
        if stillRunning { _ = kill(-processGroupID, SIGKILL) }
        lock.unlock()
        guard stillRunning else { return true }

        _ = gracePeriod.wait(timeout: .now() + 0.25)
        lock.lock()
        defer { lock.unlock() }
        guard self.processGroupID == processGroupID, processGeneration == generation else { return false }
        return !processGroupExists(processGroupID)
    }

    private func processGroupExists(_ processGroupID: pid_t) -> Bool {
        kill(-processGroupID, 0) == 0 || errno == EPERM
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let processGroupID = self.processGroupID
        let generation = processGeneration
        lock.unlock()
        if let processGroupID, let generation {
            requestTermination(processGroupID, generation: generation)
        }
    }
}

nonisolated private final class JustProcessOutput: @unchecked Sendable {
    struct Snapshot {
        let data: Data
        let exceededLimit: Bool
        let readFailed: Bool
        let reachedEndOfFile: Bool
    }

    private let lock = NSLock()
    private var data = Data()
    private var exceededLimit = false
    private var readFailed = false
    private var reachedEndOfFile = false

    func append(_ chunk: Data, maximumSize: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return false }
        guard data.count + chunk.count <= maximumSize else {
            exceededLimit = true
            return true
        }
        data.append(chunk)
        return false
    }

    func finish(readFailed: Bool) {
        lock.lock()
        self.readFailed = readFailed
        reachedEndOfFile = !readFailed
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            data: data,
            exceededLimit: exceededLimit,
            readFailed: readFailed,
            reachedEndOfFile: reachedEndOfFile
        )
    }
}

nonisolated private final class JustProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var waitStatus: Int32?

    func complete(_ waitStatus: Int32?) {
        lock.lock()
        self.waitStatus = waitStatus
        lock.unlock()
    }

    var result: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return waitStatus
    }
}

nonisolated enum JustProcessRunner {
    private static let maximumSummaryOutputSize = 1_048_576

    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        output: Pipe,
        cancellation: JustProcessCancellation?
    ) -> (Data, Int32)? {
        guard cancellation?.wasCancelled != true else { return nil }
        let outputHandle = output.fileHandleForReading
        let outputDescriptor = outputHandle.fileDescriptor
        let descriptorFlags = fcntl(outputDescriptor, F_GETFL)
        guard descriptorFlags >= 0,
              fcntl(outputDescriptor, F_SETFL, descriptorFlags | O_NONBLOCK) >= 0,
              let processGroupID = spawnProcess(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                output: output
              ) else { return nil }

        let processControl = cancellation ?? JustProcessCancellation()
        let installation = processControl.install(processGroupID)
        let generation = installation.generation
        try? output.fileHandleForWriting.close()

        let outputCapture = JustProcessOutput()
        let outputFinished = DispatchSemaphore(value: 0)
        let outputSource = DispatchSource.makeReadSource(
            fileDescriptor: outputDescriptor,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        outputSource.setEventHandler { [weak outputSource] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { buffer in
                    Darwin.read(outputDescriptor, buffer.baseAddress, buffer.count)
                }
                if bytesRead > 0 {
                    if outputCapture.append(
                        Data(buffer.prefix(bytesRead)),
                        maximumSize: maximumSummaryOutputSize
                    ) {
                        processControl.requestTermination(processGroupID, generation: generation)
                    }
                    continue
                }
                if bytesRead == 0 {
                    outputCapture.finish(readFailed: false)
                    outputSource?.cancel()
                    return
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                outputCapture.finish(readFailed: true)
                processControl.requestTermination(processGroupID, generation: generation)
                outputSource?.cancel()
                return
            }
        }
        outputSource.setCancelHandler {
            try? outputHandle.close()
            outputFinished.signal()
        }
        outputSource.resume()
        defer {
            outputSource.cancel()
            processControl.clear(processGroupID, generation: generation)
        }

        let processExit = JustProcessExit()
        let processExited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var waitStatus: Int32 = 0
            var result = waitpid(processGroupID, &waitStatus, 0)
            while result == -1, errno == EINTR {
                result = waitpid(processGroupID, &waitStatus, 0)
            }
            processExit.complete(result == processGroupID ? waitStatus : nil)
            processExited.signal()
        }

        if !installation.accepted {
            processControl.requestTermination(processGroupID, generation: generation)
        }
        let timedOut = processExited.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            processControl.requestTermination(processGroupID, generation: generation)
            if processExited.wait(timeout: .now() + 0.5) == .timedOut {
                processControl.forceTerminate(processGroupID, generation: generation)
                if processExited.wait(timeout: .now() + 0.5) == .timedOut {
                    outputSource.cancel()
                    _ = outputFinished.wait(timeout: .now() + 0.25)
                    return nil
                }
            }
        }

        var outputEnded = outputFinished.wait(timeout: .now() + 0.25) == .success
        if !outputEnded {
            processControl.requestTermination(processGroupID, generation: generation)
            outputEnded = outputFinished.wait(timeout: .now() + 0.25) == .success
        }
        if !outputEnded {
            processControl.forceTerminate(processGroupID, generation: generation)
            outputSource.cancel()
            outputEnded = outputFinished.wait(timeout: .now() + 0.25) == .success
        }

        let processGroupClean = processExit.result != nil
            && processControl.terminateRemainingProcesses(processGroupID, generation: generation)
        let outputResult = outputCapture.snapshot()
        guard !timedOut,
              cancellation?.wasCancelled != true,
              processGroupClean,
              outputEnded,
              outputResult.reachedEndOfFile,
              !outputResult.exceededLimit,
              !outputResult.readFailed,
              let waitStatus = processExit.result else { return nil }
        return (outputResult.data, exitCode(from: waitStatus))
    }

    private static func spawnProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        output: Pipe
    ) -> pid_t? {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }

        if let currentDirectoryURL {
            let result = currentDirectoryURL.path.withCString {
                posix_spawn_file_actions_addchdir_np(&fileActions, $0)
            }
            guard result == 0 else { return nil }
        }
        let outputRead = output.fileHandleForReading.fileDescriptor
        let outputWrite = output.fileHandleForWriting.fileDescriptor
        guard posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            return nil
        }
        for descriptor in [outputRead, outputWrite] where descriptor > STDERR_FILENO {
            guard posix_spawn_file_actions_addclose(&fileActions, descriptor) == 0 else { return nil }
        }
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ) == 0 else { return nil }

        let arguments = [executableURL.path] + arguments
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var processGroupID: pid_t = 0
        let result = withCStringArray(arguments) { argumentPointers in
            withCStringArray(environment) { environmentPointers in
                executableURL.path.withCString { executablePath in
                    posix_spawn(
                        &processGroupID,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        return result == 0 ? processGroupID : nil
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        let pointers: [UnsafeMutablePointer<CChar>] = strings.map { strdup($0)! }
        defer { pointers.forEach { free($0) } }
        var terminated = pointers.map { Optional($0) }
        terminated.append(nil)
        return terminated.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
    }
}
