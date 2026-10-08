import Foundation

nonisolated struct ProcessCommandResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data

    var standardErrorText: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

nonisolated enum ProcessOutputStream: String, Sendable {
    case standardOutput
    case standardError
}

nonisolated enum ProcessPriority: Sendable {
    case selectedRepository
    case normal
}

nonisolated protocol ProcessRunning: Sendable {
    func execute(
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        timeout: Duration,
        priority: ProcessPriority
    ) async throws -> ProcessCommandResult
    func executeStreaming(
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        timeout: Duration,
        priority: ProcessPriority,
        progress: @escaping @Sendable (ProcessOutputStream, Data) -> Void,
        control: ProcessControl?
    ) async throws -> ProcessCommandResult
}

extension ProcessRunning {
    func run(
        repository: URL? = nil,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:],
        acceptedExitCodes: Set<Int32> = [0],
        outputLimit: Int = ProcessRunner.defaultOutputLimit,
        timeout: Duration = ProcessRunner.readTimeout,
        priority: ProcessPriority = .normal
    ) async throws -> ProcessCommandResult {
        try await execute(
            repository: repository,
            arguments: arguments,
            input: input,
            environment: environment,
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            priority: priority
        )
    }

    func runStreaming(
        repository: URL? = nil,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:],
        acceptedExitCodes: Set<Int32> = [0],
        outputLimit: Int = ProcessRunner.defaultOutputLimit,
        timeout: Duration = ProcessRunner.readTimeout,
        priority: ProcessPriority = .normal,
        progress: @escaping @Sendable (ProcessOutputStream, Data) -> Void,
        control: ProcessControl? = nil
    ) async throws -> ProcessCommandResult {
        try await executeStreaming(
            repository: repository,
            arguments: arguments,
            input: input,
            environment: environment,
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            priority: priority,
            progress: progress,
            control: control
        )
    }
}

nonisolated enum ProcessRunnerError: Error, Sendable, CustomStringConvertible {
    case launchFailed(String)
    case processQueueFull
    case nonZeroExit(ProcessCommandResult)
    case timedOut(ProcessCommandResult)
    case cancelled(ProcessCommandResult)
    case outputLimitExceeded(stream: ProcessOutputStream, limit: Int, result: ProcessCommandResult)

    var description: String {
        switch self {
        case .launchFailed(let message):
            "Could not launch process: \(message)"
        case .processQueueFull:
            "Process queue is full"
        case .nonZeroExit(let result):
            "Process exited with status \(result.exitCode): \(result.standardErrorText)"
        case .timedOut(let result):
            "Process timed out (status \(result.exitCode)): \(result.standardErrorText)"
        case .cancelled(let result):
            "Process was cancelled (status \(result.exitCode)): \(result.standardErrorText)"
        case .outputLimitExceeded(let stream, let limit, _):
            "Process \(stream.rawValue) exceeded \(limit) bytes"
        }
    }
}

actor ProcessRunner: ProcessRunning {
    nonisolated static let readTimeout: Duration = .seconds(30)
    nonisolated static let networkTimeout: Duration = .seconds(30)
    nonisolated static let mutationTimeout: Duration = .seconds(120)
    nonisolated static let defaultOutputLimit = 8 * 1_024 * 1_024

    private let limiter: ProcessLimiter
    private let executable: String

    init(executable: String, limiter: ProcessLimiter = .shared) {
        self.executable = executable
        self.limiter = limiter
    }

    func run(
        repository: URL? = nil,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:],
        acceptedExitCodes: Set<Int32> = [0],
        outputLimit: Int = ProcessRunner.defaultOutputLimit,
        timeout: Duration = ProcessRunner.readTimeout,
        priority: ProcessPriority = .normal
    ) async throws -> ProcessCommandResult {
        try await execute(
            repository: repository,
            arguments: arguments,
            input: input,
            environment: environment,
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            priority: priority
        )
    }

    func execute(
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        timeout: Duration,
        priority: ProcessPriority
    ) async throws -> ProcessCommandResult {
        try await execute(
            repository: repository,
            arguments: arguments,
            input: input,
            environment: environment,
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            priority: priority,
            outputHandler: nil,
            control: nil
        )
    }

    func executeStreaming(
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        timeout: Duration,
        priority: ProcessPriority,
        progress: @escaping @Sendable (ProcessOutputStream, Data) -> Void,
        control: ProcessControl?
    ) async throws -> ProcessCommandResult {
        try await execute(
            repository: repository,
            arguments: arguments,
            input: input,
            environment: environment,
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            priority: priority,
            outputHandler: progress,
            control: control
        )
    }

    private func execute(
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        timeout: Duration,
        priority: ProcessPriority,
        outputHandler: (@Sendable (ProcessOutputStream, Data) -> Void)?,
        control: ProcessControl?
    ) async throws -> ProcessCommandResult {
        try await limiter.acquire(priority: priority)
        do {
            try Task.checkCancellation()
        } catch {
            await limiter.release()
            throw error
        }
        let invocation = ProcessInvocation(
            executable: executable,
            repository: repository,
            arguments: arguments,
            input: input,
            environment: environment,
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            outputHandler: outputHandler,
            control: control
        )
        do {
            let result = try await invocation.start()
            await limiter.release()
            return result
        } catch {
            await limiter.release()
            throw error
        }
    }
}
actor GitProcessRunner: ProcessRunning {
    private let runner: ProcessRunner

    init(limiter: ProcessLimiter = .shared) {
        runner = ProcessRunner(executable: "/usr/bin/git", limiter: limiter)
    }

    func execute(
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        timeout: Duration,
        priority: ProcessPriority
    ) async throws -> ProcessCommandResult {
        try await runner.execute(
            repository: repository,
            arguments: arguments,
            input: input,
            environment: environment,
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            priority: priority
        )
    }

    func executeStreaming(
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        timeout: Duration,
        priority: ProcessPriority,
        progress: @escaping @Sendable (ProcessOutputStream, Data) -> Void,
        control: ProcessControl?
    ) async throws -> ProcessCommandResult {
        try await runner.executeStreaming(
            repository: repository,
            arguments: arguments,
            input: input,
            environment: environment,
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            priority: priority,
            progress: progress,
            control: control
        )
    }
}
