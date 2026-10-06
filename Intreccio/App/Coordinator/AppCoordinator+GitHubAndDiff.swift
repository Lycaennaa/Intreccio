import Foundation

@MainActor
extension AppCoordinator {
    func refetchUpstream(for repositoryID: UUID) {
        refetchUpstream(for: [repositoryID])
    }

    func refetchUpstream(for repositoryIDs: [UUID]) {
        runtime.enqueueStatusRefreshes(
            for: repositoryIDs,
            refreshUpstream: true,
            requestKind: .explicit
        )
    }

    func refreshGitHubURLWithRetry(for repositoryID: UUID) async -> URL? {
        await runtime.refreshGitHubURLWithRetry(for: repositoryID)
    }
    func routeSourceFileEvents(_ batch: FileEventBatch, sourceID: UUID) async {
        await runtime.routeSourceFileEvents(batch, sourceID: sourceID)
    }

    func routeRepositoryFileEvents(_ batch: FileEventBatch, repositoryID: UUID) async {
        await runtime.routeRepositoryFileEvents(batch, repositoryID: repositoryID)
    }

    func requestSelectedDiff(changes requestedChanges: [FileChange], kind: DiffKind) {
        guard !isShuttingDown else { return }
        let generation = selectedSession.beginDiff(state: .idle)

        guard state.uiState.mode == .changes,
              let repositoryID = state.uiState.selectedRepoID,
              let repository = repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available,
              let refreshState = repositoryRefreshStates[repositoryID],
              let status = refreshState.status else {
            publish()
            return
        }

        let statusGeneration = refreshState.statusGeneration
        let repositoryURL = repository.canonicalURL
        let currentChanges = status.changes
        selectedDiffState = .loading
        publish()
        let task = Task { [weak self, gitService] in
            do {
                let changes = try await Self.validatedRequestedChanges(requestedChanges, currentChanges: currentChanges)
                try Task.checkCancellation()
                guard let self,
                      selectedSession.isCurrentDiff(generation),
                      state.uiState.selectedRepoID == repositoryID,
                      repositoryRefreshStates[repositoryID]?.statusGeneration == statusGeneration else { return }
                guard !changes.isEmpty else {
                    guard selectedSession.finishDiff(.idle, generation: generation) else { return }
                    publish()
                    return
                }
                let diff = try await gitService.diff(repository: repositoryURL, kind: kind, changes: changes)
                try Task.checkCancellation()
                guard selectedSession.isCurrentDiff(generation),
                      state.uiState.selectedRepoID == repositoryID,
                      repositoryRefreshStates[repositoryID]?.statusGeneration == statusGeneration,
                      selectedSession.finishDiff(.loaded(diff), generation: generation) else { return }
                publish()
            } catch is CancellationError {
            } catch {
                guard let self,
                      !isShuttingDown,
                      state.uiState.selectedRepoID == repositoryID,
                      selectedSession.finishDiff(
                        .failed(.git(error, title: "Could not load diff")),
                        generation: generation
                      ) else { return }
                publish()
            }
        }
        selectedSession.installDiffTask(task, generation: generation)
    }

    nonisolated private static func validatedRequestedChanges(
        _ requestedChanges: [FileChange],
        currentChanges: [FileChange]
    ) async throws -> [FileChange] {
        var currentByPath: [GitPath: [FileChange]] = [:]
        currentByPath.reserveCapacity(currentChanges.count)
        for (index, change) in currentChanges.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            currentByPath[change.gitPath, default: []].append(change)
        }
        var validated: [FileChange] = []
        validated.reserveCapacity(min(requestedChanges.count, currentChanges.count))
        for (index, requested) in requestedChanges.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if currentByPath[requested.gitPath]?.contains(requested) == true { validated.append(requested) }
        }
        return validated
    }

    func clearSelectedDiff() {
        selectedSession.clearDiff()
    }

}
