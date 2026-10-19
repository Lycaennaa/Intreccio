import Foundation
@testable import Intreccio
import XCTest

@discardableResult
func runGit(at url: URL, arguments: [String]) throws -> ProcessCommandResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", url.path] + arguments
    process.standardOutput = stdout
    process.standardError = stderr
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    let result = ProcessCommandResult(
        exitCode: process.terminationStatus,
        standardOutput: stdout.fileHandleForReading.readDataToEndOfFile(),
        standardError: stderr.fileHandleForReading.readDataToEndOfFile()
    )
    guard result.exitCode == 0 else { throw ProcessRunnerError.nonZeroExit(result) }
    return result
}

final class GitFixture: @unchecked Sendable {
    let url: URL

    init(testCase: XCTestCase) throws {
        url = try testCase.makeTestDirectory()
        try git("init", "-b", "main")
        try git("config", "user.name", "Fixture User")
        try git("config", "user.email", "fixture@example.com")
        try git("config", "commit.gpgsign", "false")
    }

    func write(_ text: String, to path: String) throws {
        try write(Data(text.utf8), to: path)
    }

    func write(_ data: Data, to path: String) throws {
        let destination = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> ProcessCommandResult {
        try runGit(at: url, arguments: arguments)
    }
}

extension ProcessCommandResult {
    var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
}

@MainActor
func XCTAssertThrowsErrorAsync<ExpectedError: Error>(
    _ expression: @Sendable () async throws -> Void,
    assertError: (ExpectedError) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch let error as ExpectedError {
        assertError(error)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
// ProcessRunning witnesses must preserve the full execution contract.
// swiftlint:disable function_parameter_count
actor GitConfigScopeRunner: ProcessRunning {
    private let base = GitRunner()
    private let globalConfig: URL

    init(globalConfig: URL) {
        self.globalConfig = globalConfig
    }

    private func scopedEnvironment(_ environment: [String: String]) -> [String: String] {
        var environment = environment
        environment["GIT_CONFIG_GLOBAL"] = globalConfig.path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        return environment
    }

    private func scopedRequest(_ request: ProcessExecutionRequest) -> ProcessExecutionRequest {
        ProcessExecutionRequest(
            repository: request.repository,
            arguments: request.arguments,
            input: request.input,
            environment: scopedEnvironment(request.environment),
            acceptedExitCodes: request.acceptedExitCodes,
            outputLimit: request.outputLimit,
            priority: request.priority,
            cancellationBehavior: request.cancellationBehavior,
            outputLimitBehavior: request.outputLimitBehavior
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
        try await base.execute(
            repository: repository,
            arguments: arguments,
            input: input,
            environment: scopedEnvironment(environment),
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            priority: priority
        )
    }

    func executeAfterAdmission(
        _ request: ProcessExecutionRequest,
        timeout: Duration,
        onAdmission: @escaping @Sendable () async throws -> Void
    ) async throws -> ProcessCommandResult {
        try await base.executeAfterAdmission(
            scopedRequest(request),
            timeout: timeout,
            onAdmission: onAdmission
        )
    }

    func executeWithoutTimeout(_ request: ProcessExecutionRequest) async throws -> ProcessCommandResult {
        try await base.executeWithoutTimeout(scopedRequest(request))
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
            environment: scopedEnvironment(environment),
            acceptedExitCodes: acceptedExitCodes,
            outputLimit: outputLimit,
            timeout: timeout,
            priority: priority,
            progress: progress,
            control: control
        )
    }
}
// swiftlint:enable function_parameter_count
