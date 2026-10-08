import AppKit
import XCTest

@testable import Intreccio

@MainActor
final class BranchFileInspectorTests: XCTestCase {
  func testInspectorShowsCommittedBranchContentReadOnly() throws {
    let controller = BranchFileInspectorViewController()
    _ = controller.view
    controller.render(
      BranchFileInspectorPresentation(
        branchName: "feature",
        commitObjectID: String(repeating: "a", count: 40),
        path: "Sources/File.swift",
        state: .text("let branchSnapshot = true\n")
      ))

    let textView = try XCTUnwrap(findTextView(in: controller.view))
    XCTAssertEqual(textView.string, "let branchSnapshot = true\n")
    XCTAssertFalse(textView.isEditable)
    XCTAssertTrue(textView.isSelectable)
  }

  func testBranchFileBrowserSkipsUnchangedReload() {
    let controller = BranchFileBrowserViewController(coordinator: AppCoordinator())
    _ = controller.view
    var presentationChangeCount = 0
    controller.onPresentationChange = { presentationChangeCount += 1 }
    let repository = URL(fileURLWithPath: "/repository")
    let repositoryID = UUID()
    let history = SelectedHistoryState()

    controller.reload(
      repository: repository,
      repositoryID: repositoryID,
      history: history,
      searchText: ""
    )
    XCTAssertEqual(presentationChangeCount, 1)
    controller.reload(
      repository: repository,
      repositoryID: repositoryID,
      history: history,
      searchText: ""
    )
    XCTAssertEqual(presentationChangeCount, 1)
  }

  func testBranchFileBrowserRetriesTransientTreeFailure() async throws {
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
    let objectID = String(repeating: "a", count: 40)
    let blobID = String(repeating: "b", count: 40)
    let runner = RecordingGitRunner(responses: [
      .failure(.launchFailed("temporary tree failure")),
      .result(recordedGitResult(output: "100644 blob \(blobID)\tfile.txt\0"))
    ])
    let coordinator = AppCoordinator(
      stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
      gitService: GitService(runner: runner),
      repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
    )
    coordinator.state.uiState.selectedRepoID = repositoryID
    var history = SelectedHistoryState()
    history.tips = HistoryTips(localObjectID: objectID, upstreamObjectID: nil)
    coordinator.selectedHistoryState = history
    let controller = BranchFileBrowserViewController(coordinator: coordinator)
    _ = controller.view

    controller.reload(
      repository: repositoryURL,
      repositoryID: repositoryID,
      history: history,
      searchText: ""
    )
    try await waitUntil(description: "recoverable branch tree failure") {
      if case .failed = controller.presentation.state { return true }
      return false
    }
    let retryButton = try XCTUnwrap(
      controller.view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Retry" }
    )
    XCTAssertFalse(retryButton.isHidden)
    retryButton.performClick(nil)
    try await waitUntil(description: "branch tree retry completion") {
      controller.fileCount == 1
    }

    let invocations = await runner.invocations
    XCTAssertEqual(invocations.count, 2)
    XCTAssertTrue(invocations.allSatisfy { $0.arguments.first == "ls-tree" })
    _ = await coordinator.shutdown()
  }

  func testHistoryPaginationFailurePreservesLoadedBranchPreview() async throws {
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
    let objectID = String(repeating: "a", count: 40)
    let blobID = String(repeating: "b", count: 40)
    let blobContents = "committed contents"
    let runner = RecordingGitRunner(responses: [
      .result(recordedGitResult(output: "100644 blob \(blobID)\tfile.txt\0")),
      .result(recordedGitResult(output: blobContents))
    ])
    let coordinator = AppCoordinator(
      stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
      gitService: GitService(runner: runner),
      repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
    )
    coordinator.state.uiState.selectedRepoID = repositoryID
    var history = SelectedHistoryState()
    history.tips = HistoryTips(localObjectID: objectID, upstreamObjectID: nil)
    coordinator.selectedHistoryState = history
    let controller = BranchFileBrowserViewController(coordinator: coordinator)
    _ = controller.view
    controller.reload(
      repository: repositoryURL,
      repositoryID: repositoryID,
      history: history,
      searchText: ""
    )
    try await selectFirstBranchFile(controller, expectedContents: blobContents)

    failHistoryPagination(
      &history,
      coordinator: coordinator,
      controller: controller,
      repositoryURL: repositoryURL,
      repositoryID: repositoryID
    )

    if case .text(let text) = controller.presentation.state {
      XCTAssertEqual(text, blobContents)
    } else {
      XCTFail("History pagination failure hid the loaded branch preview")
    }
    let retryButton = try XCTUnwrap(
      controller.view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Retry" }
    )
    XCTAssertTrue(retryButton.isHidden)
    let invocations = await runner.invocations
    XCTAssertEqual(invocations.count, 2)
    _ = await coordinator.shutdown()
  }

  private func selectFirstBranchFile(
    _ controller: BranchFileBrowserViewController,
    expectedContents: String
  ) async throws {
    try await waitUntil(description: "loaded branch tree") { controller.fileCount == 1 }
    let scrollView = try XCTUnwrap(
      controller.view.subviews.compactMap { $0 as? NSScrollView }.first
    )
    let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
    tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    controller.tableViewSelectionDidChange(Notification(name: Notification.Name("test selection")))
    try await waitUntil(description: "loaded committed preview") {
      if case .text(let text) = controller.presentation.state { return text == expectedContents }
      return false
    }
  }

  private func failHistoryPagination(
    _ history: inout SelectedHistoryState,
    coordinator: AppCoordinator,
    controller: BranchFileBrowserViewController,
    repositoryURL: URL,
    repositoryID: UUID
  ) {
    history.phase = .failed(
      .git(
        ProcessRunnerError.launchFailed("history pagination failed"),
        title: "Could not load history"
      )
    )
    coordinator.selectedHistoryState = history
    controller.reload(
      repository: repositoryURL,
      repositoryID: repositoryID,
      history: history,
      searchText: ""
    )
  }

  private func findTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for child in view.subviews {
      if let textView = findTextView(in: child) { return textView }
    }
    return nil
  }
  func testHeaderOpensOnlyLocalBranchWorktrees() {
    let branch = GitBranchReference(
      refName: "refs/heads/feature",
      name: "feature",
      objectID: String(repeating: "a", count: 40),
      isCurrent: false
    )
    let header = HistoryHeaderView(frame: .zero)
    var openedBranch: String?
    header.onOpenWorktree = { openedBranch = $0 }
    header.render(
      history: SelectedHistoryState(
        scope: .mixed,
        branches: [branch],
        selectedBranchRef: branch.refName
      ),
      scope: .mixed,
      summary: "",
      searchText: ""
    )
    XCTAssertTrue(header.worktreeButton.isEnabled)
    XCTAssertEqual(header.worktreeButton.title, "Open Branch Worktree")
    header.worktreeButton.performClick(nil)
    XCTAssertEqual(openedBranch, branch.refName)

    let remoteBranch = GitBranchReference(
      refName: "refs/remotes/origin/feature",
      name: "origin/feature",
      objectID: branch.objectID,
      isCurrent: false
    )
    header.render(
      history: SelectedHistoryState(
        scope: .mixed,
        branches: [remoteBranch],
        selectedBranchRef: remoteBranch.refName
      ),
      scope: .mixed,
      summary: "",
      searchText: ""
    )
    XCTAssertFalse(header.worktreeButton.isEnabled)
  }
}
