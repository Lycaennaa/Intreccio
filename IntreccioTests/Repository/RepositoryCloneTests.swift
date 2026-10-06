import Foundation
import XCTest
@testable import Intreccio

final class RepositoryCloneTests: XCTestCase {
    func testCloneURLNormalizesGitHubRemoteFormsAndRejectsOtherHosts() {
        XCTAssertEqual(
            GitHubRepositoryURL.cloneURL(from: "git@github.com:octo/repo.git"),
            URL(string: "https://github.com/octo/repo.git")
        )
        XCTAssertEqual(
            GitHubRepositoryURL.cloneURL(from: "https://github.com/octo/private"),
            URL(string: "https://github.com/octo/private.git")
        )
        XCTAssertNil(GitHubRepositoryURL.cloneURL(from: "https://gitlab.com/octo/repo.git"))
    }
    func testCloneInputAcceptsMultipleURLsAndIgnoresBlankLines() throws {
        let cloneURLs = try XCTUnwrap(
            RepositoryClonePanel.cloneURLs(
                from: "\nhttps://github.com/octo/one\n\n https://github.com/octo/two.git \n"
            )
        )

        XCTAssertEqual(
            cloneURLs,
            [
                URL(string: "https://github.com/octo/one.git"),
                URL(string: "https://github.com/octo/two.git")
            ]
        )
    }

    func testCloneUsesTemporaryDirectoryAndPublishesRepositoryAtDerivedName() async throws {
        let parent = try makeTestDirectory()
        let runner = CloneRecordingRunner()
        let source = try XCTUnwrap(URL(string: "https://github.com/octo/repo.git"))

        let control = ProcessControl()
        let result = try await GitService(runner: runner).cloneRepository(
            from: source,
            into: parent,
            control: control
        )

        let resultURL = result.url
        XCTAssertEqual(resultURL, parent.appendingPathComponent("repo", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.appendingPathComponent(".git").path))
        let invocations = await runner.invocations
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(Array(invocation.prefix(5)), ["clone", "--progress", "--recurse-submodules", "--", "https://github.com/octo/repo.git"])
        XCTAssertTrue(invocation.last?.hasPrefix(parent.path + "/.intreccio-clone-") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.last ?? ""))
        XCTAssertTrue(invocations.contains { $0.first == "submodule" })
        let streamingInvocations = await runner.streamingInvocations
        XCTAssertTrue(streamingInvocations.contains { $0.first == "clone" })
        let progressEventCount = await runner.progressEventCount
        let receivedControl = await runner.receivedControl
        XCTAssertGreaterThan(progressEventCount, 0)
        XCTAssertTrue(receivedControl)
    }

    func testEmptyRepositoryCloneSkipsLFSOperations() async throws {
        let parent = try makeTestDirectory()
        let runner = CloneRecordingRunner(hasCommit: false)
        let source = try XCTUnwrap(URL(string: "https://github.com/octo/empty-private"))

        let result = try await GitService(runner: runner).cloneRepository(from: source, into: parent)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.appendingPathComponent(".git").path))
        let invocations = await runner.invocations
        XCTAssertTrue(invocations.contains(["rev-parse", "--verify", "--quiet", "HEAD"]))
        XCTAssertFalse(invocations.contains { $0.first == "lfs" })
    }

    func testCloneRejectsExistingDestinationBeforeInvokingGit() async throws {
        let parent = try makeTestDirectory()
        let destination = parent.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let runner = CloneRecordingRunner()
        let source = try XCTUnwrap(URL(string: "https://github.com/octo/repo"))

        do {
            _ = try await GitService(runner: runner).cloneRepository(from: source, into: parent)
            XCTFail("Expected destination conflict")
        } catch RepositoryCloneError.destinationExists(let path) {
            XCTAssertEqual(path, destination.path)
        }

        let invocations = await runner.invocations
        XCTAssertTrue(invocations.isEmpty)
    }
    func testFailedCloneCleansUpItsTemporaryDirectory() async throws {
        let parent = try makeTestDirectory()
        let runner = CloneRecordingRunner(fails: true)
        let source = try XCTUnwrap(URL(string: "https://github.com/octo/repo"))

        do {
            _ = try await GitService(runner: runner).cloneRepository(from: source, into: parent)
            XCTFail("Expected clone failure")
        } catch RepositoryCloneError.cleanupFailed(_, _) {
            XCTFail("Temporary clone cleanup failed")
        } catch GitRunnerError.nonZeroExit(let result) {
            XCTAssertEqual(result.exitCode, 128)
        } catch {
            XCTFail("Unexpected clone error: \(error)")
        }

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: []).isEmpty)
    }
    func testCreateLocalRepositoryInitializesNamedFolder() async throws {
        let parent = try makeTestDirectory()
        let runner = CloneRecordingRunner()

        let result = try await GitService(runner: runner).createLocalRepository(named: "NewRepo", in: parent)

        let resultURL = result.url
        XCTAssertEqual(resultURL, parent.appendingPathComponent("NewRepo", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.appendingPathComponent(".git").path))
        let invocations = await runner.invocations
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(invocation, ["init", "-b", "main", resultURL.path])
    }
    func testLFSRepositoryFailsClearlyWhenGitLFSIsUnavailable() async throws {
        let parent = try makeTestDirectory()
        let runner = CloneRecordingRunner(lfsAvailable: false, hasLFSAttributes: true)
        let source = try XCTUnwrap(URL(string: "https://github.com/octo/repo"))

        do {
            _ = try await GitService(runner: runner).cloneRepository(from: source, into: parent)
            XCTFail("Expected Git LFS requirement")
        } catch RepositoryCloneError.gitLFSMissing {
        }

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: []).isEmpty)
    }


    @MainActor
    func testAddingFolderInsideRepositoryRegistersTopLevelRepository() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        let nested = repository.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try runGit(at: repository, arguments: ["init", "-b", "main"])
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json"))
        )
        addTeardownBlock { _ = await coordinator.shutdown() }

        await coordinator.addStandaloneRepository(nested)

        XCTAssertEqual(coordinator.repositories.map(\.canonicalURL), [repository.resolvingSymlinksInPath().standardizedFileURL])
        XCTAssertEqual(coordinator.state.standaloneRepos.first?.lastResolvedPath, repository.path)
    }
    @MainActor
    func testCatalogRegistrationFailureRemovesCreatedClone() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        try Data(#"{"schemaVersion":999}"#.utf8).write(to: stateFile)
        let stateStore = StateStore(fileURL: stateFile)
        _ = await stateStore.load()
        let runner = CloneRecordingRunner()
        let catalog = RepositoryCatalog(
            stateStore: stateStore,
            bookmarkStore: BookmarkStore(),
            scanner: RepoScanner(),
            gitService: GitService(runner: runner)
        )
        let delegate = CatalogCommandDelegate()
        catalog.delegate = delegate
        addTeardownBlock { _ = await catalog.shutdown() }
        let source = try XCTUnwrap(URL(string: "https://github.com/octo/repo"))

        do {
            _ = try await catalog.cloneRepository(from: source, into: directory)
            XCTFail("Expected catalog registration failure")
        } catch StateStoreError.writeBlocked {
        } catch {
            XCTFail("Unexpected catalog error: \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("repo", isDirectory: true).path
            )
        )
    }

}

private actor CloneRecordingRunner: ProcessRunning {
    private let fails: Bool
    private let lfsAvailable: Bool
    private let hasLFSAttributes: Bool
    private(set) var invocations: [[String]] = []
    private(set) var streamingInvocations: [[String]] = []
    private(set) var progressEventCount = 0
    private let hasCommit: Bool
    private(set) var receivedControl = false

    init(
        fails: Bool = false,
        lfsAvailable: Bool = true,
        hasLFSAttributes: Bool = false,
        hasCommit: Bool = true
    ) {
        self.fails = fails
        self.lfsAvailable = lfsAvailable
        self.hasLFSAttributes = hasLFSAttributes
        self.hasCommit = hasCommit
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
        streamingInvocations.append(arguments)
        receivedControl = receivedControl || control != nil
        progressEventCount += 1
        progress(.standardError, Data("Receiving objects: 50%\\n".utf8))
        return try await execute(
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
        invocations.append(arguments)
        if arguments.first == "init", let repositoryPath = arguments.last {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: repositoryPath).appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
            return recordedGitResult()
        }
        if arguments == ["rev-parse", "--verify", "--quiet", "HEAD"] {
            return recordedGitResult(output: hasCommit ? "0123456789abcdef\n" : "", exitCode: hasCommit ? 0 : 1)
        }
        if arguments.first == "rev-parse", let repository {
            return recordedGitResult(output: "\(repository.path)\n")
        }
        if arguments.first == "grep" {
            return recordedGitResult(exitCode: hasLFSAttributes ? 0 : 1)
        }
        if arguments == ["lfs", "version"] || arguments == ["lfs", "pull"] || arguments.first == "submodule" {
            return recordedGitResult(exitCode: lfsAvailable ? 0 : 1)
        }
        guard arguments.first == "clone", let temporaryPath = arguments.last else {
            throw GitRunnerError.launchFailed("Unexpected clone invocation")
        }
        if fails {
            throw GitRunnerError.nonZeroExit(recordedGitResult(error: "clone failed", exitCode: 128))
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: temporaryPath).appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        return recordedGitResult()
    }
}