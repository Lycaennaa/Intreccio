import Foundation
@testable import Intreccio
typealias GitRunner = GitProcessRunner
typealias GitRunnerError = ProcessRunnerError
typealias GitProcessLimiter = ProcessLimiter

nonisolated struct RecordedGitInvocation: Sendable, Equatable {
    let arguments: [String]
    let acceptedExitCodes: Set<Int32>
    let outputLimit: Int
    let timeout: Duration
    let priority: ProcessPriority
}

nonisolated enum RecordingGitResponse: Sendable {
    case result(ProcessCommandResult)
    case failure(ProcessRunnerError)
}

actor RecordingGitRunner {
    private var responses: [RecordingGitResponse]
    private(set) var invocations: [RecordedGitInvocation] = []

    init(responses: [RecordingGitResponse]) {
        self.responses = responses
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
        invocations.append(
            RecordedGitInvocation(
                arguments: arguments,
                acceptedExitCodes: acceptedExitCodes,
                outputLimit: outputLimit,
                timeout: timeout,
                priority: priority
            )
        )
        guard !responses.isEmpty else {
            throw ProcessRunnerError.launchFailed("Unexpected test Git invocation")
        }
        switch responses.removeFirst() {
        case .result(let result):
            guard acceptedExitCodes.contains(result.exitCode) else {
                throw ProcessRunnerError.nonZeroExit(result)
            }
            return result
        case .failure(let error):
            throw error
        }
    }
    func executeWithoutTimeout(_ request: ProcessExecutionRequest) async throws -> ProcessCommandResult {
        try await execute(
            repository: request.repository,
            arguments: request.arguments,
            input: request.input,
            environment: request.environment,
            acceptedExitCodes: request.acceptedExitCodes,
            outputLimit: request.outputLimit,
            timeout: ProcessRunner.mutationTimeout,
            priority: request.priority
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
            priority: priority
        )
    }
}

extension RecordingGitRunner: ProcessRunning {}

nonisolated func recordedGitResult(
    output: String = "",
    error: String = "",
    exitCode: Int32 = 0
) -> ProcessCommandResult {
    ProcessCommandResult(
        exitCode: exitCode,
        standardOutput: Data(output.utf8),
        standardError: Data(error.utf8)
    )
}
nonisolated func historyBatchRecord(objectID: String, parentID: String? = nil, subject: String) -> Data {
    var headers = ["tree 0123456789012345678901234567890123456789"]
    if let parentID { headers.append("parent \(parentID)") }
    headers.append(contentsOf: [
        "author Test <test@example.com> 1700000000 +0000",
        "committer Test <test@example.com> 1700000000 +0000",
        "",
        subject
    ])
    let object = Data(headers.joined(separator: "\n").utf8)
    var record = Data("\(objectID) commit \(object.count)\n".utf8)
    record.append(object)
    record.append(0x0A)
    return record
}

actor FailAfterApplyGitRunner: ProcessRunning {
    private let base: GitRunner
    private var didInjectFailure = false
    private let concurrentEditPath: String?

    init(base: GitRunner, concurrentEditPath: String? = nil) {
        self.base = base
        self.concurrentEditPath = concurrentEditPath
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
        try await base.execute(
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

    func executeWithoutTimeout(_ request: ProcessExecutionRequest) async throws -> ProcessCommandResult {
        let result = try await base.executeWithoutTimeout(request)
        guard !didInjectFailure, request.arguments == ["apply", "--index", "--binary"] else {
            return result
        }
        didInjectFailure = true
        if let concurrentEditPath, let repository = request.repository {
            try "Concurrent edit\n".write(
                to: repository.appendingPathComponent(concurrentEditPath),
                atomically: true,
                encoding: .utf8
            )
        }
        throw ProcessRunnerError.nonZeroExit(
            ProcessCommandResult(
                exitCode: 1,
                standardOutput: result.standardOutput,
                standardError: Data("Injected apply failure after writes".utf8)
            )
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
        try await base.executeStreaming(
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
