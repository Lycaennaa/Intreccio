import Darwin
import Foundation

nonisolated final class ProcessInvocation: @unchecked Sendable {

    private enum StopReason {
        case timeout
        case cancellation
        case outputLimit(ProcessOutputStream)
    }

    private enum StopCleanup {
        case awaitingLaunch
        case waitingForEscalation
        case finished
    }

    private enum Lifecycle {
        case launching
        case running(pid_t)
        case stopping(pid: pid_t?, reason: StopReason, cleanup: StopCleanup)
        case completed
    }

    private enum ProcessOutcome {
        case pending
        case exited(Int32)
    }

    private enum InputStatus {
        case writing
        case ended
    }

    private struct StreamCapture {
        enum Status {
            case reading
            case ended
        }

        var status = Status.reading
        var data = Data()
    }

    private struct InvocationState {
        var lifecycle = Lifecycle.launching
        var process = ProcessOutcome.pending
        var input = InputStatus.writing
        var standardOutput = StreamCapture()
        var standardError = StreamCapture()
        var continuation: CheckedContinuation<ProcessCommandResult, Error>?
        var timeoutTimer: DispatchSourceTimer?
    }

    private enum Event {
        case installContinuation(CheckedContinuation<ProcessCommandResult, Error>)
        case launched(pid_t)
        case launchFailed(String)
        case timerPrepared(DispatchSourceTimer)
        case stopRequested(StopReason)
        case inputEnded
        case output(Data, ProcessOutputStream)
        case processExited(Int32)
        case stopCleanupFinished
    }

    private enum Effect {
        case activateTimer(DispatchSourceTimer)
        case disposeUnstartedTimer(DispatchSourceTimer)
        case cancelTimer(DispatchSourceTimer)
        case terminateProcessGroup(pid_t)
        case cleanupLaunchFailure
        case reportOutput(ProcessOutputStream, Data)
        case resume(CheckedContinuation<ProcessCommandResult, Error>, Result<ProcessCommandResult, Error>)
    }

    private let lock = NSLock()
    private let standardOutputReader = LockedPipeReader()
    private let standardErrorReader = LockedPipeReader()
    private let standardInputPipe = Pipe()
    private let executable: String
    private let repository: URL?
    private let arguments: [String]
    private let environment: [String: String]
    private let acceptedExitCodes: Set<Int32>
    private let outputLimit: Int
    private let outputLimitBehavior: ProcessOutputLimitBehavior
    private let timeout: Duration?
    private let input: Data?
    private let outputHandler: (@Sendable (ProcessOutputStream, Data) -> Void)?
    private let control: ProcessControl?

    private var state = InvocationState()

    init(
        executable: String,
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        outputLimitBehavior: ProcessOutputLimitBehavior = .terminate,
        timeout: Duration?,
        outputHandler: (@Sendable (ProcessOutputStream, Data) -> Void)? = nil,
        control: ProcessControl? = nil
    ) {
        self.executable = executable
        self.repository = repository
        self.arguments = arguments
        self.environment = environment
        self.input = input
        self.acceptedExitCodes = acceptedExitCodes
        self.outputLimit = outputLimit
        self.outputLimitBehavior = outputLimitBehavior
        self.timeout = timeout
        self.outputHandler = outputHandler
        self.control = control
    }

    func start() async throws -> ProcessCommandResult {
        try await withTaskCancellationHandler {
            try await startProcess()
        } onCancel: {
            send(.stopRequested(.cancellation))
        }
    }

    func startFinishingAfterLaunch() async throws -> ProcessCommandResult {
        try Task.checkCancellation()
        return try await startProcess()
    }

    private func startProcess() async throws -> ProcessCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            send(.installContinuation(continuation))
            installHandlers()
            do {
                let processID = try launchProcess()
                writeInputAndClose()
                send(.launched(processID))
                if let timeoutTimer = makeTimeoutTimer() {
                    send(.timerPrepared(timeoutTimer))
                }
            } catch {
                send(.launchFailed(error.localizedDescription))
            }
        }
    }

    private func send(_ event: Event) {
        let effects = lock.withLock { transition(event) }
        effects.forEach(perform)
    }

    private func transition(_ event: Event) -> [Effect] {
        guard case .completed = state.lifecycle else {
            var effects: [Effect] = []
            switch event {
            case .installContinuation(let continuation):
                state.continuation = continuation
            case .launched(let processID):
                switch state.lifecycle {
                case .launching:
                    state.lifecycle = .running(processID)
                case .stopping(nil, let reason, .awaitingLaunch):
                    beginStopping(processID: processID, reason: reason, effects: &effects)
                case .running, .stopping, .completed:
                    break
                }
            case .launchFailed(let message):
                completeLaunchFailure(message, effects: &effects)
                return effects
            case .timerPrepared(let timer):
                if case .running = state.lifecycle, state.timeoutTimer == nil {
                    state.timeoutTimer = timer
                    effects.append(.activateTimer(timer))
                } else {
                    effects.append(.disposeUnstartedTimer(timer))
                }
            case .stopRequested(let reason):
                requestStop(reason, effects: &effects)
            case .inputEnded:
                state.input = .ended
            case .output(let data, let stream):
                consume(data, from: stream, effects: &effects)
            case .processExited(let exitCode):
                state.process = .exited(exitCode)
            case .stopCleanupFinished:
                if case .stopping(let processID, let reason, .waitingForEscalation) = state.lifecycle {
                    state.lifecycle = .stopping(pid: processID, reason: reason, cleanup: .finished)
                }
            }
            finishIfReady(effects: &effects)
            return effects
        }

        if case .timerPrepared(let timer) = event {
            return [.disposeUnstartedTimer(timer)]
        }
        return []
    }

    private func requestStop(_ reason: StopReason, effects: inout [Effect]) {
        switch state.lifecycle {
        case .launching:
            state.lifecycle = .stopping(pid: nil, reason: reason, cleanup: .awaitingLaunch)
        case .running(let processID):
            beginStopping(processID: processID, reason: reason, effects: &effects)
        case .stopping, .completed:
            break
        }
    }

    private func beginStopping(processID: pid_t, reason: StopReason, effects: inout [Effect]) {
        state.lifecycle = .stopping(
            pid: processID,
            reason: reason,
            cleanup: .waitingForEscalation
        )
        state.standardOutput.status = .ended
        state.standardError.status = .ended
        effects.append(.terminateProcessGroup(processID))
    }

    private func consume(_ data: Data, from stream: ProcessOutputStream, effects: inout [Effect]) {
        var capture = stream == .standardOutput ? state.standardOutput : state.standardError
        guard capture.status == .reading else { return }
        var exceededLimit = false
        if data.isEmpty {
            capture.status = .ended
        } else {
            let remaining = max(0, outputLimit - capture.data.count)
            capture.data.append(data.prefix(remaining))
            exceededLimit = data.count > remaining
        }
        if stream == .standardOutput {
            state.standardOutput = capture
        } else {
            state.standardError = capture
        }
        if !data.isEmpty, outputHandler != nil {
            effects.append(.reportOutput(stream, data))
        }
        if exceededLimit,
           outputLimitBehavior == .terminate {
            requestStop(.outputLimit(stream), effects: &effects)
        }
    }

    private func finishIfReady(effects: inout [Effect]) {
        guard let continuation = state.continuation,
              case .exited(let exitCode) = state.process,
              state.input == .ended,
              state.standardOutput.status == .ended,
              state.standardError.status == .ended else {
            return
        }

        let stopReason: StopReason?
        switch state.lifecycle {
        case .running:
            stopReason = nil
        case .stopping(_, let reason, .finished):
            stopReason = reason
        case .launching, .stopping, .completed:
            return
        }

        let result = ProcessCommandResult(
            exitCode: exitCode,
            standardOutput: state.standardOutput.data,
            standardError: state.standardError.data
        )
        let completion: Result<ProcessCommandResult, Error>
        switch stopReason {
        case .timeout:
            completion = .failure(ProcessRunnerError.timedOut(result))
        case .cancellation:
            completion = .failure(ProcessRunnerError.cancelled(result))
        case .outputLimit(let stream):
            completion = .failure(ProcessRunnerError.outputLimitExceeded(
                stream: stream,
                limit: outputLimit,
                result: result
            ))
        case nil where !acceptedExitCodes.contains(exitCode):
            completion = .failure(ProcessRunnerError.nonZeroExit(result))
        case nil:
            completion = .success(result)
        }
        complete(continuation: continuation, result: completion, effects: &effects)
    }

    private func completeLaunchFailure(_ message: String, effects: inout [Effect]) {
        guard let continuation = state.continuation else { return }
        effects.append(.cleanupLaunchFailure)
        complete(
            continuation: continuation,
            result: .failure(ProcessRunnerError.launchFailed(message)),
            effects: &effects
        )
    }

    private func complete(
        continuation: CheckedContinuation<ProcessCommandResult, Error>,
        result: Result<ProcessCommandResult, Error>,
        effects: inout [Effect]
    ) {
        control?.markFinished()
        state.lifecycle = .completed
        state.continuation = nil
        if let timer = state.timeoutTimer {
            state.timeoutTimer = nil
            effects.append(.cancelTimer(timer))
        }
        effects.append(.resume(continuation, result))
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .activateTimer(let timer):
            if let control {
                control.installTimeoutTimer(timer)
            } else {
                timer.resume()
            }
        case .disposeUnstartedTimer(let timer):
            timer.cancel()
            timer.resume()
        case .cancelTimer(let timer):
            if let control {
                control.cancelTimeoutTimer(timer)
            } else {
                timer.cancel()
            }
        case .terminateProcessGroup(let processID):
            terminateProcessGroup(processID)
        case .cleanupLaunchFailure:
            cleanupAfterLaunchFailure()
        case .resume(let continuation, let result):
            continuation.resume(with: result)
        case .reportOutput(let stream, let data):
            outputHandler?(stream, data)
        }
    }

    private func launchProcess() throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checkPOSIX(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try checkPOSIX(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        let inputRead = standardInputPipe.fileHandleForReading.fileDescriptor
        let inputWrite = standardInputPipe.fileHandleForWriting.fileDescriptor
        let outputRead = standardOutputReader.pipe.fileHandleForReading.fileDescriptor
        let outputWrite = standardOutputReader.pipe.fileHandleForWriting.fileDescriptor
        let errorRead = standardErrorReader.pipe.fileHandleForReading.fileDescriptor
        let errorWrite = standardErrorReader.pipe.fileHandleForWriting.fileDescriptor
        try checkPOSIX(fcntl(inputWrite, F_SETNOSIGPIPE, 1))
        try checkPOSIX(posix_spawn_file_actions_adddup2(&fileActions, inputRead, STDIN_FILENO))
        try checkPOSIX(posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDOUT_FILENO))
        try checkPOSIX(posix_spawn_file_actions_adddup2(&fileActions, errorWrite, STDERR_FILENO))
        for descriptor in [inputRead, inputWrite, outputRead, outputWrite, errorRead, errorWrite] where descriptor > STDERR_FILENO {
            try checkPOSIX(posix_spawn_file_actions_addclose(&fileActions, descriptor))
        }
        try checkPOSIX(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ))

        let invocationArguments = [executable] + (repository.map { ["-C", $0.path] } ?? []) + arguments
        let processEnvironment = GitProcessEnvironment.prepare(
            inherited: ProcessInfo.processInfo.environment,
            overrides: environment
        )
        let environmentStrings = processEnvironment.map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        let spawnResult = withCStringArray(invocationArguments) { argumentPointers in
            withCStringArray(environmentStrings) { environmentPointers in
                executable.withCString { executablePointer in
                    posix_spawn(
                        &processID,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        try checkPOSIX(spawnResult)
        let launchedProcessID = processID
        control?.attach(to: launchedProcessID)
        try? standardInputPipe.fileHandleForReading.close()
        try? standardOutputReader.pipe.fileHandleForWriting.close()
        try? standardErrorReader.pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(launchedProcessID, &status, 0) == -1, errno == EINTR {}
            self?.send(.processExited(Self.exitCode(from: status)))
        }
        return launchedProcessID
    }

    private func installHandlers() {
        standardOutputReader.installHandler { [weak self] data in
            self?.send(.output(data, .standardOutput))
        }
        standardErrorReader.installHandler { [weak self] data in
            self?.send(.output(data, .standardError))
        }
    }

    private func writeInputAndClose() {
        let handle = standardInputPipe.fileHandleForWriting
        let input = input
        DispatchQueue.global(qos: .utility).async { [self] in
            if let input {
                try? handle.write(contentsOf: input)
            }
            try? handle.close()
            send(.inputEnded)
        }
    }

    private func makeTimeoutTimer() -> DispatchSourceTimer? {
        guard let timeout else { return nil }
        let components = timeout.components
        let seconds = max(0, components.seconds)
        let nanoseconds = max(0, components.attoseconds / 1_000_000_000)
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let totalNanoseconds: Int64
        if multiplied.overflow || multiplied.partialValue > Int64.max - nanoseconds {
            totalNanoseconds = Int64.max
        } else {
            totalNanoseconds = multiplied.partialValue + nanoseconds
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .nanoseconds(Int(clamping: totalNanoseconds)))
        timer.setEventHandler { [weak self] in self?.send(.stopRequested(.timeout)) }
        return timer
    }

    private func terminateProcessGroup(_ processID: pid_t) {
        standardOutputReader.disableAndClose()
        standardErrorReader.disableAndClose()
        _ = kill(-processID, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            if kill(-processID, 0) == 0 {
                _ = kill(-processID, SIGKILL)
            }
            send(.stopCleanupFinished)
        }
    }

    private func cleanupAfterLaunchFailure() {
        standardOutputReader.disableAndClose()
        standardErrorReader.disableAndClose()
        try? standardInputPipe.fileHandleForReading.close()
        try? standardInputPipe.fileHandleForWriting.close()
        try? standardOutputReader.pipe.fileHandleForWriting.close()
        try? standardErrorReader.pipe.fileHandleForWriting.close()
    }

    private func checkPOSIX(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }

    private func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) rethrows -> T {
        let pointers: [UnsafeMutablePointer<CChar>] = strings.map { strdup($0)! }
        defer { pointers.forEach { free($0) } }
        var terminated = pointers.map { Optional($0) }
        terminated.append(nil)
        return try terminated.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
    }
}
