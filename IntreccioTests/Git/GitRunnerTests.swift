import Foundation
import XCTest
@testable import Intreccio

final class GitRunnerTests: XCTestCase {
    func testCapturesOutputAndExactNonzeroFailure() async throws {
        let runner = GitRunner()
        let version = try await runner.run(arguments: ["--version"])
        XCTAssertTrue(String(decoding: version.standardOutput, as: UTF8.self).hasPrefix("git version"))

        do {
            _ = try await runner.run(repository: URL(fileURLWithPath: "/does/not/exist"), arguments: ["status"])
            XCTFail("Expected nonzero Git exit")
        } catch let GitRunnerError.nonZeroExit(result) {
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertFalse(result.standardError.isEmpty)
        }
    }
    func testStreamingRunReportsStandardErrorChunks() async throws {
        let runner = GitRunner()
        let streamAndContinuation = AsyncStream<Data>.makeStream()
        let result = try await runner.runStreaming(
            arguments: ["-c", "alias.progress=!printf 'Receiving objects: 42%%\\r' >&2", "progress"],
            progress: { stream, data in
                guard stream == .standardError else { return }
                streamAndContinuation.continuation.yield(data)
            }
        )
        streamAndContinuation.continuation.finish()

        var output = Data()
        for await chunk in streamAndContinuation.stream {
            output.append(chunk)
        }
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("Receiving objects: 42%"))
        XCTAssertTrue(String(decoding: result.standardError, as: UTF8.self).contains("Receiving objects: 42%"))
    }
    func testStreamingRunCanPauseAndResumeProcessGroup() async throws {
        let runner = GitProcessRunner()
        let control = ProcessControl()
        let readyStream = AsyncStream<Void>.makeStream()
        let command = Task {
            try await runner.runStreaming(
                arguments: ["-c", "alias.wait=!printf ready >&2; while true; do sleep 1; done", "wait"],
                timeout: .seconds(10),
                progress: { stream, data in
                    guard stream == .standardError, String(decoding: data, as: UTF8.self).contains("ready") else { return }
                    readyStream.continuation.yield(())
                },
                control: control
            )
        }

        for await _ in readyStream.stream {
            break
        }
        readyStream.continuation.finish()
        XCTAssertTrue(control.pause())
        XCTAssertTrue(control.isPaused)
        XCTAssertTrue(control.resume())
        command.cancel()

        do {
            _ = try await command.value
            XCTFail("Expected cancellation")
        } catch is GitRunnerError {
        }
    }

    func testTerminatesWhenOutputExceedsCap() async throws {
        let runner = GitRunner()
        do {
            _ = try await runner.run(arguments: ["--version"], outputLimit: 4)
            XCTFail("Expected output limit error")
        } catch let GitRunnerError.outputLimitExceeded(stream, limit, result) {
            XCTAssertEqual(limit, 4)
            let captured = stream == .standardOutput ? result.standardOutput : result.standardError
            XCTAssertEqual(captured.count, 4, result.standardErrorText)
        }
    }

    func testTimeoutTerminatesAndReapsProcess() async throws {
        let runner = GitRunner()
        do {
            _ = try await runner.run(
                arguments: ["-c", "alias.wait=!sleep 10", "wait"],
                timeout: .milliseconds(50)
            )
            XCTFail("Expected timeout")
        } catch let GitRunnerError.timedOut(result) {
            XCTAssertNotEqual(result.exitCode, -1)
        }
    }

    func testCancellationTerminatesAndReapsProcess() async throws {
        let runner = GitRunner(limiter: GitProcessLimiter(maximumConcurrent: 1))
        let command = Task {
            try await runner.run(arguments: ["-c", "alias.wait=!sleep 10", "wait"])
        }
        try await Task.sleep(for: .milliseconds(50))
        command.cancel()

        do {
            _ = try await command.value
            XCTFail("Expected cancellation")
        } catch let GitRunnerError.cancelled(result) {
            XCTAssertNotEqual(result.exitCode, -1)
        }
    }

    func testConcurrentCancellationDuringLaunchDoesNotCrashOrBlockLaterCommands() async throws {
        let runner = GitRunner(limiter: GitProcessLimiter(maximumConcurrent: 2))
        let commands = (0..<64).map { _ in
            Task { try await runner.run(arguments: ["--version"]) }
        }
        await Task.yield()
        commands.forEach { $0.cancel() }
        for command in commands {
            _ = try? await command.value
        }

        let result = try await runner.run(arguments: ["--version"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCancellationDuringOutputDoesNotCrashOrBlockLaterCommands() async throws {
        let runner = GitRunner(limiter: GitProcessLimiter(maximumConcurrent: 1))
        let command = Task {
            try await runner.run(arguments: [
                "-c", "alias.stream=!while true; do printf x; sleep 0.01; done", "stream",
            ])
        }
        try await Task.sleep(for: .milliseconds(50))
        command.cancel()

        do {
            _ = try await command.value
            XCTFail("Expected cancellation")
        } catch is GitRunnerError {
        }

        let result = try await runner.run(arguments: ["--version"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCancellationDuringInputDoesNotCrashOrBlockLaterCommands() async throws {
        let runner = GitRunner(limiter: GitProcessLimiter(maximumConcurrent: 1))
        let command = Task {
            try await runner.run(
                arguments: ["-c", "alias.wait=!sleep 10", "wait"],
                input: Data(repeating: 0x61, count: 1_024 * 1_024)
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        command.cancel()

        do {
            _ = try await command.value
            XCTFail("Expected cancellation")
        } catch is GitRunnerError {
        }

        let result = try await runner.run(arguments: ["--version"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testOutputLimitWaitsForProcessGroupCleanup() async throws {
        let directory = try makeTestDirectory()
        let beforeKill = directory.appendingPathComponent("before-kill").path
        let afterKill = directory.appendingPathComponent("after-kill").path
        let alias = "!f() { trap '' TERM; ( trap '' TERM; yes x | head -c 1000; sleep 0.2; printf before > \(beforeKill); sleep 2; printf after > \(afterKill) ) & wait; }; f"
        let runner = GitRunner()
        let start = ContinuousClock.now

        do {
            _ = try await runner.run(
                arguments: ["-c", "alias.loud=\(alias)", "loud"],
                outputLimit: 64
            )
            XCTFail("Expected output limit error")
        } catch is GitRunnerError {
        }
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(900))
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeKill))
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: afterKill))
    }

    func testStandardInputCompletionAndBothOutputEOFs() async throws {
        let runner = GitRunner()
        let input = Data("payload".utf8)
        let result = try await runner.run(
            arguments: [
                "-c", "alias.consume=!cat; printf diagnostic >&2", "consume",
            ],
            input: input
        )

        XCTAssertEqual(result.standardOutput, input)
        XCTAssertEqual(String(decoding: result.standardError, as: UTF8.self), "diagnostic")
    }

    func testLaunchFailureCleansUpAndReleasesLimiter() async throws {
        let runner = GitRunner(limiter: GitProcessLimiter(maximumConcurrent: 1))
        do {
            _ = try await runner.run(arguments: [String(repeating: "x", count: 2_000_000)])
            XCTFail("Expected launch failure")
        } catch GitRunnerError.launchFailed {
        }

        let result = try await runner.run(arguments: ["--version"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testTimeoutCancellationRaceResumesOnceAndReleasesLimiter() async throws {
        let runner = GitRunner(limiter: GitProcessLimiter(maximumConcurrent: 4))
        let commands = (0..<4).map { _ in
            Task {
                try await runner.run(
                    arguments: ["-c", "alias.wait=!sleep 10", "wait"],
                    timeout: .milliseconds(40)
                )
            }
        }
        try await Task.sleep(for: .milliseconds(40))
        commands.forEach { $0.cancel() }

        for command in commands {
            do {
                _ = try await command.value
                XCTFail("Expected timeout or cancellation")
            } catch GitRunnerError.timedOut(_), GitRunnerError.cancelled(_) {
            }
        }
        let result = try await runner.run(arguments: ["--version"])
        XCTAssertEqual(result.exitCode, 0)
    }
    func testCancelledQueuedRequestDoesNotStartGitAfterReleaseRace() async throws {
        let directory = try makeTestDirectory()
        let marker = directory.appendingPathComponent("cancelled-process-started")
        let limiter = GitProcessLimiter(maximumConcurrent: 1)
        try await limiter.acquire(priority: .normal)
        let runner = GitRunner(limiter: limiter)
        let command = Task {
            try await runner.run(
                arguments: ["-c", "alias.marker=!touch \(marker.path)", "marker"]
            )
        }

        try await waitUntil { await limiter.waitingCountForTesting == 1 }
        command.cancel()
        await limiter.release()

        do {
            _ = try await command.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let laterResult = try await runner.run(arguments: ["--version"])
        XCTAssertEqual(laterResult.exitCode, 0)
    }
 }
