import Foundation
@testable import Intreccio
import XCTest

final class GitServicePushTests: XCTestCase {
    func testPushSendsOnlyConfiguredBranchAndLeavesUncommittedChanges() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: ["init", "--bare", "-b", "main", remote.path])
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("push", "--set-upstream", "origin", "main")
        try fixture.write("local\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "local")
        try fixture.write("uncommitted\n", to: "uncommitted.txt")
        let localHead = try fixture.git("rev-parse", "HEAD")
            .standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let service = GitService()
        let target = try await service.preparePushTarget(repository: fixture.url)
        try await service.pushToUpstream(target: target)

        let remoteHead = try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"]).standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteHead, localHead)
        let uncommittedPath = fixture.url.appendingPathComponent("uncommitted.txt").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: uncommittedPath))
    }

    func testPushRefusesDivergedUpstreamWithoutForcePushing() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: ["init", "--bare", "-b", "main", remote.path])
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("push", "--set-upstream", "origin", "main")
        try fixture.write("local\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "local")

        let peer = try makeTestDirectory()
        try runGit(at: peer.deletingLastPathComponent(), arguments: ["clone", remote.path, peer.path])
        try runGit(at: peer, arguments: ["config", "user.name", "Peer"])
        try runGit(at: peer, arguments: ["config", "user.email", "peer@example.com"])
        try "remote\n".write(to: peer.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try runGit(at: peer, arguments: ["add", "--", "remote.txt"])
        try runGit(at: peer, arguments: ["commit", "-m", "remote"])
        try runGit(at: peer, arguments: ["push", "origin", "main"])
        let remoteHead = try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"]).standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let service = GitService()
            let target = try await service.preparePushTarget(repository: fixture.url)
            try await service.pushToUpstream(target: target)
            XCTFail("Expected a diverged branch to be rejected")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .branchBehindUpstream)
        }

        XCTAssertEqual(
            try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"]).standardOutputText
                .trimmingCharacters(in: .whitespacesAndNewlines),
            remoteHead
        )
    }

    func testPushRefusesHeadChangedAfterConfirmation() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: ["init", "--bare", "-b", "main", remote.path])
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("push", "--set-upstream", "origin", "main")
        try fixture.write("first\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "first")
        let service = GitService()
        let target = try await service.preparePushTarget(repository: fixture.url)
        let remoteHead = try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"]).standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("second\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "second")

        do {
            try await service.pushToUpstream(target: target)
            XCTFail("Expected a changed HEAD to invalidate confirmation")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .pushTargetChanged)
        }

        XCTAssertEqual(
            try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"]).standardOutputText
                .trimmingCharacters(in: .whitespacesAndNewlines),
            remoteHead
        )
    }
    func testPushIndicatorTracksCurrentGitHubPermission() async throws {
        let scenario = try makeGitHubPushScenario()
        let githubRunner = RecordingGitRunner(responses: [
            .result(recordedGitResult()),
            .result(recordedGitResult(output: "WRITE\n")),
            .result(recordedGitResult()),
            .result(recordedGitResult(output: "READ\n"))
        ])
        let service = GitService(
            runner: GitRunner(),
            githubCLI: GitHubCLI(executableURL: nil, runner: githubRunner)
        )

        let allowedStatus = try await service.status(repository: scenario.fixture.url)
        XCTAssertEqual(allowedStatus.pushAccess, .allowed)
        XCTAssertEqual(RepositoryRefreshState(status: allowedStatus).sidebarBadge, "L0 || P1")

        let deniedStatus = try await service.status(repository: scenario.fixture.url)
        XCTAssertEqual(deniedStatus.pushAccess, .denied)
        XCTAssertEqual(RepositoryRefreshState(status: deniedStatus).sidebarBadge, "L0")
        let invocations = await githubRunner.invocations
        XCTAssertEqual(invocations.count, 4)
    }

    func testMixedDestinationsRequireGitHubWriteAccess() async throws {
        let scenario = try makeGitHubPushScenario()
        try scenario.fixture.git("remote", "set-url", "--add", "--push", "origin", scenario.remote.path)
        let githubRunner = RecordingGitRunner(responses: [
            .result(recordedGitResult()),
            .result(recordedGitResult(output: "READ\n")),
            .result(recordedGitResult()),
            .result(recordedGitResult(output: "READ\n"))
        ])
        let service = GitService(
            runner: GitRunner(),
            githubCLI: GitHubCLI(executableURL: nil, runner: githubRunner)
        )

        let status = try await service.status(repository: scenario.fixture.url)
        XCTAssertEqual(status.pushAccess, .denied)
        XCTAssertEqual(RepositoryRefreshState(status: status).sidebarBadge, "L0")
        XCTAssertFalse(
            ChangesMutationPolicy.pushControlAvailability(status: status, mutationRunning: false).isAvailable
        )

        do {
            _ = try await service.preparePushTarget(repository: scenario.fixture.url)
            XCTFail("Expected mixed destinations to require GitHub write access")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .remoteWriteAccessDenied("octo/repo"))
        }
        let invocations = await githubRunner.invocations
        XCTAssertEqual(invocations.count, 4)
    }

    func testPushRechecksGitHubWriteAccessBeforePushing() async throws {
        let scenario = try makeGitHubPushScenario()
        let gitRunner = GitPushInterceptor()
        let githubRunner = RecordingGitRunner(responses: [
            .result(recordedGitResult()),
            .result(recordedGitResult(output: "READ\n"))
        ])
        let service = GitService(
            runner: gitRunner,
            githubCLI: GitHubCLI(executableURL: nil, runner: githubRunner)
        )

        do {
            try await service.pushToUpstream(target: scenario.target)
            XCTFail("Expected write access to be required")
        } catch {
            XCTAssertEqual(
                error as? GitServiceError,
                .pushDestinationsFailed(
                    succeeded: [],
                    failures: ["octo/repo: GitHub write access denied"]
                )
            )
        }

        let pushAttempts = await gitRunner.pushAttempts
        XCTAssertEqual(pushAttempts, 0)
        let remoteHead = try runGit(at: scenario.remote, arguments: ["rev-parse", "refs/heads/main"])
            .standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(remoteHead, scenario.target.headObjectID)
    }
    func testQueuedPushRechecksGitHubAccessAfterAdmission() async throws {
        let scenario = try makeGitHubPushScenario()
        let gate = GitPushAdmissionGate()
        let gitRunner = GitPushInterceptor(admissionGate: gate)
        let githubRunner = RecordingGitRunner(responses: [
            .result(recordedGitResult()),
            .result(recordedGitResult(output: "WRITE\n")),
            .result(recordedGitResult()),
            .result(recordedGitResult(output: "READ\n"))
        ])
        let service = GitService(
            runner: gitRunner,
            githubCLI: GitHubCLI(executableURL: nil, runner: githubRunner)
        )
        let target = try await service.preparePushTarget(repository: scenario.fixture.url)
        let pushTask = Task { try await service.pushToUpstream(target: target) }

        await gate.waitUntilQueued()
        let callsBeforeAdmission = await githubRunner.invocations
        XCTAssertEqual(callsBeforeAdmission.count, 2)
        await gate.release()

        do {
            try await pushTask.value
            XCTFail("Expected the queued push to use the current GitHub permission")
        } catch {
            XCTAssertEqual(
                error as? GitServiceError,
                .pushDestinationsFailed(
                    succeeded: [],
                    failures: ["octo/repo: GitHub write access denied"]
                )
            )
        }
        let pushAttempts = await gitRunner.pushAttempts
        XCTAssertEqual(pushAttempts, 0)
        let callsAfterAdmission = await githubRunner.invocations
        XCTAssertEqual(callsAfterAdmission.count, 4)
    }

    func testPushRechecksPermissionBeforeEachGitHubDestination() async throws {
        let scenario = try makeGitHubPushScenario()
        let secondURL = "https://github.com/octo/repo2.git"
        try scenario.fixture.git("remote", "set-url", "--add", "--push", "origin", secondURL)
        let target = GitPushTarget(
            repository: scenario.target.repository,
            branch: scenario.target.branch,
            upstream: scenario.target.upstream,
            remote: scenario.target.remote,
            remoteRef: scenario.target.remoteRef,
            headObjectID: scenario.target.headObjectID,
            ahead: scenario.target.ahead,
            pushURLs: [scenario.target.pushURLs[0], secondURL],
            initialPushExpectedRemoteHeads: scenario.target.initialPushExpectedRemoteHeads
        )
        let gitRunner = GitPushInterceptor()
        let githubRunner = RecordingGitRunner(responses: [
            .result(recordedGitResult()),
            .result(recordedGitResult(output: "WRITE\n")),
            .result(recordedGitResult()),
            .result(recordedGitResult(output: "READ\n"))
        ])
        let service = GitService(
            runner: gitRunner,
            githubCLI: GitHubCLI(executableURL: nil, runner: githubRunner)
        )

        do {
            try await service.pushToUpstream(target: target)
            XCTFail("Expected the second destination to be denied")
        } catch {
            XCTAssertEqual(
                error as? GitServiceError,
                .pushDestinationsFailed(
                    succeeded: [],
                    failures: [
                        "octo/repo: Git push failed",
                        "octo/repo2: GitHub write access denied"
                    ]
                )
            )
        }

        let pushAttempts = await gitRunner.pushAttempts
        XCTAssertEqual(pushAttempts, 1)
        let invocations = await githubRunner.invocations
        XCTAssertEqual(invocations.count, 4)
    }

    func testPushAttemptsLaterURLsAfterEarlierFailure() async throws {
        let scenario = try makeMultiplePushScenario()
        let mirror = try XCTUnwrap(scenario.mirror)
        let gitRunner = GitPushInterceptor()
        let service = GitService(
            runner: gitRunner,
            githubCLI: GitHubCLI(executableURL: nil, runner: RecordingGitRunner(responses: []))
        )

        do {
            try await service.pushToUpstream(target: scenario.target)
            XCTFail("Expected the first push destination to fail")
        } catch {
            XCTAssertEqual(
                error as? GitServiceError,
                .pushDestinationsFailed(
                    succeeded: ["remote destination 2"],
                    failures: ["remote destination 1: Git push failed"]
                )
            )
        }

        let pushAttempts = await gitRunner.pushAttempts
        XCTAssertEqual(pushAttempts, 2)
        let mirrorHead = try runGit(at: mirror, arguments: ["rev-parse", "refs/heads/main"])
            .standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(mirrorHead, scenario.target.headObjectID)
    }

    private func makeGitHubPushScenario() throws -> GitHubPushScenario {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: [
            "init", "--bare", "-b", "main", remote.path
        ])
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("push", "--set-upstream", "origin", "main")
        try fixture.git("remote", "set-url", "--push", "origin", "https://github.com/octo/repo.git")
        try fixture.write("ahead\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "ahead")
        let head = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GitHubPushScenario(
            fixture: fixture,
            remote: remote,
            mirror: nil,
            target: GitPushTarget(
                repository: fixture.url,
                branch: "main",
                upstream: "origin/main",
                remote: "origin",
                remoteRef: "refs/heads/main",
                headObjectID: head,
                ahead: 1,
                pushURLs: ["https://github.com/octo/repo.git"],
                initialPushExpectedRemoteHeads: nil
            )
        )
    }
    private func makeMultiplePushScenario() throws -> GitHubPushScenario {
        let fixture = try GitFixture(testCase: self)
        let remotes = try makeTestDirectory()
        let upstream = remotes.appendingPathComponent("upstream.git", isDirectory: true)
        let mirror = remotes.appendingPathComponent("mirror.git", isDirectory: true)
        for remote in [upstream, mirror] {
            try runGit(at: remotes, arguments: ["init", "--bare", "-b", "main", remote.path])
        }
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("remote", "add", "origin", upstream.path)
        try fixture.git("push", "--set-upstream", "origin", "main")
        try fixture.git("push", mirror.path, "main")
        try fixture.git("remote", "set-url", "--push", "origin", upstream.path)
        try fixture.git("remote", "set-url", "--add", "--push", "origin", mirror.path)
        try fixture.write("ahead\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "ahead")
        let head = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GitHubPushScenario(
            fixture: fixture,
            remote: upstream,
            mirror: mirror,
            target: GitPushTarget(
                repository: fixture.url,
                branch: "main",
                upstream: "origin/main",
                remote: "origin",
                remoteRef: "refs/heads/main",
                headObjectID: head,
                ahead: 1,
                pushURLs: [upstream.path, mirror.path],
                initialPushExpectedRemoteHeads: nil
            )
        )
    }

 }

private struct GitHubPushScenario {
    let fixture: GitFixture
    let remote: URL
    let mirror: URL?
    let target: GitPushTarget
}

// ProcessRunning witnesses must preserve the full execution contract.
// swiftlint:disable function_parameter_count
private actor GitPushInterceptor: ProcessRunning {
    private let base = GitRunner()
    private(set) var pushAttempts = 0
    private let admissionGate: GitPushAdmissionGate?
    private var beforePush: (@Sendable () async throws -> Void)?

    init(admissionGate: GitPushAdmissionGate? = nil) {
        self.admissionGate = admissionGate
    }

    func installBeforeFirstPushHook(_ hook: @escaping @Sendable () async throws -> Void) {
        beforePush = hook
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
        if arguments.first == "push" {
            pushAttempts += 1
            if pushAttempts == 1, let beforePush {
                try await beforePush()
            } else if pushAttempts == 1 {
                throw ProcessRunnerError.launchFailed("Injected first push failure")
            }
        }
        return try await base.execute(
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

    func executeAfterAdmission(
        _ request: ProcessExecutionRequest,
        timeout: Duration,
        onAdmission: @escaping @Sendable () async throws -> Void
    ) async throws -> ProcessCommandResult {
        if let admissionGate { await admissionGate.waitUntilReleased() }
        try await onAdmission()
        return try await execute(
            repository: request.repository,
            arguments: request.arguments,
            input: request.input,
            environment: request.environment,
            acceptedExitCodes: request.acceptedExitCodes,
            outputLimit: request.outputLimit,
            timeout: timeout,
            priority: request.priority
        )
    }

    func executeWithoutTimeout(_ request: ProcessExecutionRequest) async throws -> ProcessCommandResult {
        if request.arguments.first == "push" {
            pushAttempts += 1
            if pushAttempts == 1 {
                throw ProcessRunnerError.launchFailed("Injected first push failure")
            }
        }
        return try await base.executeWithoutTimeout(request)
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

// swiftlint:enable function_parameter_count

private actor GitPushAdmissionGate {
    private var queued = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var queuedContinuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            queued = true
            queuedContinuation?.resume()
            queuedContinuation = nil
        }
    }

    func waitUntilQueued() async {
        if queued { return }
        await withCheckedContinuation { queuedContinuation = $0 }
    }

    func release() {
        queued = false
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

extension GitServiceInitialPushTests {
    func testInitialPushLeaseRejectsConcurrentBranchCreationAfterPreflight() async throws {
        let fixture = try GitFixture(testCase: self)
        let remote = try makeTestDirectory().appendingPathComponent("remote.git", isDirectory: true)
        try runGit(at: remote.deletingLastPathComponent(), arguments: ["init", "--bare", "-b", "main", remote.path])
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        let baseHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("local\n", to: "tracked.txt")
        try fixture.git("commit", "-am", "local")
        try fixture.git("remote", "add", "origin", remote.path)
        let repository = fixture.url
        let runner = GitPushInterceptor()
        await runner.installBeforeFirstPushHook {
            _ = try runGit(at: repository, arguments: ["push", remote.path, "\(baseHead):refs/heads/main"])
        }
        let service = GitService(runner: runner)
        let target = try await service.preparePushTarget(repository: fixture.url)
        do {
            try await service.pushToUpstream(target: target)
            XCTFail("Expected the destination lease to reject a concurrent branch creation")
        } catch {
            XCTAssertTrue(error is GitServiceError)
        }
        let remoteHead = try runGit(at: remote, arguments: ["rev-parse", "refs/heads/main"])
            .standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteHead, baseHead)
    }
}
