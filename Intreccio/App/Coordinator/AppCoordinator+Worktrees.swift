import Foundation

@MainActor
extension AppCoordinator {
  func openLinkedWorktree(
    _ worktreeURL: URL,
    sourceRepositoryID: UUID,
    sourceRepositoryURL: URL,
    branchReference: String
  ) async {
    guard isCurrentWorktreeRequest(sourceRepositoryID, branchReference, sourceRepositoryURL) else {
      return
    }
    do {
      guard let repositoryID = try await repositoryID(forWorktreeAt: worktreeURL) else { return }
      try Task.checkCancellation()
      guard isCurrentWorktreeRequest(sourceRepositoryID, branchReference, sourceRepositoryURL) else {
        return
      }
      setMode(.changes)
      selectRepository(repositoryID)
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled,
        isCurrentWorktreeRequest(sourceRepositoryID, branchReference, sourceRepositoryURL)
      else { return }
      errorMessage = "Could not add linked worktree: \(error)"
      publish()
    }
  }

  func switchChangesWorktree(
    _ worktreeURL: URL,
    from sourceRepositoryID: UUID,
    sourceRepositoryURL: URL
  ) async {
    guard isCurrentChangesWorktreeRequest(sourceRepositoryID, sourceRepositoryURL) else { return }
    do {
      guard let repositoryID = try await repositoryID(forWorktreeAt: worktreeURL) else { return }
      try Task.checkCancellation()
      guard isCurrentChangesWorktreeRequest(sourceRepositoryID, sourceRepositoryURL) else { return }
      selectRepository(repositoryID)
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled,
        isCurrentChangesWorktreeRequest(sourceRepositoryID, sourceRepositoryURL)
      else { return }
      errorMessage = "Could not open worktree: \(error)"
      publish()
    }
  }

  private func repositoryID(forWorktreeAt worktreeURL: URL) async throws -> UUID? {
    let canonicalURL = RepositoryPathPolicy.canonicalURL(worktreeURL)
    if let repositoryID = repositories.first(where: { $0.canonicalURL == canonicalURL })?.id {
      return repositoryID
    }
    let outcome = try await catalog.addStandaloneRepository(canonicalURL)
    if case .selectedRepository(let repositoryID) = outcome { return repositoryID }
    return repositories.first(where: { $0.canonicalURL == canonicalURL })?.id
  }

  private func isCurrentWorktreeRepository(_ repositoryID: UUID, _ sourceURL: URL) -> Bool {
    guard let repository = repositories.first(where: { $0.id == repositoryID }) else { return false }
    return repository.availability == .available
      && repository.canonicalURL.standardizedFileURL == sourceURL.standardizedFileURL
  }

  func isCurrentWorktreeRequest(
    _ repositoryID: UUID,
    _ branchReference: String,
    _ sourceURL: URL
  ) -> Bool {
    !isShuttingDown
      && state.uiState.mode == .history
      && state.uiState.selectedRepoID == repositoryID
      && selectedHistoryState.selectedBranchRef == branchReference
      && isCurrentWorktreeRepository(repositoryID, sourceURL)
  }

  private func isCurrentChangesWorktreeRequest(_ repositoryID: UUID, _ sourceURL: URL) -> Bool {
    !isShuttingDown
      && state.uiState.mode == .changes
      && state.uiState.selectedRepoID == repositoryID
      && isCurrentWorktreeRepository(repositoryID, sourceURL)
  }

  func openHistoryBranchWorktree(_ branchReference: String?) async {
    guard !isShuttingDown,
      state.uiState.mode == .history,
      let sourceRepositoryID = state.uiState.selectedRepoID,
      let repository = repositories.first(where: { $0.id == sourceRepositoryID }),
      repository.availability == .available
    else { return }
    let sourceRepositoryURL = repository.canonicalURL
    guard let branchReference else {
      setMode(.changes)
      return
    }
    guard branchReference.hasPrefix("refs/heads/"),
      selectedHistoryState.selectedBranchRef == branchReference
    else { return }
    do {
      guard let worktreeURL = try await gitService.linkedWorktreeURL(
        repository: sourceRepositoryURL,
        branchReference: branchReference
      ) else {
        guard isCurrentWorktreeRequest(
          sourceRepositoryID,
          branchReference,
          sourceRepositoryURL
        ) else { return }
        statusMessage = "No linked worktree is checked out for this branch."
        publish()
        return
      }
      try Task.checkCancellation()
      guard isCurrentWorktreeRequest(
        sourceRepositoryID,
        branchReference,
        sourceRepositoryURL
      ) else { return }
      await openLinkedWorktree(
        worktreeURL,
        sourceRepositoryID: sourceRepositoryID,
        sourceRepositoryURL: sourceRepositoryURL,
        branchReference: branchReference
      )
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled,
        isCurrentWorktreeRequest(
          sourceRepositoryID,
          branchReference,
          sourceRepositoryURL
        )
      else { return }
      errorMessage = "Could not open linked worktree: \(error)"
      publish()
    }
  }

}
