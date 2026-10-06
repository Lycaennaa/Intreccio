import Foundation
import XCTest
@testable import Intreccio


@MainActor
extension AppCoordinatorTests {
    func testHistoryFirstPageRejectsStaleTipsBeforeAppending() async throws {

        let directory = try makeTestDirectory()
        let repositoryID = UUID()
        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let oldHead = String(repeating: "a", count: 40)
        let newHead = String(repeating: "b", count: 40)
        let oldID = String(repeating: "c", count: 40)
        let newID = String(repeating: "d", count: 40)
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(oldHead)\0\0\n")),
            .result(recordedGitResult(output: "\(oldID)\0\n")),
            .result(.init(exitCode: 0, standardOutput: historyBatchRecord(objectID: oldID, subject: "old head"), standardError: Data())),
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(newHead)\0\0\n")),
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(newHead)\0\0\n")),
            .result(recordedGitResult(output: "\(newID)\0\n")),
            .result(.init(exitCode: 0, standardOutput: historyBatchRecord(objectID: newID, subject: "new head"), standardError: Data())),
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(newHead)\0\0\n"))
        ])
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
            gitService: GitService(runner: runner),
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID

        coordinator.setMode(.history)
        do {
            try await waitUntil(description: "stale first history page replacement") {
                coordinator.selectedHistoryState.commits.first?.subject == "new head"
            }
        } catch {
            let invocations = await runner.invocations
            XCTFail("First history reload did not complete; invocations: \(invocations.map { $0.arguments })")
            _ = await coordinator.shutdown()
            return
        }

        XCTAssertEqual(coordinator.selectedHistoryState.commits.map(\.subject), ["new head"])
        XCTAssertEqual(coordinator.selectedHistoryState.tips?.localObjectID, newHead)
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 12)
        XCTAssertEqual(invocations[2].arguments.first, "log")
        XCTAssertEqual(invocations[3].arguments, ["cat-file", "--batch"])
        XCTAssertEqual(invocations[5].arguments.first, "for-each-ref")
        XCTAssertEqual(invocations[8].arguments.first, "log")
        _ = await coordinator.shutdown()
    }
    func testPaginatedHistoryStillRejectsStaleTipsBeforeAppendingPage() async throws {

        let directory = try makeTestDirectory()
        let repositoryID = UUID()
        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let oldHead = String(repeating: "a", count: 40)
        let newHead = String(repeating: "b", count: 40)
        let oldIDs = (0..<15).map { String(format: "%040x", $0 + 1) }
        var oldPage = Data()
        for (index, objectID) in oldIDs.enumerated() {
            oldPage.append(historyBatchRecord(objectID: objectID, subject: "old \(index)"))
        }
        let newRecord = historyBatchRecord(objectID: newHead, subject: "new head")
        let oldLogOutput = oldIDs.map { "\($0)\0" }.joined()
        let newLogOutput = "\(newHead)\0\n"
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(oldHead)\0\0\n")),
            .result(recordedGitResult(output: oldLogOutput)),
            .result(.init(exitCode: 0, standardOutput: oldPage, standardError: Data())),
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(oldHead)\0\0\n")),
            .result(recordedGitResult(output: newLogOutput)),
            .result(.init(exitCode: 0, standardOutput: newRecord, standardError: Data())),
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(newHead)\0\0\n")),
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(newHead)\0\0\n")),
            .result(recordedGitResult(output: newLogOutput)),
            .result(.init(exitCode: 0, standardOutput: newRecord, standardError: Data())),
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(newHead)\0\0\n")),
        ])
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
            gitService: GitService(runner: runner),
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID

        coordinator.setMode(.history)
        do {
            try await waitUntil(description: "initial full history page") {
                coordinator.selectedHistoryState.commits.count == 15
            }
        } catch {
            let invocations = await runner.invocations
            XCTFail("Initial history page did not complete; invocations: \(invocations.map { $0.arguments })")
            _ = await coordinator.shutdown()
            return
        }
        coordinator.loadNextHistoryPage()

        do {
            try await waitUntil(description: "stale history page replacement") {
                coordinator.selectedHistoryState.commits.first?.subject == "new head"
            }
        } catch {
            let invocations = await runner.invocations
            XCTFail("History reload did not complete; invocations: \(invocations.map { $0.arguments })")
            _ = await coordinator.shutdown()
            return
        }

        XCTAssertEqual(coordinator.selectedHistoryState.commits.count, 1)
        XCTAssertEqual(coordinator.selectedHistoryState.tips?.localObjectID, newHead)
        _ = await coordinator.shutdown()
    }
    func testCancelledSelectedCommitLoadReturnsToIdle() async throws {
        let directory = try makeTestDirectory()
        let repositoryID = UUID()
        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let tipsHead = String(repeating: "a", count: 40)
        let commitID = String(repeating: "b", count: 40)
        let parentID = String(repeating: "c", count: 40)
        let commitRecord = historyBatchRecord(objectID: commitID, parentID: parentID, subject: "selected")
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(tipsHead)\0\0\n")),
            .result(recordedGitResult(output: "\(commitID)\0\n")),
            .result(.init(exitCode: 0, standardOutput: commitRecord, standardError: Data())),
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(tipsHead)\0\0\n")),
            .result(.init(exitCode: 0, standardOutput: commitRecord, standardError: Data())),
            .result(recordedGitResult(output: "M\0file.txt\0")),
            .result(recordedGitResult()),
            .failure(.cancelled(recordedGitResult(exitCode: -1))),
        ])
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
            gitService: GitService(runner: runner),
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID

        coordinator.setMode(.history)
        try await waitUntil(description: "history commit for cancellation") {
            coordinator.selectedHistoryState.commits.count == 1
        }
        coordinator.selectCommit(try XCTUnwrap(coordinator.selectedHistoryState.commits.first))
        do {
            try await waitUntil(description: "cancelled commit load cleanup") {
                if case .idle = coordinator.selectedCommitState { return true }
                return false
            }
        } catch {
            let invocations = await runner.invocations
            XCTFail("Cancelled commit cleanup did not complete; invocations: \(invocations.map { $0.arguments })")
            _ = await coordinator.shutdown()
            return
        }

        XCTAssertEqual(coordinator.selectedCommitState, .idle)
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 10)
        _ = await coordinator.shutdown()
    }
}