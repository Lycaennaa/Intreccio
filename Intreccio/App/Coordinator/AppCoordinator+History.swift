import Foundation

private struct HistoryRequestIdentity: Sendable {
  let repositoryID: UUID
  let repositoryURL: URL
  let historyGeneration: UInt64
  let branchRef: String?
}

private struct HistoryPageRequest {
  let generation: UInt64
  let identity: HistoryRequestIdentity
  let skip: Int
  let requestedScope: HistoryScope
  let scope: HistoryScope
  let knownTips: HistoryTips?
}

private enum HistoryPageFetchResult {
  case branchMissing([GitBranchReference])
  case loaded(
    branches: [GitBranchReference]?,
    tips: HistoryTips,
    currentTips: HistoryTips?,
    page: HistoryMetadataPage
  )
}

private struct SelectedCommitRequest {
  let commit: Commit
  let generation: UInt64
  let identity: HistoryRequestIdentity
  let tips: HistoryTips?
}
@MainActor
extension AppCoordinator {
  func refreshSelectedRepository() {
    guard let repositoryID = state.uiState.selectedRepoID else { return }
    refetchUpstream(for: repositoryID)
  }

  var filteredHistoryCommits: [Commit] {
    selectedHistoryState.filteredCommits(searchText: state.uiState.searchText)
  }

  func setHistoryScope(_ scope: HistoryScope) {
    guard !isShuttingDown, historyScope != scope else { return }
    historyScope = scope
    clearSelectedHistory()
    loadNextHistoryPage()
    publish()
  }
  func setHistoryBranch(_ branchRef: String?) {
    let isKnownBranch = selectedHistoryState.branches.contains { $0.refName == branchRef }
    guard !isShuttingDown,
      selectedHistoryState.selectedBranchRef != branchRef,
      branchRef == nil || isKnownBranch
    else { return }
    let branches = selectedHistoryState.branches
    selectedHistoryState.selectedBranchRef = branchRef
    clearSelectedHistory()
    selectedHistoryState.branches = branches
    loadNextHistoryPage()
    publish()
  }
  func refreshHistoryBranches() async {
    guard !isShuttingDown,
      state.uiState.mode == .history,
      let repositoryID = state.uiState.selectedRepoID,
      let repository = repositories.first(where: { $0.id == repositoryID }),
      repository.availability == .available
    else { return }
    let identity = HistoryRequestIdentity(
      repositoryID: repositoryID,
      repositoryURL: repository.canonicalURL,
      historyGeneration: runtime.historyGeneration(for: repositoryID),
      branchRef: selectedHistoryState.selectedBranchRef
    )
    do {
      let branches = try await gitService.branchReferences(repository: identity.repositoryURL)
      try Task.checkCancellation()
      guard isCurrentHistoryRequestIdentity(identity), repositoryPathMatches(identity) else { return }
      let selectedBranch = identity.branchRef.flatMap { branchRef in
        branches.first { $0.refName == branchRef }
      }
      let selectedTips: HistoryTips?
      if let branchRef = identity.branchRef {
        selectedTips = try await gitService.historyTips(
          repository: identity.repositoryURL,
          branchReference: branchRef
        )
      } else {
        selectedTips = try await gitService.historyTips(repository: identity.repositoryURL)
      }
      try Task.checkCancellation()
      guard isCurrentHistoryRequestIdentity(identity), repositoryPathMatches(identity) else { return }
      let branchTipsChanged: Bool
      if let selectedTips, let loadedTips = selectedHistoryState.tips {
        branchTipsChanged = selectedTips != loadedTips
      } else {
        branchTipsChanged = selectedHistoryState.tips == nil && selectedSession.hasHistoryTask
      }
      if identity.branchRef != nil, selectedBranch == nil || selectedTips == nil {
        clearSelectedHistory(preservingBranchSelection: false)
        selectedHistoryState.branches = branches
        loadNextHistoryPage()
      } else if branchTipsChanged {
        clearSelectedHistory()
        selectedHistoryState.branches = branches
        loadNextHistoryPage()
      } else {
        selectedHistoryState.branches = branches
        publish()
      }
    } catch is CancellationError {
    } catch ProcessRunnerError.cancelled {
    } catch {
    }
  }

  func retryHistoryPage() {
    guard case .failed = selectedHistoryState.phase else { return }
    selectedHistoryState.phase = .idle
    loadNextHistoryPage()
  }

  func loadNextHistoryPage() {
    if case .failed = selectedHistoryState.phase { return }

    guard !isShuttingDown,
      !selectedSession.hasHistoryTask,
      state.uiState.mode == .history,
      let repositoryID = state.uiState.selectedRepoID,
      let repository = repositories.first(where: { $0.id == repositoryID }),
      repository.availability == .available,
      !selectedHistoryState.reachedEnd,
      !selectedHistoryState.reachedLimit
    else { return }

    let requestGeneration = selectedSession.beginHistoryTask()
    let branchRef = selectedHistoryState.selectedBranchRef
    let request = HistoryPageRequest(
      generation: requestGeneration,
      identity: HistoryRequestIdentity(
        repositoryID: repositoryID,
        repositoryURL: repository.canonicalURL,
        historyGeneration: runtime.historyGeneration(for: repositoryID),
        branchRef: branchRef
      ),
      skip: selectedHistoryState.commits.count,
      requestedScope: historyScope,
      scope: branchRef == nil ? historyScope : .mixed,
      knownTips: selectedHistoryState.tips
    )
    selectedHistoryState.phase = .loading
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performHistoryPageLoad(request)
    }
    selectedSession.installHistoryTask(task, generation: requestGeneration)
    publish()
  }

  private func performHistoryPageLoad(_ request: HistoryPageRequest) async {
    do {
      let branches = try await fetchHistoryBranches(for: request)
      let result = try await fetchHistoryPage(request, branches: branches)
      try Task.checkCancellation()
      guard isCurrentHistoryPageRequest(request) else {
        _ = restartHistoryPageIfRepositoryPathChanged(request)
        return
      }
      switch result {
      case .branchMissing(let branches):
        selectedHistoryState.branches = branches
        selectedHistoryState.selectedBranchRef = nil
        restartHistoryPage(request, invalidateRuntime: false)
      case .loaded(let branches, let tips, let currentTips, let page):
        guard currentTips == tips else {
          restartHistoryPage(request, invalidateRuntime: request.identity.branchRef == nil)
          return
        }
        if selectedHistoryState.branches.isEmpty, let branches { selectedHistoryState.branches = branches }
        selectedHistoryState.scope = request.scope
        selectedHistoryState.tips = tips
        applyHistoryPage(page, skip: request.skip)
        selectedHistoryState.phase = .idle
        selectedSession.finishHistoryTask(generation: request.generation)
        publish()
      }
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled else { return }
      guard isCurrentHistoryPageRequest(request) else {
        _ = restartHistoryPageIfRepositoryPathChanged(request)
        return
      }
      selectedHistoryState.phase = .failed(.git(error, title: "Could not load history"))
      selectedSession.finishHistoryTask(generation: request.generation)
      publish()
    }
  }

  private func fetchHistoryPage(
    _ request: HistoryPageRequest,
    branches: [GitBranchReference]?
  ) async throws -> HistoryPageFetchResult {
    if let branchRef = request.identity.branchRef,
      let branches,
      !branches.contains(where: { $0.refName == branchRef }) {
      return .branchMissing(branches)
    }
    let tips: HistoryTips
    if let knownTips = request.knownTips {
      tips = knownTips
    } else if let branchRef = request.identity.branchRef {
      guard let branchTips = try await gitService.historyTips(
        repository: request.identity.repositoryURL,
        branchReference: branchRef
      ) else {
        let availableBranches =
          branches ?? selectedHistoryState.branches.filter { $0.refName != branchRef }
        return .branchMissing(availableBranches)
      }
      tips = branchTips
    } else {
      tips = try await gitService.historyTips(repository: request.identity.repositoryURL)
    }
    let page = try await gitService.historyPage(
      repository: request.identity.repositoryURL,
      scope: request.scope,
      tips: tips,
      skip: request.skip
    )
    let currentTips = try await currentHistoryTips(
      repository: request.identity.repositoryURL,
      branchReference: request.identity.branchRef
    )
    return .loaded(branches: branches, tips: tips, currentTips: currentTips, page: page)
  }

  private func fetchHistoryBranches(for request: HistoryPageRequest) async throws
    -> [GitBranchReference]? {
    guard request.identity.branchRef != nil || request.knownTips == nil else { return nil }
    do {
      return try await gitService.branchReferences(repository: request.identity.repositoryURL)
    } catch is CancellationError {
      throw CancellationError()
    } catch ProcessRunnerError.cancelled {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      return nil
    }
  }

  private func currentHistoryTips(repository: URL, branchReference: String?) async throws
    -> HistoryTips? {
    if let branchReference {
      return try await gitService.historyTips(
        repository: repository, branchReference: branchReference)
    }
    return try await gitService.historyTips(repository: repository)
  }

  private func isCurrentHistoryPageRequest(_ request: HistoryPageRequest) -> Bool {
    isCurrentHistoryPageIdentity(request) && repositoryPathMatches(request.identity)
  }

  private func isCurrentHistoryPageIdentity(_ request: HistoryPageRequest) -> Bool {
    selectedSession.isCurrentHistory(request.generation)
      && historyScope == request.requestedScope
      && isCurrentHistoryRequestIdentity(request.identity)
  }

  private func isCurrentHistoryRequestIdentity(_ identity: HistoryRequestIdentity) -> Bool {
    !isShuttingDown
      && state.uiState.mode == .history
      && state.uiState.selectedRepoID == identity.repositoryID
      && selectedHistoryState.selectedBranchRef == identity.branchRef
      && runtime.historyGeneration(for: identity.repositoryID) == identity.historyGeneration
  }

  private func repositoryPathMatches(_ identity: HistoryRequestIdentity) -> Bool {
    repositories.first(where: { $0.id == identity.repositoryID })?.canonicalURL.standardizedFileURL
      == identity.repositoryURL.standardizedFileURL
  }

  private func restartHistoryPageIfRepositoryPathChanged(_ request: HistoryPageRequest) -> Bool {
    guard isCurrentHistoryPageIdentity(request) else { return false }
    guard let repository = repositories.first(where: { $0.id == request.identity.repositoryID }) else {
      selectedSession.finishHistoryTask(generation: request.generation)
      clearSelectedHistory()
      publish()
      return true
    }
    guard repository.canonicalURL.standardizedFileURL != request.identity.repositoryURL.standardizedFileURL
    else { return false }
    restartHistoryPage(request, invalidateRuntime: false)
    return true
  }

  private func restartHistoryPage(_ request: HistoryPageRequest, invalidateRuntime: Bool) {
    if invalidateRuntime {
      _ = runtime.invalidateHistory(for: [request.identity.repositoryID])
    }
    selectedSession.finishHistoryTask(generation: request.generation)
    clearSelectedHistory()
    loadNextHistoryPage()
  }

  private func applyHistoryPage(_ page: HistoryMetadataPage, skip: Int) {
    selectedHistoryState.metadataCompleteness = page.completeness
    if let notOnUpstreamObjectIDs = page.notOnUpstreamObjectIDs {
      selectedHistoryState.notOnUpstreamObjectIDs =
        (selectedHistoryState.notOnUpstreamObjectIDs ?? []).union(notOnUpstreamObjectIDs)
    }
    if skip >= SelectedHistoryState.maximumLoadedCommits {
      selectedHistoryState.reachedEnd = page.completeness.isComplete && page.commits.isEmpty
      selectedHistoryState.reachedLimit = !page.commits.isEmpty || !page.completeness.isComplete
    } else {
      selectedHistoryState.commits.append(contentsOf: page.commits)
      selectedHistoryState.reachedEnd =
        page.completeness.isComplete
        && page.commits.count < GitService.historyPageSize
      if !page.completeness.isComplete { selectedHistoryState.reachedLimit = true }
    }
  }

  func selectCommit(_ commit: Commit?) {
    guard !isShuttingDown else { return }
    let generation = selectedSession.beginCommit()
    guard let commit,
      state.uiState.mode == .history,
      selectedHistoryState.commits.contains(where: { $0.objectID == commit.objectID }),
      let repositoryID = state.uiState.selectedRepoID,
      let repository = repositories.first(where: { $0.id == repositoryID }),
      repository.availability == .available
    else {
      selectedCommitState = .idle
      publish()
      return
    }
    let request = SelectedCommitRequest(
      commit: commit,
      generation: generation,
      identity: HistoryRequestIdentity(
        repositoryID: repositoryID,
        repositoryURL: repository.canonicalURL,
        historyGeneration: runtime.historyGeneration(for: repositoryID),
        branchRef: selectedHistoryState.selectedBranchRef
      ),
      tips: selectedHistoryState.tips
    )
    selectedCommitState = .loading(commit)
    publish()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.loadSelectedCommitDetails(request)
    }
    selectedSession.installCommitTask(task, generation: generation)
  }

  private func loadSelectedCommitDetails(_ request: SelectedCommitRequest) async {
    do {
      let details = try await gitService.show(
        repository: request.identity.repositoryURL, commit: request.commit)
      let currentTips = try await currentHistoryTips(
        repository: request.identity.repositoryURL,
        branchReference: request.identity.branchRef
      )
      try Task.checkCancellation()
      guard isCurrentSelectedCommitRequest(request) else {
        _ = restartSelectedCommitAfterRepositoryPathChange(request)
        return
      }
      if currentTips != request.tips {
        restartHistoryAfterStaleCommit(request)
        return
      }
      selectedCommitState = .loaded(details)
      selectedSession.finishCommitTask(generation: request.generation)
      publish()
    } catch ProcessRunnerError.cancelled {
      finishCancelledCommitLoad(generation: request.generation)
    } catch is CancellationError {
      finishCancelledCommitLoad(generation: request.generation)
    } catch {
      guard isCurrentSelectedCommitRequest(request) else {
        _ = restartSelectedCommitAfterRepositoryPathChange(request)
        return
      }
      selectedCommitState = .failed(request.commit, .git(error, title: "Could not load commit"))
      selectedSession.finishCommitTask(generation: request.generation)
      publish()
    }
  }

  private func isCurrentSelectedCommitRequest(_ request: SelectedCommitRequest) -> Bool {
    isCurrentSelectedCommitIdentity(request) && repositoryPathMatches(request.identity)
  }

  private func isCurrentSelectedCommitIdentity(_ request: SelectedCommitRequest) -> Bool {
    selectedSession.isCurrentCommit(request.generation)
      && isCurrentHistoryRequestIdentity(request.identity)
  }

  private func restartSelectedCommitAfterRepositoryPathChange(
    _ request: SelectedCommitRequest
  ) -> Bool {
    guard isCurrentSelectedCommitIdentity(request) else { return false }
    guard let repository = repositories.first(where: { $0.id == request.identity.repositoryID }) else {
      selectedSession.finishCommitTask(generation: request.generation)
      selectedCommitState = .idle
      publish()
      return true
    }
    guard repository.canonicalURL.standardizedFileURL != request.identity.repositoryURL.standardizedFileURL
    else { return false }
    guard let commit = selectedHistoryState.commits.first(where: {
      $0.objectID == request.commit.objectID
    }) else {
      restartHistoryAfterStaleCommit(request)
      return true
    }
    selectedSession.finishCommitTask(generation: request.generation)
    selectedCommitState = .idle
    selectCommit(commit)
    return true
  }

  private func restartHistoryAfterStaleCommit(_ request: SelectedCommitRequest) {
    if request.identity.branchRef == nil {
      _ = runtime.invalidateHistory(for: [request.identity.repositoryID])
    }
    clearSelectedHistory()
    loadNextHistoryPage()
    publish()
  }
  private func finishCancelledCommitLoad(generation: UInt64) {
    guard !isShuttingDown, selectedSession.isCurrentCommit(generation) else { return }
    selectedCommitState = .idle
    selectedSession.finishCommitTask(generation: generation)
    publish()
  }

  func clearSelectedHistory(preservingBranchSelection: Bool = true) {
    selectedSession.clearHistory(preservingBranchSelection: preservingBranchSelection)
  }

  func setCommitMessage(_ message: String) {
    commitMessage = message
    usesDefaultCommitMessage = false
    if case .failed = mutationState { mutationState = .idle }
    publish()
  }

  func beginAmending(_ commit: Commit) {
    guard !isShuttingDown,
      mutationTask == nil,
      state.uiState.mode == .history,
      let repositoryID = state.uiState.selectedRepoID,
      selectedHistoryState.selectedBranchRef == nil,
      selectedHistoryState.headObjectID == commit.objectID,
      selectedHistoryState.commits.contains(where: { $0.objectID == commit.objectID })
    else { return }
    guard commit.subjectMetadata.completeness.isComplete,
      commit.bodyMetadata.completeness.isComplete
    else { return }
    let body = commit.body.trimmingCharacters(in: .newlines)
    amendSession = AmendSession(
      repositoryID: repositoryID,
      commit: commit,
      previousMessage: commitMessage,
      previousUsesDefaultMessage: usesDefaultCommitMessage
    )
    commitMessage = body.isEmpty ? commit.subject : commit.subject + "\n\n" + body
    usesDefaultCommitMessage = false
    setMode(.changes)
  }

  func cancelAmendingCommit() {
    guard amendSession != nil else { return }
    restoreDraftBeforeAmend()
    if case .failed = mutationState { mutationState = .idle }
    publish()
  }

  func restoreDraftBeforeAmend() {
    guard let amendSession else { return }
    self.amendSession = nil
    commitMessage = amendSession.previousMessage
    usesDefaultCommitMessage = amendSession.previousUsesDefaultMessage
  }

  nonisolated static func defaultCommitMessage(for status: RepoStatus) -> String? {
    var seenPaths = Set<GitPath>()
    var stagedChanges: [FileChange] = []
    for change in status.changes where change.hasStagedChange {
      guard seenPaths.insert(change.gitPath).inserted else { continue }
      stagedChanges.append(change)
      if stagedChanges.count == 4 { return nil }
    }
    guard (1...3).contains(stagedChanges.count) else { return nil }

    let verb: String
    if stagedChanges.allSatisfy({ $0.indexState == .added || $0.indexState == .copied }) {
      verb = "Create"
    } else if stagedChanges.allSatisfy({ $0.indexState == .deleted }) {
      verb = "Delete"
    } else {
      verb = "Update"
    }

    func displayPath(for change: FileChange) -> String {
      guard change.isPathLossy == false else { return change.displayPath }
      return change.path.unicodeScalars.map { scalar in
        switch scalar.value {
        case 0x0A: "\\n"
        case 0x0D: "\\r"
        case 0x0B, 0x0C, 0x85, 0x2028, 0x2029:
          "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        default: String(scalar)
        }
      }.joined()
    }
    let paths = stagedChanges.map { displayPath(for: $0) }
    let fileList =
      switch paths.count {
      case 1: paths[0]
      case 2: "\(paths[0]) and \(paths[1])"
      default: "\(paths[0]), \(paths[1]) and \(paths[2])"
      }
    return "\(verb) \(fileList)"
  }

  func updateDefaultCommitMessage(for status: RepoStatus) {
    guard usesDefaultCommitMessage else { return }
    commitMessage = Self.defaultCommitMessage(for: status) ?? ""
  }

}
