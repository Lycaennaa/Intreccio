import Foundation

nonisolated enum QuickOpenFileUpdateResult: Sendable, Equatable {
    case unchanged
    case updated
    case invalidInput
    case capacityExceeded
}

@MainActor
extension AppCoordinator {
    func selectRepository(_ repositoryID: UUID?) {
        guard !isShuttingDown else { return }
        let previous = state.uiState.selectedRepoID
        guard previous != repositoryID else { return }
        cancelSelectedMutation(clearMessage: true)
        selectedSession.replaceLoadTask(with: nil)
        clearSelectedDiff()
        clearSelectedHistory()
        state.uiState.selectedRepoID = repositoryID
        let loadTask = Task { [weak self] in
            guard let self else { return }
            if let previous, previous != repositoryID {
                await runtime.cancelRefresh(repositoryID: previous)
            }
            guard !Task.isCancelled, !isShuttingDown else { return }
            await runtime.setSelectedRepository(repositoryID)
            guard !Task.isCancelled,
                  !isShuttingDown,
                  state.uiState.selectedRepoID == repositoryID,
                  let repositoryID else { return }
            await runtime.setDiffStatsEnabled(
                state.uiState.mode == .changes,
                generation: selectedSession.modeGeneration
            )
            runtime.enqueueStatusRefreshes(for: [repositoryID], refreshUpstream: true)
            if state.uiState.mode == .history { loadNextHistoryPage() }
        }
        selectedSession.replaceLoadTask(with: loadTask)
        scheduleUIStateSave()
        publish()
    }

    func setSearchText(_ text: String) {
        guard !isShuttingDown else { return }
        state.uiState.searchText = text
        scheduleUIStateSave()
        publish()
    }

    func setRepositoryPinned(_ repositoryID: UUID, pinned: Bool) {
        setRepositoriesPinned([repositoryID], pinned: pinned)
    }

    func setRepositoriesPinned(_ repositoryIDs: [UUID], pinned: Bool) {
        guard !isShuttingDown, !repositoryIDs.isEmpty else { return }
        let requestedIDs = Set(repositoryIDs)
        let validIDs = repositories.map(\.id).filter { requestedIDs.contains($0) }
        guard !validIDs.isEmpty else { return }
        let changedIDs = validIDs.filter {
            state.uiState.pinnedRepositoryIDs.contains($0) != pinned
        }
        guard !changedIDs.isEmpty else { return }
        if pinned {
            state.uiState.pinnedRepositoryIDs.formUnion(changedIDs)
        } else {
            state.uiState.pinnedRepositoryIDs.subtract(changedIDs)
        }
        scheduleUIStateSave()
        publish()
    }

    func setMode(_ mode: AppMode) {
        guard !isShuttingDown, state.uiState.mode != mode else { return }
        if mode != .changes { restoreDraftBeforeAmend() }
        cancelSelectedMutation(clearMessage: false)
        selectedSession.replaceLoadTask(with: nil)
        clearSelectedDiff()
        clearSelectedHistory()
        state.uiState.mode = mode
        let modeGeneration = selectedSession.nextModeGeneration()
        let loadTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, !self.isShuttingDown, self.state.uiState.mode == mode else { return }
            await self.runtime.setDiffStatsEnabled(mode == .changes, generation: modeGeneration)
            guard !Task.isCancelled, !self.isShuttingDown, self.state.uiState.mode == mode else { return }
            guard let selected = self.state.uiState.selectedRepoID else { return }
            await self.runtime.setSelectedRepository(selected)
            await self.runtime.cancelRefresh(repositoryID: selected)
            guard !Task.isCancelled,
                  !isShuttingDown,
                  state.uiState.mode == mode,
                  state.uiState.selectedRepoID == selected else { return }
            if mode == .changes {
                runtime.enqueueStatusRefreshes(for: [selected], refreshUpstream: true)
            } else {
                loadNextHistoryPage()
            }
        }
        selectedSession.replaceLoadTask(with: loadTask)
        scheduleUIStateSave()
        publish()
    }

    func setWindowState(frame: String, sidebarWidth: Double, changesListWidth: Double) {
        guard !isShuttingDown else { return }
        // Never persist transient degenerate geometry (e.g. recorded mid-teardown);
        // restoring it later collapses the window to a sliver.
        guard let validFrame = PersistedUIState.sanitizedWindowFrame(frame) else { return }
        state.uiState.windowFrame = validFrame
        state.uiState.sidebarWidth = sidebarWidth
        state.uiState.changesListWidth = changesListWidth
        scheduleUIStateSave()
    }

    func setDiffFontSize(_ size: Double) {
        guard !isShuttingDown, size >= 9, size <= 24, state.uiState.diffFontSize != size else { return }
        state.uiState.diffFontSize = size
        scheduleUIStateSave()
        publish()
    }

    func setShowWhitespaceInDiff(_ enabled: Bool) {
        guard !isShuttingDown, state.uiState.showWhitespaceInDiff != enabled else { return }
        state.uiState.showWhitespaceInDiff = enabled
        scheduleUIStateSave()
        publish()
    }

    func setFileWatchDebounce(milliseconds: Int) {
        guard !isShuttingDown, milliseconds >= 50, milliseconds <= 2_000,
              state.uiState.fileWatchDebounceMilliseconds != milliseconds else { return }
        state.uiState.fileWatchDebounceMilliseconds = milliseconds
        let delay = Duration.milliseconds(milliseconds)
        runtime.updateDebounce(delay)
        scheduleUIStateSave()
    }

    func setDefaultOpenApplication(_ applicationURL: URL?) {
        guard !isShuttingDown else { return }
        guard let applicationURL else {
            guard state.uiState.defaultOpenApplicationURL != nil else { return }
            state.uiState.defaultOpenApplicationURL = nil
            scheduleUIStateSave()
            return
        }
        guard let normalizedURL = PersistedOpenApplicationList.normalizedSavedApplicationURLs([applicationURL]).first,
              normalizedURL != state.uiState.defaultOpenApplicationURL else { return }
        state.uiState.defaultOpenApplicationURL = normalizedURL
        scheduleUIStateSave()
    }
    func quickOpenFilePaths(for repositoryID: UUID) -> [String] {
        state.uiState.quickOpenFileAssignments.first { $0.repositoryID == repositoryID }?.paths ?? []
    }

    func setQuickOpenFilePaths(_ paths: [String], for repositoryID: UUID) -> QuickOpenFileUpdateResult {
        guard !isShuttingDown,
              repositories.contains(where: { $0.id == repositoryID }) else { return .unchanged }
        let normalizedPaths: [String]
        switch PersistedUIState.validatedQuickOpenFilePathsForMutation(paths) {
        case .valid(let paths):
            normalizedPaths = paths
        case .invalid:
            return .invalidInput
        case .capacityExceeded:
            return .capacityExceeded
        }
        var assignments = state.uiState.quickOpenFileAssignments
        if let index = assignments.firstIndex(where: { $0.repositoryID == repositoryID }) {
            if normalizedPaths.isEmpty {
                assignments.remove(at: index)
            } else {
                assignments[index] = PersistedQuickOpenFileAssignment(
                    repositoryID: repositoryID,
                    paths: normalizedPaths
                )
            }
        } else if !normalizedPaths.isEmpty {
            assignments.append(PersistedQuickOpenFileAssignment(
                repositoryID: repositoryID,
                paths: normalizedPaths
            ))
        }
        let normalizedAssignments = PersistedUIState.normalizedQuickOpenFileAssignments(assignments)
        guard normalizedAssignments == assignments else { return .capacityExceeded }
        guard normalizedAssignments != state.uiState.quickOpenFileAssignments else { return .unchanged }
        state.uiState.quickOpenFileAssignments = normalizedAssignments
        scheduleUIStateSave()
        publish()
        return .updated
    }

    /// One-time registration of the system folder apps on first launch ever.
    /// Afterwards they are ordinary remembered applications: removing them
    /// persists and they are never re-added.
    func seedDefaultFolderApplicationsIfNeeded() {
        guard !isShuttingDown,
              !state.uiState.seededDefaultFolderApplications else { return }
        state.uiState.seededDefaultFolderApplications = true
        var applicationList = state.uiState.openApplicationList
        applicationList.seedDefaultFolderApplications()
        state.uiState.openApplicationList = applicationList
        scheduleRememberedApplicationSave()
    }

    func rememberOpenApplication(_ applicationURL: URL) {
        guard !isShuttingDown else { return }
        var applicationList = state.uiState.openApplicationList
        guard applicationList.remember(applicationURL) else { return }
        state.uiState.openApplicationList = applicationList
        scheduleRememberedApplicationSave()
    }

    func removeOpenApplications(_ applicationURLs: [URL]) {
        guard !isShuttingDown else { return }
        var applicationList = state.uiState.openApplicationList
        guard applicationList.remove(applicationURLs) else { return }
        state.uiState.openApplicationList = applicationList
        scheduleRememberedApplicationSave()
    }

    func removeOpenApplication(_ applicationURL: URL) {
        removeOpenApplications([applicationURL])
    }

    /// Removes apps from the hidden list so they can appear in Open With menus again.
    func restoreExcludedOpenApplications(_ applicationURLs: [URL]) {
        guard !isShuttingDown else { return }
        var applicationList = state.uiState.openApplicationList
        guard applicationList.restore(applicationURLs) else { return }
        state.uiState.openApplicationList = applicationList
        scheduleRememberedApplicationSave()
    }

    func reauthorizeSource(_ sourceID: UUID, with selectedURL: URL) async {
        do {
            _ = try await catalog.reauthorizeSource(sourceID, with: selectedURL)
        } catch is CancellationError {
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            errorMessage = "Could not re-authorize source: \(error)"
            publish()
        }
    }

    func clearError() {
        errorMessage = nil
        publish()
    }

}
