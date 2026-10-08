import AppKit

private struct WorktreeMenuData {
  let worktrees: [GitWorktree]
  let mainRepositoryURL: URL
}

@MainActor
final class ChangesWorktreeSelectorController: NSObject, NSMenuDelegate {
  let button = NSPopUpButton(frame: .zero, pullsDown: false)

  private let coordinator: AppCoordinator
  private var currentRepository: RepoDescriptor?
  private var worktreeMenuData: WorktreeMenuData?
  private var worktrees: [GitWorktree] { worktreeMenuData?.worktrees ?? [] }
  private var isLoading = false
  private var isSwitching = false
  private var loadGeneration: UInt64 = 0
  private var loadTask: Task<Void, Never>?
  private var selectionTask: Task<Void, Never>?
  private var loadFailure: String?
  private var pendingWorktreeURL: URL?
  private var isMenuOpen = false
  private var needsMenuUpdate = false
  private var pendingWorktreeMenuData: WorktreeMenuData?

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init()
    button.target = self
    button.action = #selector(worktreeSelected(_:))
    button.menu?.delegate = self
    button.setAccessibilityLabel("Switch repository worktree")
    button.toolTip = "Changes and staging stay in the selected worktree."
    button.controlSize = .small
  }

  deinit {
    MainActor.assumeIsolated {
      loadTask?.cancel()
      selectionTask?.cancel()
    }
  }

  func clear() {
    loadGeneration &+= 1
    loadTask?.cancel()
    selectionTask?.cancel()
    loadTask = nil
    selectionTask = nil
    currentRepository = nil
    worktreeMenuData = nil
    pendingWorktreeMenuData = nil
    isLoading = false
    isSwitching = false
    pendingWorktreeURL = nil
    loadFailure = nil
    button.isEnabled = false
    button.toolTip = ""
    refreshMenu()
  }

  func reload(repository: RepoDescriptor) {
    guard repository.availability == .available else {
      clear()
      return
    }
    if currentRepository?.id == repository.id,
       currentRepository?.canonicalURL == repository.canonicalURL {
      guard currentRepository?.gitDirectoryInfo != repository.gitDirectoryInfo
        || currentRepository?.mainRepositoryURL != repository.mainRepositoryURL
        || currentRepository?.displayName != repository.displayName else { return }
      currentRepository = repository
      refreshMenu()
      return
    }
    selectionTask?.cancel()
    selectionTask = nil
    isSwitching = false
    pendingWorktreeURL = nil
    pendingWorktreeMenuData = nil
    currentRepository = repository
    worktreeMenuData = nil
    loadFailure = nil
    loadWorktrees(repository: repository)
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    applyPendingMenuUpdate()
  }

  func menuWillOpen(_ menu: NSMenu) {
    isMenuOpen = true
    guard !isLoading, !isSwitching, loadTask == nil, let currentRepository else { return }
    loadFailure = nil
    loadWorktrees(repository: currentRepository, preservingCachedWorktrees: true)
  }

  func menuDidClose(_ menu: NSMenu) {
    isMenuOpen = false
    guard needsMenuUpdate || pendingWorktreeMenuData != nil else { return }
    DispatchQueue.main.async { [weak self] in self?.applyPendingMenuUpdate() }
  }

  private func loadWorktrees(
    repository: RepoDescriptor,
    preservingCachedWorktrees: Bool = false
  ) {
    loadGeneration &+= 1
    loadTask?.cancel()
    isLoading = true
    if !preservingCachedWorktrees { refreshMenu() }
    let generation = loadGeneration
    let repositoryID = repository.id
    let gitService = coordinator.gitService
    let repositoryScanner = RepoScanner()
    loadTask = Task { [weak self, gitService, repositoryScanner] in
      do {
        let worktrees = try await Self.resolvedWorktrees(
          for: repository,
          using: gitService,
          scanner: repositoryScanner
        )
        try Task.checkCancellation()
        guard let self, loadGeneration == generation else { return }
        isLoading = false
        loadTask = nil
        let latestRepository = coordinator.repositories.first { $0.id == repositoryID }
        guard coordinator.state.uiState.selectedRepoID == repositoryID,
              currentRepository?.id == repositoryID,
              currentRepository?.canonicalURL.standardizedFileURL
                == repository.canonicalURL.standardizedFileURL,
              latestRepository?.canonicalURL.standardizedFileURL
                == repository.canonicalURL.standardizedFileURL else {
          refreshMenu()
          return
        }
        pendingWorktreeMenuData = worktrees
        loadFailure = nil
        refreshMenu()
      } catch {
        guard !Task.isCancelled,
              let self,
              loadGeneration == generation,
              coordinator.state.uiState.selectedRepoID == repositoryID else { return }
        isLoading = false
        loadFailure = error.localizedDescription
        loadTask = nil
        refreshMenu()
      }
    }
  }

  private static func resolvedWorktrees(
    for repository: RepoDescriptor,
    using gitService: GitService,
    scanner: RepoScanner
  ) async throws -> WorktreeMenuData {
    let listedWorktrees = try await gitService.worktrees(repository: repository.canonicalURL)
    var worktrees: [GitWorktree] = []
    var listedMainURL: URL?
    for worktree in listedWorktrees {
      try Task.checkCancellation()
      guard let gitDirectoryInfo = await scanner.gitDirectoryInfo(at: worktree.path) else { continue }
      worktrees.append(worktree)
      if !gitDirectoryInfo.isLinkedWorktree { listedMainURL = worktree.path }
    }
    let mainRepositoryURL = repository.mainRepositoryURL
      ?? (repository.isLinkedWorktree ? nil : repository.canonicalURL)
    if let mainRepositoryURL,
      !worktrees.contains(where: {
        $0.path.standardizedFileURL == mainRepositoryURL.standardizedFileURL
      }) {
      let branches = try? await gitService.branchReferences(repository: mainRepositoryURL)
      let branchReference = branches?.first(where: \.isCurrent)?.refName
      worktrees.insert(GitWorktree(path: mainRepositoryURL, branchReference: branchReference), at: 0)
    }
    return WorktreeMenuData(
      worktrees: worktrees,
      mainRepositoryURL: mainRepositoryURL ?? listedMainURL ?? repository.canonicalURL
    )
  }
  private func refreshMenu() {
    needsMenuUpdate = true
    applyPendingMenuUpdate()
  }

  private func applyPendingMenuUpdate() {
    guard !isMenuOpen, needsMenuUpdate || pendingWorktreeMenuData != nil else { return }
    needsMenuUpdate = false
    if let pendingWorktreeMenuData {
      worktreeMenuData = pendingWorktreeMenuData
      self.pendingWorktreeMenuData = nil
    }
    updateMenu()
  }
  private func updateMenu() {
    button.removeAllItems()
    guard let currentRepository else {
      button.addItem(withTitle: "Worktrees")
      button.isEnabled = false
      return
    }
    let mainURL = (
      currentRepository.mainRepositoryURL
        ?? worktreeMenuData?.mainRepositoryURL
        ?? currentRepository.canonicalURL
    ).standardizedFileURL
    let linkedWorktrees = worktrees.filter { $0.path.standardizedFileURL != mainURL }
    let duplicateNames = Dictionary(grouping: linkedWorktrees, by: { $0.path.lastPathComponent })
    let orderedWorktrees = worktrees.sorted { left, right in
      let leftIsMain = left.path.standardizedFileURL == mainURL
      let rightIsMain = right.path.standardizedFileURL == mainURL
      if leftIsMain != rightIsMain { return leftIsMain }
      return left.path.path.localizedStandardCompare(right.path.path) == .orderedAscending
    }
    for worktree in orderedWorktrees {
      let isMainWorktree = worktree.path.standardizedFileURL == mainURL
      var title = isMainWorktree ? (worktree.branchName ?? "main") : worktree.path.lastPathComponent
      if !isMainWorktree,
         duplicateNames[title]?.count ?? 0 > 1,
         let branchName = worktree.branchName {
        title += " (\(branchName))"
      }
      button.addItem(withTitle: title)
      button.lastItem?.representedObject = worktree.path
    }
    if worktrees.isEmpty {
      button.addItem(
        withTitle: loadFailure == nil ? currentRepository.displayName : "Retry Worktree Scan")
      button.lastItem?.representedObject = currentRepository.canonicalURL
    }
    let selectedURL = (pendingWorktreeURL ?? currentRepository.canonicalURL).standardizedFileURL
    if let selectedIndex = button.itemArray.firstIndex(where: {
      ($0.representedObject as? URL)?.standardizedFileURL == selectedURL
    }) {
      button.selectItem(at: selectedIndex)
    }
    button.isEnabled = !isLoading && !isSwitching && (!worktrees.isEmpty || loadFailure != nil)
    button.toolTip = loadFailure ?? "Switch worktrees. Changes stay in the selected worktree."
  }

  @objc private func worktreeSelected(_ sender: NSPopUpButton) {
    guard !isLoading,
          !isSwitching,
          !needsMenuUpdate,
          pendingWorktreeMenuData == nil,
          let currentRepository,
          let worktreeURL = sender.selectedItem?.representedObject as? URL,
          worktreeURL.standardizedFileURL != currentRepository.canonicalURL.standardizedFileURL else { return }
    isSwitching = true
    pendingWorktreeURL = worktreeURL
    button.isEnabled = false
    let repositoryID = currentRepository.id
    let repositoryURL = currentRepository.canonicalURL
    let coordinator = self.coordinator
    selectionTask = Task { [weak self, coordinator] in
      await coordinator.switchChangesWorktree(
        worktreeURL,
        from: repositoryID,
        sourceRepositoryURL: repositoryURL
      )
      guard !Task.isCancelled, let self else { return }
      isSwitching = false
      pendingWorktreeURL = nil
      selectionTask = nil
      refreshMenu()
    }
  }

}
