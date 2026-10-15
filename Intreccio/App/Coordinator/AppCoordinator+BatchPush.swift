import Foundation

@MainActor
extension AppCoordinator {
    func pushToUpstream(_ targets: [GitPushTarget]) {
        guard !isShuttingDown,
              !mutationAdmissionClosed,
              mutationTask == nil,
              !targets.isEmpty,
              targets.allSatisfy({ $0.remote == "origin" }) else { return }

        let repositoryDisplayNames = RepoDescriptor.disambiguatedDisplayNames(for: repositories)
        var repositoryIDs = [UUID]()
        var repositoryNames = [String]()
        var seenRepositoryIDs = Set<UUID>()
        for target in targets {
            guard let repository = repositories.first(where: {
                $0.canonicalURL == target.repository && $0.availability == .available
            }), seenRepositoryIDs.insert(repository.id).inserted else { return }
            repositoryIDs.append(repository.id)
            repositoryNames.append(repositoryDisplayNames[repository.id] ?? repository.displayName)
        }

        mutationGeneration &+= 1
        let generation = mutationGeneration
        let operationID = UUID()
        mutationID = operationID
        mutationIsBatchPush = true
        lastMutationFailure = nil
        mutationState = .running
        publish()

        mutationTask = Task<OperationFailure?, Never> { [weak self, gitService] in
            var pushed = [String]()
            var failures = [String]()
            for (index, target) in targets.enumerated() {
                do {
                    try Task.checkCancellation()
                    try await gitService.pushToUpstream(target: target)
                    pushed.append(repositoryNames[index])
                } catch is CancellationError {
                    break
                } catch {
                    failures.append("\(repositoryNames[index]): \(error)")
                }
            }
            let failure: OperationFailure?
            if failures.isEmpty {
                failure = nil
            } else {
                let details = [
                    pushed.isEmpty ? nil : "Pushed:\n\(pushed.map { "• \($0)" }.joined(separator: "\n"))",
                    "Failed:\n\(failures.map { "• \($0)" }.joined(separator: "\n"))"
                ].compactMap(\.self).joined(separator: "\n\n")
                failure = .message(
                    details,
                    title: "Some repositories could not be pushed",
                    recoverySuggestion: "Review the repository errors and retry the repositories that remain unpushed."
                )
            }
            guard let self else { return failure }
            finishBatchPush(
                repositoryIDs: repositoryIDs,
                generation: generation,
                operationID: operationID,
                failure: failure
            )
            return failure
        }
    }

    private func finishBatchPush(
        repositoryIDs: [UUID],
        generation: UInt64,
        operationID: UUID,
        failure: OperationFailure?
    ) {
        lastMutationFailure = failure
        let ownsTask = mutationID == operationID
        if ownsTask {
            mutationTask = nil
            mutationID = nil
            mutationIsBatchPush = false
        }
        guard !isShuttingDown else { return }
        if let failure { errorMessage = failure.copyText }

        let selectedRepositoryWasPushed = state.uiState.selectedRepoID.map(repositoryIDs.contains) == true
        if runtime.invalidateHistory(for: repositoryIDs), selectedRepositoryWasPushed {
            clearSelectedHistory()
            loadNextHistoryPage()
        }
        runtime.enqueueStatusRefreshes(
            for: repositoryIDs,
            refreshUpstream: true,
            requestKind: .destructiveOperation
        )
        if selectedRepositoryWasPushed { clearSelectedDiff() }

        guard ownsTask, mutationGeneration == generation else {
            if ownsTask {
                mutationState = .idle
                publish()
            }
            return
        }
        mutationState = failure.map(RepositoryMutationState.failed) ?? .idle
        publish()
    }
}
