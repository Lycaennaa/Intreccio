import Foundation
@testable import Intreccio
import XCTest

final class GitServiceIntegrationTests: XCTestCase {
    func testStatusCollapsesUntrackedDirectoriesAndExpandsNestedFilesOnDemand() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("nested/ignored/\n", to: ".gitignore")
        try fixture.write("tracked\n", to: "tracked.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")

        let expectedPaths = (0..<256).map { index in
            "nested/level-\(index % 8)/file-\(index).txt"
        } + [
            "nested/level-0/:(glob)*.txt",
            "nested/level-0/file with spaces.txt"
        ]
        for path in expectedPaths {
            try fixture.write("untracked\n", to: path)
        }
        let ignoredPath = "nested/ignored/secret.txt"
        try fixture.write("ignored\n", to: ignoredPath)

        let service = GitService()
        let collapsed = try await service.status(
            repository: fixture.url,
            expandUntrackedDirectories: false
        )
        XCTAssertEqual(
            collapsed.changes.filter { $0.kind == .untracked }.map(\.path),
            ["nested/"]
        )

        let expanded = try await service.status(repository: fixture.url)
        let untrackedPaths = Set(
            expanded.changes.filter { $0.kind == .untracked }.map(\.path)
        )
        XCTAssertEqual(untrackedPaths, Set(expectedPaths))
        XCTAssertFalse(untrackedPaths.contains(ignoredPath))
        XCTAssertFalse(untrackedPaths.contains("nested/"))
    }

    func testIgnoredPathsUsesGitIgnoreRulesWithoutFilteringTrackedPaths() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("ignored/\n*.cache\n", to: ".gitignore")
        try fixture.write("tracked\n", to: "tracked.txt")
        try fixture.git("add", "--", ".gitignore", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.write("ignored/\n*.cache\ntracked.txt\n", to: ".gitignore")
        try fixture.write("ignored\n", to: "ignored/file.txt")
        try fixture.write("cached\n", to: "result.cache")

        let ignored = try await GitService().ignoredPaths(
            repository: fixture.url,
            relativePaths: ["ignored/file.txt", "result.cache", "tracked.txt", "visible.txt", ":(glob)*.txt"]
        )

        XCTAssertEqual(ignored, Set(["ignored/file.txt", "result.cache"]))
    }

    func testExpandedUntrackedStatusPreservesFileLevelStaging() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.write("one\n", to: "nested/one.txt")
        try fixture.write("two\n", to: "nested/two.txt")

        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let selected = try XCTUnwrap(status.changes.first { $0.path == "nested/one.txt" })
        try await service.stage(repository: fixture.url, paths: [selected.path])

        let updated = try await service.status(repository: fixture.url)
        let staged = try XCTUnwrap(updated.changes.first { $0.path == selected.path })
        XCTAssertTrue(staged.hasStagedChange)
        XCTAssertTrue(updated.changes.contains {
            $0.path == "nested/two.txt" && $0.kind == .untracked
        })
    }

    func testStatusCancellationWhileWaitingForProcessDoesNotLeakLimiter() async throws {
        let fixture = try GitFixture(testCase: self)
        let limiter = GitProcessLimiter(maximumConcurrent: 1)
        try await limiter.acquire(priority: .normal)
        let runner = GitRunner(limiter: limiter)
        let service = GitService(runner: runner)
        let task = Task {
            try await service.localStatus(
                repository: fixture.url,
                priority: .normal,
                expandUntrackedDirectories: true
            )
        }
        try await Task.sleep(for: .milliseconds(25))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected status cancellation")
        } catch is CancellationError {
        } catch GitRunnerError.cancelled(_) {
        }

        await limiter.release()
        let result = try await runner.run(arguments: ["--version"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStatusPropagatesGitFailureWithoutReturningCollapsedFallback() async throws {
        let directory = try makeTestDirectory()

        do {
            _ = try await GitService().status(repository: directory)
            XCTFail("Expected status failure")
        } catch let GitRunnerError.nonZeroExit(result) {
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertFalse(result.standardError.isEmpty)
        } catch {
            XCTFail("Unexpected status error: \(error)")
        }
    }
    func testUnsupportedPathspecFallbackUsesOneLargeArgumentBatch() async throws {
        let directories = (0..<5_000).map { "d-\($0)/" }
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: porcelainUntrackedStatus(directories))),
            .failure(.nonZeroExit(recordedGitResult(
                error: "unknown option pathspec-from-file",
                exitCode: 129
            ))),
            .result(recordedGitResult(output: porcelainUntrackedStatus(directories)))
        ])

        let status = try await GitService(runner: runner).localStatus(
            repository: URL(fileURLWithPath: "/repository"),
            priority: .normal
        )

        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 3)
        XCTAssertEqual(status.changes.map(\.path), directories)
        XCTAssertEqual(
            Array(invocations[2].arguments.prefix(5)),
            ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--"]
        )
        let pathspecs = Array(invocations[2].arguments.dropFirst(5))
        XCTAssertEqual(pathspecs, directories.map { ":(literal)\($0)" })
        XCTAssertGreaterThan(
            pathspecs.reduce(0) { $0 + $1.utf8.count + 1 },
            64 * 1_024
        )
    }
    func testUnsupportedPathspecFallbackPreservesSpecialPathsAndOrder() async throws {
        let specialDirectory = "nested/$(not-a-command)/"
        let initialPaths = ["outside.txt", "nested/", specialDirectory]
        let expandedPaths = [
            "nested/-leading file.txt",
            "nested/file with spaces.txt",
            "nested/:(glob)*.txt",
            "\(specialDirectory)file with spaces.txt",
            "\(specialDirectory)$(still-not-a-command);'quoted'\nline.txt"
        ]
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: porcelainUntrackedStatus(initialPaths))),
            .failure(.nonZeroExit(recordedGitResult(
                error: "unknown option pathspec-from-file",
                exitCode: 129
            ))),
            .result(recordedGitResult(output: porcelainUntrackedStatus(expandedPaths)))
        ])

        let status = try await GitService(runner: runner).localStatus(
            repository: URL(fileURLWithPath: "/repository"),
            priority: .normal
        )

        XCTAssertEqual(status.changes.map(\.path), ["outside.txt"] + expandedPaths)
        let invocations = await runner.invocations
        XCTAssertEqual(
            Array(invocations[2].arguments.dropFirst(5)),
            [":(literal)nested/", ":(literal)\(specialDirectory)"]
        )
        XCTAssertFalse(invocations[2].arguments.contains { $0.contains("still-not-a-command") })
    }

    func testUnsupportedPathspecFallbackChecksCancellationBeforeLaunchingBatch() async {
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: porcelainUntrackedStatus(["nested/"]))),
            .failure(.nonZeroExit(recordedGitResult(
                error: "unknown option pathspec-from-file",
                exitCode: 129
            )))
        ])
        let task = Task {
            try await GitService(runner: runner).localStatus(
                repository: URL(fileURLWithPath: "/repository"),
                priority: .normal
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected status cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected status error: \(error)")
        }

        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 2)
    }

    func testUnsupportedPathspecFallbackPropagatesFailure() async {
        let failureResult = recordedGitResult(error: "fatal: status failed", exitCode: 128)
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: porcelainUntrackedStatus(["nested/"]))),
            .failure(.nonZeroExit(recordedGitResult(
                error: "unknown option pathspec-from-file",
                exitCode: 129
            ))),
            .failure(.nonZeroExit(failureResult))
        ])

        do {
            _ = try await GitService(runner: runner).localStatus(
                repository: URL(fileURLWithPath: "/repository"),
                priority: .normal
            )
            XCTFail("Expected fallback failure")
        } catch let GitRunnerError.nonZeroExit(result) {
            XCTAssertEqual(result, failureResult)
        } catch {
            XCTFail("Unexpected fallback error: \(error)")
        }

        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 3)
    }
}

private func porcelainUntrackedStatus(_ paths: [String]) -> String {
    paths.map { "? \($0)\0" }.joined()
}
