import Foundation

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

    func loadNextHistoryPage() {
        guard !isShuttingDown,
              !selectedSession.hasHistoryTask,
              state.uiState.mode == .history,
              let repositoryID = state.uiState.selectedRepoID,
              let repository = repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available,
              !selectedHistoryState.reachedEnd,
              !selectedHistoryState.reachedLimit else { return }

        let requestGeneration = selectedSession.beginHistoryTask()
        let historyGeneration = runtime.historyGeneration(for: repositoryID)
        let repositoryURL = repository.canonicalURL
        let skip = selectedHistoryState.commits.count
        let scope = historyScope
        let knownTips = selectedHistoryState.tips
        selectedHistoryState.phase = .loading

        let task = Task { [weak self, gitService] in
            do {
                let tips: HistoryTips
                if let knownTips {
                    tips = knownTips
                } else {
                    tips = try await gitService.historyTips(repository: repositoryURL)
                }
                let page = try await gitService.historyPage(
                    repository: repositoryURL,
                    scope: scope,
                    tips: tips,
                    skip: skip
                )
                let currentTips = try await gitService.historyTips(repository: repositoryURL)
                try Task.checkCancellation()
                guard let self,
                      selectedSession.isCurrentHistory(requestGeneration),
                      state.uiState.mode == .history,
                      state.uiState.selectedRepoID == repositoryID,
                      historyScope == scope,
                      runtime.historyGeneration(for: repositoryID) == historyGeneration else { return }
                guard currentTips == tips else {
                    _ = runtime.invalidateHistory(for: [repositoryID])
                    selectedSession.finishHistoryTask(generation: requestGeneration)
                    clearSelectedHistory()
                    loadNextHistoryPage()
                    return
                }
                selectedHistoryState.tips = tips
                selectedHistoryState.metadataCompleteness = page.completeness
                if skip >= SelectedHistoryState.maximumLoadedCommits {
                    selectedHistoryState.reachedEnd = page.completeness.isComplete && page.commits.isEmpty
                    selectedHistoryState.reachedLimit = !page.commits.isEmpty || !page.completeness.isComplete
                } else {
                    selectedHistoryState.commits.append(contentsOf: page.commits)
                    selectedHistoryState.reachedEnd = page.completeness.isComplete
                        && page.commits.count < GitService.historyPageSize
                    if !page.completeness.isComplete { selectedHistoryState.reachedLimit = true }
                }
                selectedHistoryState.phase = .idle
                selectedSession.finishHistoryTask(generation: requestGeneration)
                publish()
            } catch is CancellationError {
            } catch {
                guard let self,
                      !isShuttingDown,
                      selectedSession.isCurrentHistory(requestGeneration),
                      state.uiState.mode == .history,
                      state.uiState.selectedRepoID == repositoryID,
                      runtime.historyGeneration(for: repositoryID) == historyGeneration else { return }
                selectedHistoryState.phase = .failed(.git(error, title: "Could not load history"))
                selectedSession.finishHistoryTask(generation: requestGeneration)
                publish()
            }
        }
        selectedSession.installHistoryTask(task, generation: requestGeneration)
        publish()
    }

    func selectCommit(_ commit: Commit?) {
        guard !isShuttingDown else { return }
        let generation = selectedSession.beginCommit()

        guard let commit,
              state.uiState.mode == .history,
              selectedHistoryState.commits.contains(where: { $0.objectID == commit.objectID }),
              let repositoryID = state.uiState.selectedRepoID,
              let repository = repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available else {
            selectedCommitState = .idle
            publish()
            return
        }

        let historyGeneration = runtime.historyGeneration(for: repositoryID)
        let tips = selectedHistoryState.tips
        selectedCommitState = .loading(commit)
        publish()
        let task = Task { [weak self, gitService] in
            do {
                let details = try await gitService.show(repository: repository.canonicalURL, commit: commit)
                let currentTips = try await gitService.historyTips(repository: repository.canonicalURL)
                try Task.checkCancellation()
                guard let self,
                      selectedSession.isCurrentCommit(generation),
                      state.uiState.mode == .history,
                      state.uiState.selectedRepoID == repositoryID,
                      runtime.historyGeneration(for: repositoryID) == historyGeneration else { return }
                guard currentTips == tips else {
                    _ = runtime.invalidateHistory(for: [repositoryID])
                    clearSelectedHistory()
                    loadNextHistoryPage()
                    publish()
                    return
                }
                guard selectedSession.isCurrentCommit(generation) else { return }
                selectedCommitState = .loaded(details)
                selectedSession.finishCommitTask(generation: generation)
                publish()
            } catch ProcessRunnerError.cancelled {
                guard let self else { return }
                finishCancelledCommitLoad(generation: generation)
            } catch is CancellationError {
                guard let self else { return }
                finishCancelledCommitLoad(generation: generation)
            } catch {
                guard let self,
                      !isShuttingDown,
                      selectedSession.isCurrentCommit(generation),
                      state.uiState.mode == .history,
                      state.uiState.selectedRepoID == repositoryID else { return }
                selectedCommitState = .failed(commit, .git(error, title: "Could not load commit"))
                selectedSession.finishCommitTask(generation: generation)
                publish()
            }
        }
        selectedSession.installCommitTask(task, generation: generation)
    }

    private func finishCancelledCommitLoad(generation: UInt64) {
        guard !isShuttingDown, selectedSession.isCurrentCommit(generation) else { return }
        selectedCommitState = .idle
        selectedSession.finishCommitTask(generation: generation)
        publish()
    }

    func clearSelectedHistory() {
        selectedSession.clearHistory()
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
              selectedHistoryState.headObjectID == commit.objectID,
              selectedHistoryState.commits.contains(where: { $0.objectID == commit.objectID }) else { return }
        guard commit.subjectMetadata.completeness.isComplete,
              commit.bodyMetadata.completeness.isComplete else { return }
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
                case 0x0B, 0x0C, 0x85, 0x2028, 0x2029: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
                default: String(scalar)
                }
            }.joined()
        }
        let paths = stagedChanges.map { displayPath(for: $0) }
        let fileList = switch paths.count {
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
