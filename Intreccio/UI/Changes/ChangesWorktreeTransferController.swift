import AppKit

@MainActor
final class ChangesWorktreeTransferController: NSObject {
  let button = NSButton(title: "Bring Changes to Main", target: nil, action: nil)

  private let coordinator: AppCoordinator
  private var repository: RepoDescriptor?
  private var mainRepositoryURL: URL?
  private var queriedMainStatusURL: URL?
  private var sourceStatus: RepoStatus?
  private var mutationIsRunning = false
  private var mainStatus: RepoStatus?
  private var mainStatusFailure: String?
  private var statusGeneration: UInt64 = 0
  private var statusTask: Task<Void, Never>?
  private var statusRefreshGeneration: UInt64 = 0
  private var statusRefreshTask: Task<Void, Never>?

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init()
    button.target = self
    button.action = #selector(bringChangesToMain(_:))
    button.setAccessibilityHelp(
      "Stage this worktree's uncommitted changes in main. "
        + "Ensure both worktrees are idle; concurrent edits may be overwritten."
    )
    button.controlSize = .small
    button.isHidden = true
  }

  deinit {
    MainActor.assumeIsolated {
      statusTask?.cancel()
      statusRefreshTask?.cancel()
    }
  }

  func clear() {
    repository = nil
    mainRepositoryURL = nil
    sourceStatus = nil
    mutationIsRunning = false
    invalidateMainStatus()
    button.isHidden = true
    button.isEnabled = false
    button.toolTip = ""
  }

  func configure(
    repository: RepoDescriptor?,
    discoveredMainRepositoryURL: URL?,
    status: RepoStatus?,
    mutationIsRunning: Bool
  ) {
    let resolvedMainURL = (repository?.mainRepositoryURL ?? discoveredMainRepositoryURL)?.standardizedFileURL
    let repositoryChanged = self.repository?.id != repository?.id
      || self.repository?.canonicalURL != repository?.canonicalURL
    let mainChanged = mainRepositoryURL != resolvedMainURL
    let statusChanged = sourceStatus != status || self.mutationIsRunning != mutationIsRunning
    self.repository = repository
    mainRepositoryURL = resolvedMainURL
    sourceStatus = status
    self.mutationIsRunning = mutationIsRunning
    if repositoryChanged || mainChanged || statusChanged { invalidateMainStatus() }
    updateButton()
  }

  func refreshMainStatus() {
    guard repository?.isLinkedWorktree == true,
          let sourceStatus,
          !sourceStatus.changes.isEmpty,
          mainRepositoryURL != nil else { return }
    invalidateMainStatus()
    updateButton()
  }

  private func invalidateMainStatus() {
    statusGeneration &+= 1
    statusTask?.cancel()
    statusTask = nil
    statusRefreshGeneration &+= 1
    statusRefreshTask?.cancel()
    statusRefreshTask = nil
    mainStatus = nil
    queriedMainStatusURL = nil
    mainStatusFailure = nil
  }

  private func updateButton() {
    guard let repository,
          repository.isLinkedWorktree,
          let sourceStatus,
          !sourceStatus.changes.isEmpty else {
      button.isHidden = true
      button.isEnabled = false
      return
    }
    button.isHidden = false
    button.isEnabled = false
    if mutationIsRunning {
      button.toolTip = "A repository change is already running."
      return
    }
    if let failure = WorktreeTransferEligibility.failure(sourceStatus: sourceStatus) {
      button.toolTip = failure.description
      return
    }
    guard let mainRepositoryURL else {
      button.toolTip = "Could not identify the main worktree."
      return
    }
    guard queriedMainStatusURL == mainRepositoryURL else {
      loadMainStatus(at: mainRepositoryURL)
      button.toolTip = "Checking main worktree…"
      return
    }
    guard let mainStatus else {
      button.toolTip = mainStatusFailure.map { "Could not check main worktree: \($0)" }
        ?? "Checking main worktree…"
      return
    }
    if let failure = WorktreeTransferEligibility.failure(
      sourceStatus: sourceStatus,
      mainStatus: mainStatus
    ) {
      button.toolTip = failure.description
      return
    }
    button.toolTip =
      "Stage all worktree changes in clean main. The source worktree stays unchanged."
    button.isEnabled = true
  }

  private func loadMainStatus(at repositoryURL: URL) {
    statusGeneration &+= 1
    statusTask?.cancel()
    let generation = statusGeneration
    let repositoryID = repository?.id
    let gitService = coordinator.gitService
    mainStatus = nil
    queriedMainStatusURL = repositoryURL
    mainStatusFailure = nil
    statusTask = Task { [weak self, gitService] in
      do {
        let status = try await gitService.status(repository: repositoryURL, priority: .normal)
        try Task.checkCancellation()
        guard let self,
              statusGeneration == generation,
              repository?.id == repositoryID,
              mainRepositoryURL == repositoryURL else { return }
        mainStatus = status
        statusTask = nil
        updateButton()
        scheduleMainStatusRefresh(for: repositoryURL)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled,
              let self,
              statusGeneration == generation,
              repository?.id == repositoryID,
              mainRepositoryURL == repositoryURL else { return }
        mainStatusFailure = error.localizedDescription
        statusTask = nil
        scheduleMainStatusRefresh(for: repositoryURL)
        updateButton()
      }
    }
  }

  func waitForMainStatusRefresh() async {
    await statusTask?.value
  }

  private func scheduleMainStatusRefresh(for repositoryURL: URL) {
    statusRefreshGeneration &+= 1
    statusRefreshTask?.cancel()
    let generation = statusRefreshGeneration
    statusRefreshTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {
        return
      }
      guard !Task.isCancelled,
            let self,
            statusRefreshGeneration == generation,
            mainRepositoryURL == repositoryURL else { return }
      statusRefreshTask = nil
      invalidateMainStatus()
      updateButton()
    }
  }

  @objc private func bringChangesToMain(_ sender: NSButton) {
    guard sender.isEnabled,
          let sourceRepositoryID = repository?.id,
          let mainRepositoryURL,
          let window = sender.window else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Transfer changes to main?"
    alert.informativeText = "Ensure both worktrees are idle before continuing. Concurrent edits may be overwritten. "
      + "The source worktree remains unchanged."
    alert.addButton(withTitle: "Transfer to Main")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn,
            let self,
            self.repository?.id == sourceRepositoryID,
            self.mainRepositoryURL == mainRepositoryURL,
            !self.mutationIsRunning else { return }
      self.coordinator.bringWorktreeChangesToMain(
        sourceRepositoryID: sourceRepositoryID,
        mainRepositoryURL: mainRepositoryURL
      )
    }
  }
}
