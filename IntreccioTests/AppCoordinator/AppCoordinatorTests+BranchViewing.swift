import AppKit
import Foundation
import XCTest

@testable import Intreccio

@MainActor
extension AppCoordinatorTests {
  func testSelectingAnotherBranchLoadsHistoryWithoutChangingWorktree() async throws {
    let directory = try makeTestDirectory()
    let repository = directory.appendingPathComponent("Repo", isDirectory: true)
    try initializeRepository(at: repository)
    try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
    try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
    try "main\n".write(
      to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    try runGit(at: repository, arguments: ["add", "-A"])
    try runGit(at: repository, arguments: ["commit", "-m", "main commit"])
    try runGit(at: repository, arguments: ["checkout", "-b", "feature"])
    try "feature\n".write(
      to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    try runGit(at: repository, arguments: ["add", "-A"])
    try runGit(at: repository, arguments: ["commit", "-m", "feature commit"])
    try runGit(at: repository, arguments: ["checkout", "main"])
    try "dirty\n".write(
      to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    try "untracked\n".write(
      to: repository.appendingPathComponent("untracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    let statusBefore = try runGit(
      at: repository,
      arguments: ["status", "--porcelain=v1", "--untracked-files=all"]
    ).standardOutputText
    let headBefore = try runGit(at: repository, arguments: ["rev-parse", "HEAD"]).standardOutputText

    let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
    await coordinator.addStandaloneRepository(repository)
    let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
    coordinator.setMode(.history)
    coordinator.selectRepository(repositoryID)
    try await waitUntil(description: "branch options loaded") {
      coordinator.selectedHistoryState.branches.contains { $0.refName == "refs/heads/feature" }
    }

    coordinator.setHistoryBranch("refs/heads/feature")
    try await waitUntil(description: "selected branch history loaded") {
      coordinator.selectedHistoryState.selectedBranchRef == "refs/heads/feature"
        && coordinator.selectedHistoryState.commits.first?.subject == "feature commit"
        && coordinator.selectedHistoryState.phase == .idle
    }
    coordinator.beginAmending(try XCTUnwrap(coordinator.selectedHistoryState.commits.first))

    XCTAssertFalse(coordinator.isAmendingCommit)
    let headAfter = try runGit(at: repository, arguments: ["rev-parse", "HEAD"]).standardOutputText
    let statusAfter = try runGit(
      at: repository,
      arguments: ["status", "--porcelain=v1", "--untracked-files=all"]
    ).standardOutputText
    let trackedContents = try String(
      contentsOf: repository.appendingPathComponent("tracked.txt"),
      encoding: .utf8
    )
    let untrackedContents = try String(
      contentsOf: repository.appendingPathComponent("untracked.txt"),
      encoding: .utf8
    )
    XCTAssertEqual(headAfter, headBefore)
    XCTAssertEqual(statusAfter, statusBefore)
    XCTAssertEqual(trackedContents, "dirty\n")
    XCTAssertEqual(untrackedContents, "untracked\n")
  }

  func testSwitchingRepositoriesClearsBranchSelectionOnlyOnRepositoryChange() throws {
    let directory = try makeTestDirectory()
    let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
    let firstRepositoryID = UUID()
    let secondRepositoryID = UUID()
    let feature = GitBranchReference(
      refName: "refs/heads/feature",
      name: "feature",
      objectID: String(repeating: "a", count: 40),
      isCurrent: false
    )

    coordinator.setMode(.history)
    coordinator.selectRepository(firstRepositoryID)
    coordinator.selectedHistoryState.branches = [feature]
    coordinator.setHistoryBranch(feature.refName)
    XCTAssertEqual(coordinator.selectedHistoryState.selectedBranchRef, feature.refName)

    coordinator.selectRepository(firstRepositoryID)
    XCTAssertEqual(coordinator.selectedHistoryState.selectedBranchRef, feature.refName)
    coordinator.selectRepository(secondRepositoryID)
    XCTAssertNil(coordinator.selectedHistoryState.selectedBranchRef)
  }
  func testOpeningBranchWorktreeStagesChangesWithoutTouchingMainWorktree() async throws {
    let fixture = try makeLinkedWorktreeFixture()
    let directory = fixture.directory
    let repository = fixture.repository
    let worktreeURL = fixture.worktreeURL
    let mainHead = fixture.mainHead
    let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
    await coordinator.addStandaloneRepository(repository)
    let mainRepositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
    coordinator.setMode(.history)
    coordinator.selectRepository(mainRepositoryID)
    try await waitUntil(description: "linked branch available") {
      coordinator.selectedHistoryState.branches.contains { $0.refName == "refs/heads/feature" }
    }
    coordinator.setHistoryBranch("refs/heads/feature")
    try await waitUntil(description: "linked branch history loaded") {
      coordinator.selectedHistoryState.commits.first?.subject == "feature commit"
        && coordinator.selectedHistoryState.phase == .idle
    }

    await coordinator.openHistoryBranchWorktree("refs/heads/feature")
    try await waitUntil(description: "linked worktree selected in Changes") {
      let selected = coordinator.repositories.first { $0.id == coordinator.state.uiState.selectedRepoID }
      return coordinator.state.uiState.mode == .changes
        && selected?.canonicalURL.standardizedFileURL == worktreeURL.standardizedFileURL
    }
    let selector = try await makeWorktreeSelector(coordinator, worktreeURL: worktreeURL)
    try await waitUntil(description: "linked worktree changes loaded") {
      coordinator.selectedStatus?.changes.contains {
        $0.gitPath == GitPath("tracked.txt") && $0.hasUnstagedChange
      } == true
    }
    coordinator.stageAll()
    try await waitUntil(description: "linked worktree change staged") {
      !coordinator.hasActiveMutation
        && coordinator.selectedStatus?.changes.contains {
          $0.gitPath == GitPath("tracked.txt") && $0.hasStagedChange
        } == true
    }
    try await switchChangesWorktrees(
      coordinator: coordinator,
      selector: selector,
      repositoryURL: repository,
      worktreeURL: worktreeURL
    )

    let mainStatus = try runGit(
      at: repository,
      arguments: ["status", "--porcelain=v1", "--untracked-files=all"]
    ).standardOutputText
    let worktreeStatus = try runGit(
      at: worktreeURL,
      arguments: ["status", "--porcelain=v1", "--untracked-files=all"]
    ).standardOutputText
    let headAfter = try runGit(at: repository, arguments: ["rev-parse", "HEAD"]).standardOutputText
    XCTAssertEqual(mainStatus, "")
    XCTAssertTrue(worktreeStatus.contains("tracked.txt"))
    XCTAssertEqual(headAfter, mainHead)
  }

  func testWorktreeSelectorRefreshesListWhenOpened() async throws {
    let directory = try makeTestDirectory()
    let repository = directory.appendingPathComponent("Repo", isDirectory: true)
    try initializeRepository(at: repository)
    try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
    try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
    try "main\n".write(
      to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    try runGit(at: repository, arguments: ["add", "-A"])
    try runGit(at: repository, arguments: ["commit", "-m", "main commit"])
    let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
    await coordinator.addStandaloneRepository(repository)
    let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
    let descriptor = try XCTUnwrap(coordinator.repositories.first)
    coordinator.setMode(.changes)
    coordinator.selectRepository(repositoryID)
    let selector = ChangesWorktreeSelectorController(coordinator: coordinator)
    selector.reload(repository: descriptor)
    try await waitUntil(description: "main worktree loaded") {
      selector.button.itemArray.count == 1 && selector.button.isEnabled
    }

    let worktreeURL = directory.appendingPathComponent("Feature Worktree", isDirectory: true)
    try runGit(at: repository, arguments: ["worktree", "add", "-b", "feature", worktreeURL.path])
    let menu = try XCTUnwrap(selector.button.menu)
    XCTAssertTrue(menu.delegate === selector)
    let originalItem = try XCTUnwrap(menu.items.first)
    menu.delegate?.menuNeedsUpdate?(menu)
    menu.delegate?.menuWillOpen?(menu)
    XCTAssertTrue(menu.items.first === originalItem)
    menu.delegate?.menuDidClose?(menu)
    try await waitUntil(description: "worktree list refreshed on menu open") {
      selector.button.itemArray.count == 2
        && selector.button.itemArray.contains { $0.title == "Feature Worktree" }
    }
  }

  func testWorktreeSelectorCanRetryAfterModeSwitchDuringScan() async throws {
    let directory = try makeTestDirectory()
    let repository = directory.appendingPathComponent("Repo", isDirectory: true)
    try initializeRepository(at: repository)
    try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
    try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
    try "main\n".write(
      to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    try runGit(at: repository, arguments: ["add", "-A"])
    try runGit(at: repository, arguments: ["commit", "-m", "main commit"])
    let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
    await coordinator.addStandaloneRepository(repository)
    let repositoryDescriptor = try XCTUnwrap(coordinator.repositories.first)
    coordinator.setMode(.changes)
    coordinator.selectRepository(repositoryDescriptor.id)
    let selector = ChangesWorktreeSelectorController(coordinator: coordinator)
    selector.reload(repository: repositoryDescriptor)
    coordinator.setMode(.history)
    try await waitUntil(description: "stale worktree result releases selector loading state") {
      selector.button.itemArray.count == 1 && selector.button.isEnabled
    }

    let worktreeURL = directory.appendingPathComponent("Feature Worktree", isDirectory: true)
    try runGit(at: repository, arguments: ["worktree", "add", "-b", "feature", worktreeURL.path])
    coordinator.setMode(.changes)
    selector.reload(repository: repositoryDescriptor)
    let menu = try XCTUnwrap(selector.button.menu)
    menu.delegate?.menuWillOpen?(menu)
    menu.delegate?.menuDidClose?(menu)
    try await waitUntil(description: "menu retries after scan completes in other mode") {
      selector.button.itemArray.count == 2
        && selector.button.itemArray.contains { $0.title == "Feature Worktree" }
    }
  }

  func testWorktreeSelectorRetriesAfterInitialScanFailure() async throws {
    let fixture = try makeLinkedWorktreeFixture()
    let coordinator = makeCoordinator(
      stateFile: fixture.directory.appendingPathComponent("state.json")
    )
    await coordinator.addStandaloneRepository(fixture.repository)
    let mainRepository = try XCTUnwrap(coordinator.repositories.first)
    coordinator.setMode(.changes)
    coordinator.selectRepository(mainRepository.id)
    try await waitUntil(description: "main repository status") {
      coordinator.repositoryRefreshStates[mainRepository.id]?.phase == .idle
        && coordinator.repositoryRefreshStates[mainRepository.id]?.status != nil
    }

    let gitDirectory = fixture.repository.appendingPathComponent(".git", isDirectory: true)
    let backupGitDirectory = fixture.directory.appendingPathComponent("git-backup", isDirectory: true)
    try FileManager.default.moveItem(at: gitDirectory, to: backupGitDirectory)
    try "gitdir: \(fixture.directory.appendingPathComponent("missing-git-dir").path)\n".write(
      to: gitDirectory, atomically: true, encoding: .utf8)
    defer {
      if FileManager.default.fileExists(atPath: backupGitDirectory.path) {
        if FileManager.default.fileExists(atPath: gitDirectory.path) {
          try? FileManager.default.removeItem(at: gitDirectory)
        }
        try? FileManager.default.moveItem(at: backupGitDirectory, to: gitDirectory)
      }
    }
    XCTAssertThrowsError(try runGit(at: fixture.repository, arguments: ["worktree", "list"]))
    let selector = ChangesWorktreeSelectorController(coordinator: coordinator)
    selector.reload(repository: mainRepository)
    try await waitUntil(description: "failed worktree scan remains retryable") {
      selector.button.title == "Retry Worktree Scan" && selector.button.isEnabled
    }

    try FileManager.default.removeItem(at: gitDirectory)
    try FileManager.default.moveItem(at: backupGitDirectory, to: gitDirectory)
    let menu = try XCTUnwrap(selector.button.menu)
    menu.delegate?.menuNeedsUpdate?(menu)
    menu.delegate?.menuWillOpen?(menu)
    menu.delegate?.menuDidClose?(menu)
    try await waitUntil(description: "worktree scan recovers after repository restoration") {
      selector.button.itemArray.count == 2
        && selector.button.itemArray.contains { $0.title == "Feature Worktree" }
    }
  }
  func testSidebarHighlightDoesNotSelectMainForLinkedWorktree() async throws {
    let fixture = try makeLinkedWorktreeFixture()
    let coordinator = makeCoordinator(
      stateFile: fixture.directory.appendingPathComponent("state.json")
    )
    await coordinator.addStandaloneRepository(fixture.repository)
    let mainRepositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
    await coordinator.addStandaloneRepository(fixture.worktreeURL)
    let linkedRepositoryID = try XCTUnwrap(
      coordinator.repositories.first {
        $0.canonicalURL.standardizedFileURL == fixture.worktreeURL.standardizedFileURL
      }?.id
    )
    coordinator.setMode(.changes)
    coordinator.selectRepository(linkedRepositoryID)

    let sidebar = RepoSidebarViewController(coordinator: coordinator)
    sidebar.loadView()
    XCTAssertEqual(coordinator.state.uiState.selectedRepoID, linkedRepositoryID)
    XCTAssertEqual(
      sidebar.repositoryIDs(in: sidebar.outlineView.selectedRowIndexes),
      [mainRepositoryID]
    )
    coordinator.setSearchText("Feature Worktree")
    let searchSnapshot = coordinator.snapshot
    sidebar.reload(searchSnapshot)
    XCTAssertEqual(
      sidebar.repositoryIDs(in: sidebar.outlineView.selectedRowIndexes),
      [linkedRepositoryID]
    )
    XCTAssertEqual(
      sidebar.sidebarSelectionRepositoryID(for: mainRepositoryID, snapshot: searchSnapshot),
      linkedRepositoryID
    )

  }

  func testLinkedOnlyStandaloneHasVisibleSidebarRepresentative() throws {
    let fixture = try makeLinkedWorktreeFixture()
    let directory = fixture.directory
    let repositoryID = UUID()
    let repositoryURL = fixture.worktreeURL
    let repository = RepoDescriptor(
      id: repositoryID,
      source: .standalone(id: repositoryID),
      url: repositoryURL,
      canonicalURL: repositoryURL,
      resourceID: nil,
      relativePath: nil,
      availability: .available,
      gitDirectoryInfo: GitDirectoryInfo.read(at: repositoryURL)
    )
    let coordinator = AppCoordinator(
      stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
      repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
    )
    addTeardownBlock { _ = await coordinator.shutdown() }
    let sidebar = RepoSidebarViewController(coordinator: coordinator)
    sidebar.loadView()

    XCTAssertNotNil(sidebar.repositoryNodesByID[repositoryID])
    XCTAssertTrue(sidebar.emptyLabel.isHidden)
    XCTAssertEqual(
      sidebar.sidebarSelectionRepositoryID(for: repositoryID, snapshot: coordinator.snapshot),
      repositoryID
    )
    let row = try XCTUnwrap(sidebar.row(for: repositoryID))
    sidebar.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    sidebar.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
    XCTAssertEqual(coordinator.state.uiState.selectedRepoID, repositoryID)
  }

  func testHistoryBranchPickerRefreshesExternalRefsWhenOpened() async throws {
    let directory = try makeTestDirectory()
    let repository = directory.appendingPathComponent("Repo", isDirectory: true)
    try initializeRepository(at: repository)
    try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
    try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
    try "main\n".write(
      to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    try runGit(at: repository, arguments: ["add", "-A"])
    try runGit(at: repository, arguments: ["commit", "-m", "initial commit"])
    try runGit(at: repository, arguments: ["branch", "external-feature"])
    try "second\n".write(
      to: repository.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
    try runGit(at: repository, arguments: ["add", "-A"])
    try runGit(at: repository, arguments: ["commit", "-m", "main second commit"])
    let headBefore = try runGit(at: repository, arguments: ["rev-parse", "HEAD"]).standardOutputText
    let oldFeatureTip = try runGit(
      at: repository,
      arguments: ["rev-parse", "refs/heads/external-feature"]
    ).standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
    let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
    await coordinator.addStandaloneRepository(repository)
    let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
    coordinator.setMode(.history)
    coordinator.selectRepository(repositoryID)
    try await waitUntil(description: "initial history branch loaded") {
      coordinator.selectedHistoryState.branches.contains { $0.refName == "refs/heads/main" }
        && coordinator.selectedHistoryState.phase == .idle
    }

    let historyController = HistoryViewController(coordinator: coordinator)
    let rootView = historyController.view
    historyController.reload(coordinator.snapshot)
    func findHeader(in view: NSView) -> HistoryHeaderView? {
      if let header = view as? HistoryHeaderView { return header }
      for subview in view.subviews {
        if let header = findHeader(in: subview) { return header }
      }
      return nil
    }
    let header = try XCTUnwrap(findHeader(in: rootView))
    let menu = try XCTUnwrap(header.branchControl.menu)
    XCTAssertTrue(menu.delegate === header)
    menu.delegate?.menuWillOpen?(menu)
    try await waitUntil(description: "external branch appears after opening picker") {
      coordinator.selectedHistoryState.branches.contains {
        $0.refName == "refs/heads/external-feature"
      }
    }
    historyController.reload(coordinator.snapshot)
    XCTAssertTrue(header.branchControl.itemArray.contains {
      ($0.representedObject as? String) == "refs/heads/external-feature"
    })

    coordinator.setHistoryBranch("refs/heads/external-feature")
    try await waitUntil(description: "external branch history initially loaded") {
      coordinator.selectedHistoryState.selectedBranchRef == "refs/heads/external-feature"
        && coordinator.selectedHistoryState.tips?.localObjectID == oldFeatureTip
        && coordinator.selectedHistoryState.commits.first?.subject == "initial commit"
        && coordinator.selectedHistoryState.phase == .idle
    }
    historyController.reload(coordinator.snapshot)
    try runGit(at: repository, arguments: ["branch", "-f", "external-feature", "HEAD"])
    menu.delegate?.menuWillOpen?(menu)
    let advancedFeatureTip = headBefore.trimmingCharacters(in: .whitespacesAndNewlines)
    try await waitUntil(description: "selected branch history refreshes to advanced tip") {
      coordinator.selectedHistoryState.tips?.localObjectID == advancedFeatureTip
        && coordinator.selectedHistoryState.commits.first?.subject == "main second commit"
        && coordinator.selectedHistoryState.phase == .idle
    }
    historyController.reload(coordinator.snapshot)
    header.contentControl.selectedSegment = 1
    header.onContentSelection?(true)
    try await waitUntil(description: "branch file view follows refreshed tip") {
      historyController.branchFilePresentation.commitObjectID == advancedFeatureTip
        && historyController.branchFilePresentation.state == .noSelection
    }
    let branchFileBrowser = try XCTUnwrap(
      historyController.children.compactMap { $0 as? BranchFileBrowserViewController }.first
    )
    try await waitUntil(description: "branch file tree follows advanced tip") {
      branchFileBrowser.fileCount == 2
    }

    XCTAssertEqual(
      try runGit(at: repository, arguments: ["rev-parse", "HEAD"]).standardOutputText,
      headBefore
    )
  }

  private func makeWorktreeSelector(
    _ coordinator: AppCoordinator,
    worktreeURL: URL
  ) async throws -> ChangesWorktreeSelectorController {
    let worktreeRepository = try XCTUnwrap(
      coordinator.repositories.first { $0.id == coordinator.state.uiState.selectedRepoID }
    )
    XCTAssertTrue(worktreeRepository.isLinkedWorktree)
    XCTAssertEqual(worktreeRepository.displayName, "Repo (Feature Worktree)")
    let sidebar = RepoSidebarViewController(coordinator: coordinator)
    let worktreeIsInSidebar = sidebar.makeNodes(coordinator.snapshot).contains { node in
      if case .repository(let id) = node.kind { return id == worktreeRepository.id }
      return false
    }
    XCTAssertFalse(worktreeIsInSidebar)
    let selector = ChangesWorktreeSelectorController(coordinator: coordinator)
    selector.reload(repository: worktreeRepository)
    try await waitUntil(description: "worktree switcher loaded") {
      selector.button.itemArray.count == 2 && selector.button.isEnabled
    }
    XCTAssertEqual(selector.button.title, "Feature Worktree")
    XCTAssertTrue(selector.button.itemArray.contains { $0.title == "main" })
    let firstMenuItem = try XCTUnwrap(selector.button.itemArray.first)
    selector.reload(repository: worktreeRepository)
    XCTAssertTrue(selector.button.itemArray.first === firstMenuItem)
    return selector
  }
  private struct LinkedWorktreeFixture {
    let directory: URL
    let repository: URL
    let worktreeURL: URL
    let mainHead: String
  }

  private func makeLinkedWorktreeFixture() throws -> LinkedWorktreeFixture {
    let directory = try makeTestDirectory()
    let repository = directory.appendingPathComponent("Repo", isDirectory: true)
    try initializeRepository(at: repository)
    try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
    try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
    try "main\n".write(
      to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    try runGit(at: repository, arguments: ["add", "-A"])
    try runGit(at: repository, arguments: ["commit", "-m", "main commit"])
    let mainHead = try runGit(at: repository, arguments: ["rev-parse", "HEAD"]).standardOutputText
    try runGit(at: repository, arguments: ["checkout", "-b", "feature"])
    try "feature\n".write(
      to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    try runGit(at: repository, arguments: ["add", "-A"])
    try runGit(at: repository, arguments: ["commit", "-m", "feature commit"])
    try runGit(at: repository, arguments: ["checkout", "main"])
    let worktreeURL = directory.appendingPathComponent("Feature Worktree", isDirectory: true)
    try runGit(at: repository, arguments: ["worktree", "add", worktreeURL.path, "feature"])
    addTeardownBlock {
      _ = try? runGit(at: repository, arguments: ["worktree", "remove", "--force", worktreeURL.path])
    }
    try "dirty in linked worktree\n".write(
      to: worktreeURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    return LinkedWorktreeFixture(
      directory: directory,
      repository: repository,
      worktreeURL: worktreeURL,
      mainHead: mainHead
    )
  }
  private func switchChangesWorktrees(
    coordinator: AppCoordinator,
    selector: ChangesWorktreeSelectorController,
    repositoryURL: URL,
    worktreeURL: URL
  ) async throws {
    try activateWorktree(named: "main", using: selector)
    try await waitUntil(description: "Changes switched to the main worktree") {
      coordinator.repositories.first { $0.id == coordinator.state.uiState.selectedRepoID }?
        .canonicalURL.standardizedFileURL == repositoryURL.standardizedFileURL
    }
    let mainRepository = try XCTUnwrap(
      coordinator.repositories.first {
        $0.canonicalURL.standardizedFileURL == repositoryURL.standardizedFileURL
      }
    )
    selector.reload(repository: mainRepository)
    try await waitUntil(description: "main worktree selector reloaded") {
      selector.button.itemArray.count == 2 && selector.button.isEnabled
    }
    try activateWorktree(named: "Feature Worktree", using: selector)
    try await waitUntil(description: "Changes switched back to linked worktree") {
      coordinator.repositories.first { $0.id == coordinator.state.uiState.selectedRepoID }?
        .canonicalURL.standardizedFileURL == worktreeURL.standardizedFileURL
    }
  }

  private func activateWorktree(
    named title: String,
    using selector: ChangesWorktreeSelectorController
  ) throws {
    let index = try XCTUnwrap(selector.button.itemArray.firstIndex { $0.title == title })
    selector.button.selectItem(at: index)
    let action = try XCTUnwrap(selector.button.action)
    XCTAssertTrue(NSApplication.shared.sendAction(action, to: selector.button.target, from: selector.button))
  }
}
