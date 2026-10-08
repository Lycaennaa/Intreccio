import Foundation
@testable import Intreccio
import XCTest

final class RepoScannerIntegrationTests: XCTestCase {
    func testScanFindsRootAndStopsBeforeNestedRepository() async throws {
        let root = try makeTestDirectory()
        try initializeRepository(at: root)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try initializeRepository(at: nested)

        let result = try await RepoScanner().scan(root: root, exclusions: [])

        XCTAssertEqual(result.repositories.map(\.canonicalURL), [root.resolvingSymlinksInPath().standardizedFileURL])
        XCTAssertNil(result.incompleteReason)
        XCTAssertGreaterThanOrEqual(result.visitedDirectoryCount, 1)
        XCTAssertGreaterThanOrEqual(result.duration, .zero)
    }

    func testScanFindsVisibleNestedReposAndSkipsHiddenSymlinkAndExcludedPaths() async throws {
        let root = try makeTestDirectory()
        let visible = root.appendingPathComponent("Visible", isDirectory: true)
        let excluded = root.appendingPathComponent("Excluded", isDirectory: true)
        let hidden = root.appendingPathComponent(".Hidden", isDirectory: true)
        let external = root.deletingLastPathComponent().appendingPathComponent("External-\(UUID().uuidString)", isDirectory: true)
        try initializeRepository(at: visible)
        try initializeRepository(at: excluded)
        try initializeRepository(at: hidden)
        try initializeRepository(at: external)
        addTeardownBlock { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Linked", isDirectory: true),
            withDestinationURL: external
        )

        let result = try await RepoScanner().scan(root: root, exclusions: ["Excluded"])

        XCTAssertEqual(result.repositories.map(\.relativePath), ["Visible"])
    }

    func testScanExcludesAllRepositoriesBelowNestedFolderPath() async throws {
        let root = try makeTestDirectory()
        let active = root.appendingPathComponent("repos/Active", isDirectory: true)
        let inactive = root.appendingPathComponent("external/not active/repos/Inactive", isDirectory: true)
        try initializeRepository(at: active)
        try initializeRepository(at: inactive)

        let result = try await RepoScanner().scan(root: root, exclusions: ["external/not active"])

        XCTAssertEqual(result.repositories.map(\.relativePath), ["repos/Active"])
    }

    func testScannerExclusionMatchesPolicyForNormalizedDescendantPath() async throws {
        let root = try makeTestDirectory()
        let repositoryPath = "external/not active/Repo"
        try initializeRepository(at: root.appendingPathComponent(repositoryPath, isDirectory: true))

        let exclusion = "external/./not active/../not active"
        let result = try await RepoScanner().scan(root: root, exclusions: [exclusion])

        XCTAssertTrue(
            RepositoryPathPolicy.isExcluded(
                relativePath: repositoryPath,
                by: [exclusion],
                root: root
            )
        )
        XCTAssertTrue(result.repositories.isEmpty)
    }

    func testRepositoryLimitReturnsValidPartialResultAndExplicitReason() async throws {
        let root = try makeTestDirectory()
        try initializeRepository(at: root.appendingPathComponent("A", isDirectory: true))
        try initializeRepository(at: root.appendingPathComponent("B", isDirectory: true))
        var configuration = RepoScanner.Configuration()
        configuration.repositoryLimit = 1

        let result = try await RepoScanner(configuration: configuration).scan(root: root, exclusions: [])

        XCTAssertEqual(result.repositories.count, 1)
        XCTAssertEqual(result.incompleteReason, "Scan stopped after finding 1 repositories.")
        XCTAssertGreaterThanOrEqual(result.visitedDirectoryCount, 1)
    }

    func testBookmarkRoundTripResolvesSelectedDirectory() async throws {
        let root = try makeTestDirectory()
        let store = BookmarkStore()
        let bookmark: Data
        do {
            bookmark = try await store.create(for: root)
        } catch {
            throw XCTSkip("Security-scoped bookmarks unavailable in this test host: \(error)")
        }

        let resolution = try await store.resolve(bookmark)
        await store.stopAccessing(resolution)

        XCTAssertEqual(resolution.url.resolvingSymlinksInPath().standardizedFileURL, root.resolvingSymlinksInPath().standardizedFileURL)
    }

    func testCancellingQueuedScanRemovesWaiterBeforeActiveScansRelease() async throws {
        let firstRoot = try makeTestDirectory()
        let secondRoot = try makeTestDirectory()
        let queuedRoot = try makeTestDirectory()
        for root in [firstRoot, secondRoot, queuedRoot] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let runner = BlockingGitRunner()
        let scanner = RepoScanner(gitService: GitService(runner: runner))
        let first = Task { try await scanner.scan(root: firstRoot, exclusions: []) }
        let second = Task { try await scanner.scan(root: secondRoot, exclusions: []) }
        try await waitUntil { await runner.startedCount == 2 }

        let completion = ScanCompletionProbe()
        let queued = Task {
            do {
                _ = try await scanner.scan(root: queuedRoot, exclusions: [])
            } catch {
            }
            await completion.markFinished()
        }
        try await waitUntil { await scanner.waitingCountForTesting == 1 }
        queued.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await completion.finished), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let queuedFinished = await completion.finished
        let startedCount = await runner.startedCount
        XCTAssertTrue(queuedFinished)
        XCTAssertEqual(startedCount, 2)

        await runner.releaseAll()
        _ = await first.result
        _ = await second.result
        _ = await queued.result
    }

    private func initializeRepository(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(at: url, arguments: ["init", "-b", "main"])
    }
}

private actor ScanCompletionProbe {
    private(set) var finished = false

    func markFinished() {
        finished = true
    }
}

private actor BlockingGitRunner: ProcessRunning {
    private var pending: [(URL?, CheckedContinuation<ProcessCommandResult, Never>)] = []
    private(set) var startedCount = 0

    func execute(
        repository: URL?,
        arguments: [String],
        input: Data?,
        environment: [String: String],
        acceptedExitCodes: Set<Int32>,
        outputLimit: Int,
        timeout: Duration,
        priority: ProcessPriority
    ) async -> ProcessCommandResult {
        startedCount += 1
        return await withCheckedContinuation { continuation in
            pending.append((repository, continuation))
        }
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

    func releaseAll() {
        let pending = self.pending
        self.pending.removeAll()
        for (repository, continuation) in pending {
            continuation.resume(returning: recordedGitResult(output: "\(repository?.path ?? "")\n"))
        }
    }
}
