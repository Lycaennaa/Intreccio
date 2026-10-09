import Foundation
@testable import Intreccio
import XCTest

private struct ActiveNoTimeoutFixture {
    let request: ProcessExecutionRequest
    let started: URL
    let release: URL
    let finished: URL
}

private func makeActiveNoTimeoutFixture(
    in directory: URL,
    name: String,
    cancellationBehavior: ProcessCancellationBehavior
) -> ActiveNoTimeoutFixture {
    let started = directory.appendingPathComponent("\(name)-started")
    let release = directory.appendingPathComponent("\(name)-release")
    let finished = directory.appendingPathComponent("\(name)-finished")
    let commandScript = [
        "touch \"\(started.path)\"",
        "while [ ! -e \"\(release.path)\" ]; do",
        "sleep 0.01",
        "done",
        "touch \"\(finished.path)\""
    ].joined(separator: "; ")
    let request = ProcessExecutionRequest(
        repository: nil,
        arguments: ["-c", "alias.wait=!\(commandScript)", "wait"],
        input: nil,
        environment: [:],
        acceptedExitCodes: [0],
        outputLimit: ProcessRunner.defaultOutputLimit,
        priority: .normal,
        cancellationBehavior: cancellationBehavior
    )
    return ActiveNoTimeoutFixture(request: request, started: started, release: release, finished: finished)
}

extension GitRunnerTests {
    func testActiveNoTimeoutCommandFinishesAfterCallerCancellation() async throws {
        let fixture = makeActiveNoTimeoutFixture(
            in: try makeTestDirectory(),
            name: "finish-after-launch",
            cancellationBehavior: .finishAfterLaunch
        )
        defer { try? Data().write(to: fixture.release) }
        let runner = GitRunner(limiter: GitProcessLimiter(maximumConcurrent: 1))
        let command = Task { try await runner.executeWithoutTimeout(fixture.request) }

        try await waitUntil(description: "no-timeout command starts") {
            FileManager.default.fileExists(atPath: fixture.started.path)
        }
        command.cancel()
        try Data().write(to: fixture.release)
        let result = try await command.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.finished.path))
    }

    func testActiveNoTimeoutCommandHonorsCancellationWhenCancellable() async throws {
        let fixture = makeActiveNoTimeoutFixture(
            in: try makeTestDirectory(),
            name: "cancellable",
            cancellationBehavior: .cancellable
        )
        defer { try? Data().write(to: fixture.release) }
        let runner = GitRunner(limiter: GitProcessLimiter(maximumConcurrent: 1))
        let command = Task { try await runner.executeWithoutTimeout(fixture.request) }

        try await waitUntil(description: "cancellable no-timeout command starts") {
            FileManager.default.fileExists(atPath: fixture.started.path)
        }
        command.cancel()
        try Data().write(to: fixture.release)
        do {
            _ = try await command.value
            XCTFail("Expected cancellation")
        } catch GitRunnerError.cancelled(_) {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finished.path))
    }
}
