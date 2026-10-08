import Foundation
import XCTest

@testable import Intreccio

@MainActor
extension AppCoordinatorTests {
  private func makeHistoryCoordinator(
    directory: URL,
    responses: [RecordingGitResponse]
  ) -> (coordinator: AppCoordinator, runner: RecordingGitRunner) {
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
    let runner = RecordingGitRunner(responses: responses)
    let coordinator = AppCoordinator(
      stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
      gitService: GitService(runner: runner),
      repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
    )
    coordinator.state.uiState.selectedRepoID = repositoryID
    return (coordinator, runner)
  }

  private func snapshotWithoutSelectedRepository(_ snapshot: AppSnapshot) -> AppSnapshot {
    var state = snapshot.state
    state.uiState.selectedRepoID = nil
    return AppSnapshot(
      state: state,
      repositories: snapshot.repositories,
      scanMessages: snapshot.scanMessages,
      runtime: snapshot.runtime,
      selectedSession: snapshot.selectedSession,
      mutationState: snapshot.mutationState,
      commitMessage: snapshot.commitMessage,
      usesDefaultCommitMessage: snapshot.usesDefaultCommitMessage,
      amendSession: snapshot.amendSession,
      errorMessage: snapshot.errorMessage,
      stateSaveErrorMessage: snapshot.stateSaveErrorMessage,
      statusMessage: snapshot.statusMessage,
      hasLoadedState: snapshot.hasLoadedState,
      hasStarted: snapshot.hasStarted
    )
  }

  private func historyPageResponses(
    headObjectID: String,
    commitObjectID: String,
    subject: String
  ) -> [RecordingGitResponse] {
    let branchList = "refs/heads/main\0main\0\(headObjectID)\0*\0\n"
    let tips = "\(headObjectID)\0\0\n"
    let commitRecord = historyBatchRecord(objectID: commitObjectID, subject: subject)
    return [
      .result(recordedGitResult(output: branchList)),
      .result(recordedGitResult(output: "refs/heads/main\n")),
      .result(recordedGitResult(output: tips)),
      .result(recordedGitResult(output: "\(commitObjectID)\0\n")),
      .result(.init(exitCode: 0, standardOutput: commitRecord, standardError: Data())),
      .result(recordedGitResult(output: "refs/heads/main\n")),
      .result(recordedGitResult(output: tips))
    ]
  }

  func testHistoryFirstPageRejectsStaleTipsBeforeAppending() async throws {

    let directory = try makeTestDirectory()
    let oldHead = String(repeating: "a", count: 40)
    let newHead = String(repeating: "b", count: 40)
    let oldID = String(repeating: "c", count: 40)
    let newID = String(repeating: "d", count: 40)
    let responses: [RecordingGitResponse] = [
      .result(recordedGitResult(output: "refs/heads/main\0main\0\(oldHead)\0*\0\n")),
      .result(recordedGitResult(output: "refs/heads/main\n")),
      .result(recordedGitResult(output: "\(oldHead)\0\0\n")),
      .result(recordedGitResult(output: "\(oldID)\0\n")),
      .result(
        .init(
          exitCode: 0, standardOutput: historyBatchRecord(objectID: oldID, subject: "old head"),
          standardError: Data())),
      .result(recordedGitResult(output: "refs/heads/main\n")),
      .result(recordedGitResult(output: "\(newHead)\0\0\n")),
      .result(recordedGitResult(output: "refs/heads/main\0main\0\(newHead)\0*\0\n")),
      .result(recordedGitResult(output: "refs/heads/main\n")),
      .result(recordedGitResult(output: "\(newHead)\0\0\n")),
      .result(recordedGitResult(output: "\(newID)\0\n")),
      .result(
        .init(
          exitCode: 0, standardOutput: historyBatchRecord(objectID: newID, subject: "new head"),
          standardError: Data())),
      .result(recordedGitResult(output: "refs/heads/main\n")),
      .result(recordedGitResult(output: "\(newHead)\0\0\n"))
    ]
    let (coordinator, runner) = makeHistoryCoordinator(directory: directory, responses: responses)

    coordinator.setMode(.history)
    do {
      try await waitUntil(description: "stale first history page replacement") {
        coordinator.selectedHistoryState.commits.first?.subject == "new head"
      }
    } catch {
      let invocations = await runner.invocations
      XCTFail("First history reload did not complete; invocations: \(invocations.map(\.arguments))")
      _ = await coordinator.shutdown()
      return
    }

    XCTAssertEqual(coordinator.selectedHistoryState.commits.map(\.subject), ["new head"])
    XCTAssertEqual(coordinator.selectedHistoryState.tips?.localObjectID, newHead)
    let invocations = await runner.invocations
    XCTAssertEqual(invocations.count, 14)
    XCTAssertEqual(invocations[3].arguments.first, "log")
    XCTAssertEqual(invocations[4].arguments, ["cat-file", "--batch"])
    XCTAssertEqual(invocations[6].arguments.first, "for-each-ref")
    XCTAssertEqual(invocations[10].arguments.first, "log")
    _ = await coordinator.shutdown()
  }
  func testPaginatedHistoryStillRejectsStaleTipsBeforeAppendingPage() async throws {

    let directory = try makeTestDirectory()
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
    let responses: [RecordingGitResponse] = [
      .result(recordedGitResult(output: "refs/heads/main\0main\0\(oldHead)\0*\0\n")),
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
      .result(recordedGitResult(output: "refs/heads/main\0main\0\(newHead)\0*\0\n")),
      .result(recordedGitResult(output: "refs/heads/main\n")),
      .result(recordedGitResult(output: "\(newHead)\0\0\n")),
      .result(recordedGitResult(output: newLogOutput)),
      .result(.init(exitCode: 0, standardOutput: newRecord, standardError: Data())),
      .result(recordedGitResult(output: "refs/heads/main\n")),
      .result(recordedGitResult(output: "\(newHead)\0\0\n"))
    ]
    let (coordinator, runner) = makeHistoryCoordinator(directory: directory, responses: responses)

    coordinator.setMode(.history)
    do {
      try await waitUntil(description: "initial full history page") {
        coordinator.selectedHistoryState.commits.count == 15
      }
    } catch {
      let invocations = await runner.invocations
      XCTFail("Initial history page did not complete; invocations: \(invocations.map(\.arguments))")
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
      XCTFail("History reload did not complete; invocations: \(invocations.map(\.arguments))")
      _ = await coordinator.shutdown()
      return
    }

    XCTAssertEqual(coordinator.selectedHistoryState.commits.count, 1)
    XCTAssertEqual(coordinator.selectedHistoryState.tips?.localObjectID, newHead)
    _ = await coordinator.shutdown()
  }
  func testBranchEnumerationOutputLimitDoesNotBlockHistory() async throws {
    let directory = try makeTestDirectory()
    let headObjectID = String(repeating: "a", count: 40)
    let commitObjectID = String(repeating: "b", count: 40)
    let pageResponses = historyPageResponses(
      headObjectID: headObjectID,
      commitObjectID: commitObjectID,
      subject: "history still loads"
    )
    let outputLimitError = ProcessRunnerError.outputLimitExceeded(
      stream: .standardOutput,
      limit: ProcessRunner.defaultOutputLimit,
      result: recordedGitResult(output: "partial refs")
    )
    let (coordinator, runner) = makeHistoryCoordinator(
      directory: directory,
      responses: [.failure(outputLimitError)] + Array(pageResponses.dropFirst())
    )

    coordinator.setMode(.history)
    try await waitUntil(description: "history after oversized branch list") {
      coordinator.selectedHistoryState.commits.first?.subject == "history still loads"
    }

    XCTAssertTrue(coordinator.selectedHistoryState.branches.isEmpty)
    let invocations = await runner.invocations
    XCTAssertEqual(invocations.count, 7)
    XCTAssertEqual(invocations[1].arguments.first, "symbolic-ref")
    XCTAssertEqual(invocations[3].arguments.first, "log")
    _ = await coordinator.shutdown()
  }

  func testHistoryFailureWaitsForExplicitRetry() async throws {
    let directory = try makeTestDirectory()
    let headObjectID = String(repeating: "c", count: 40)
    let commitObjectID = String(repeating: "d", count: 40)
    let pageResponses = historyPageResponses(
      headObjectID: headObjectID,
      commitObjectID: commitObjectID,
      subject: "retried history"
    )
    let responses = Array(pageResponses.prefix(3))
      + [.failure(.launchFailed("temporary history failure"))]
      + pageResponses
    let (coordinator, runner) = makeHistoryCoordinator(directory: directory, responses: responses)

    coordinator.setMode(.history)
    try await waitUntil(description: "failed history phase") {
      if case .failed = coordinator.selectedHistoryState.phase { return true }
      return false
    }
    coordinator.loadNextHistoryPage()
    let failedInvocations = await runner.invocations
    XCTAssertEqual(failedInvocations.count, 4)

    let controller = HistoryViewController(coordinator: coordinator)
    controller.loadView()
    controller.reload(coordinator.snapshot)
    let header = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? HistoryHeaderView }.first)
    let failedSnapshot = coordinator.snapshot
    var branchHistory = failedSnapshot.selectedSession.historyState
    branchHistory.selectedBranchRef = "refs/heads/feature"
    header.render(
      history: branchHistory,
      scope: failedSnapshot.selectedSession.historyScope,
      summary: "feature",
      searchText: ""
    )
    XCTAssertEqual(header.worktreeButton.title, "Open Branch Worktree")
    controller.reload(snapshotWithoutSelectedRepository(failedSnapshot))
    XCTAssertTrue(header.retryHistoryButton.isHidden)
    XCTAssertEqual(header.worktreeButton.title, "Open Current Worktree")
    XCTAssertFalse(header.worktreeButton.isEnabled)
    header.setWorktreeOpening(false)
    XCTAssertFalse(header.worktreeButton.isEnabled)
    controller.reload(failedSnapshot)
    XCTAssertFalse(header.retryHistoryButton.isHidden)
    header.contentControl.selectedSegment = 1
    let contentAction = try XCTUnwrap(header.contentControl.action)
    XCTAssertTrue(
      NSApp.sendAction(contentAction, to: header.contentControl.target, from: header.contentControl)
    )
    if case .failed(let message) = controller.branchFilePresentation.state {
      XCTAssertTrue(message.contains("Could not load history"))
    } else {
      XCTFail("Files mode hid the history failure")
    }
    let failedViewInvocations = await runner.invocations
    XCTAssertEqual(failedViewInvocations.count, 4)
    XCTAssertFalse(header.retryHistoryButton.isHidden)
    header.retryHistoryButton.performClick(nil)
    try await waitUntil(description: "explicitly retried history page") {
      coordinator.selectedHistoryState.commits.first?.subject == "retried history"
    }

    let invocations = await runner.invocations
    XCTAssertEqual(invocations.count, 11)
    XCTAssertEqual(coordinator.selectedHistoryState.phase, .idle)
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
    let commitRecord = historyBatchRecord(
      objectID: commitID, parentID: parentID, subject: "selected")
    let runner = RecordingGitRunner(responses: [
      .result(recordedGitResult(output: "refs/heads/main\0main\0\(tipsHead)\0*\0\n")),
      .result(recordedGitResult(output: "refs/heads/main\n")),
      .result(recordedGitResult(output: "\(tipsHead)\0\0\n")),
      .result(recordedGitResult(output: "\(commitID)\0\n")),
      .result(.init(exitCode: 0, standardOutput: commitRecord, standardError: Data())),
      .result(recordedGitResult(output: "refs/heads/main\n")),
      .result(recordedGitResult(output: "\(tipsHead)\0\0\n")),
      .result(.init(exitCode: 0, standardOutput: commitRecord, standardError: Data())),
      .result(recordedGitResult(output: "M\0file.txt\0")),
      .result(recordedGitResult()),
      .failure(.cancelled(recordedGitResult(exitCode: -1)))
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
      XCTFail(
        "Cancelled commit cleanup did not complete; invocations: \(invocations.map(\.arguments))")
      _ = await coordinator.shutdown()
      return
    }

    XCTAssertEqual(coordinator.selectedCommitState, .idle)
    let invocations = await runner.invocations
    XCTAssertEqual(invocations.count, 11)
    _ = await coordinator.shutdown()
  }
}
