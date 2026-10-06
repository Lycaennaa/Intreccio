import Foundation

@MainActor
extension AppCoordinator {
    func stage(changes: [FileChange]) {
        beginMutation(.stage(paths: changes.filter(\.hasUnstagedChange).map(\.gitPath)))
    }

    func stageAll() {
        guard let status = selectedStatus else { return }
        beginMutation(.stage(paths: status.changes.filter(\.hasUnstagedChange).map(\.gitPath)))
    }

    func unstage(changes: [FileChange]) {
        beginMutation(.unstage(paths: changes.filter(\.hasStagedChange).map(\.gitPath)))
    }

    func unstageAll() {
        guard let status = selectedStatus else { return }
        beginMutation(.unstage(paths: status.changes.filter(\.hasStagedChange).map(\.gitPath)))
    }
    func stashChanges() {
        beginMutation(.stashChanges)
    }

    func restoreLatestStash() {
        beginMutation(.restoreLatestStash)
    }

    func discard(changes: [FileChange]) {
        beginMutation(.discard(changes: changes))
    }

    func addToGitIgnore(selectedPath: String, targetPath: String, isDirectory: Bool) {
        addToGitIgnore(
            selectedPath: GitPath(selectedPath),
            targetPath: GitPath(targetPath),
            isDirectory: isDirectory
        )
    }

    func addToGitIgnore(selectedPath: GitPath, targetPath: GitPath, isDirectory: Bool) {
        beginMutation(.ignore(selectedPath: selectedPath, targetPath: targetPath, isDirectory: isDirectory))
    }

    func commit() {
        if let amendSession {
            beginMutation(.amend(message: commitMessage, expectedHeadObjectID: amendSession.commit.objectID))
        } else {
            beginMutation(.commit(message: commitMessage))
        }
    }
    func preparePushTarget(for repositoryID: UUID) async -> GitPushTarget? {
        guard !isShuttingDown,
              let repository = repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available else { return nil }
        do {
            return try await gitService.preparePushTarget(repository: repository.canonicalURL)
        } catch is CancellationError {
            return nil
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return nil }
            errorMessage = "Could not prepare push: \(error)"
            publish()
            return nil
        }
    }

    func pushToUpstream(_ target: GitPushTarget) {
        beginMutation(.pushToUpstream(target))
    }

    func rebaseOnUpstream() {
        beginMutation(.rebaseOnUpstream)
    }

    func continueRebase() {
        beginMutation(.continueRebase)
    }

    func abortRebase() {
        beginMutation(.abortRebase)
    }

    var selectedStatus: RepoStatus? {
        guard let repositoryID = state.uiState.selectedRepoID else { return nil }
        return repositoryRefreshStates[repositoryID]?.status
    }

    enum Mutation {
        case stage(paths: [GitPath])
        case unstage(paths: [GitPath])
        case discard(changes: [FileChange])
        case stashChanges
        case restoreLatestStash
        case ignore(selectedPath: GitPath, targetPath: GitPath, isDirectory: Bool)
        case commit(message: String)
        case amend(message: String, expectedHeadObjectID: String)
        case pushToUpstream(GitPushTarget)
        case rebaseOnUpstream
        case continueRebase
        case abortRebase

        var refreshesUpstream: Bool {
            if case .pushToUpstream = self { return true }
            return false
        }

        var isCommit: Bool {
            switch self {
            case .commit, .amend: true
            default: false
            }
        }

        var failureTitle: String {
            switch self {
            case .stage: "Could not stage changes"
            case .unstage: "Could not unstage changes"
            case .discard: "Could not discard changes"
            case .stashChanges: "Could not stash changes"
            case .restoreLatestStash: "Could not restore latest stash"
            case .ignore: "Could not update .gitignore"
            case .commit: "Could not commit changes"
            case .amend: "Could not amend commit"
            case .pushToUpstream: "Could not push to upstream"
            case .rebaseOnUpstream: "Could not rebase on upstream"
            case .continueRebase: "Could not continue rebase"
            case .abortRebase: "Could not abort rebase"
            }
        }
    }

    func beginMutation(_ mutation: Mutation) {
        guard !isShuttingDown,
              mutationTask == nil,
              state.uiState.mode == .changes,
              let repositoryID = state.uiState.selectedRepoID,
              let repository = repositories.first(where: { $0.id == repositoryID }),
              repository.availability == .available,
              repositoryRefreshStates[repositoryID]?.status != nil else { return }
        let repositoryURL = repository.canonicalURL
        if case let .pushToUpstream(target) = mutation, target.repository != repositoryURL { return }
        mutationGeneration &+= 1
        let generation = mutationGeneration
        let operationID = UUID()
        mutationID = operationID
        mutationState = .running
        publish()
        mutationTask = Task { [weak self, gitService] in
            var failure: OperationFailure?
            do {
                switch mutation {
                case .stage(let paths):
                    try await gitService.stage(repository: repositoryURL, paths: paths)
                case .unstage(let paths):
                    try await gitService.unstage(repository: repositoryURL, paths: paths)
                case .stashChanges:
                    try await gitService.stashChanges(repository: repositoryURL)
                case .restoreLatestStash:
                    try await gitService.restoreLatestStash(repository: repositoryURL)
                case .discard(let changes):
                    try await gitService.discard(repository: repositoryURL, changes: changes)
                case .ignore(let selectedPath, let targetPath, let isDirectory):
                    try await gitService.addToGitIgnore(
                        repository: repositoryURL,
                        selectedPath: selectedPath,
                        targetPath: targetPath,
                        isDirectory: isDirectory
                    )
                case .commit(let message):
                    _ = try await gitService.commit(repository: repositoryURL, message: message)
                case .amend(let message, let expectedHeadObjectID):
                    _ = try await gitService.amend(
                        repository: repositoryURL,
                        message: message,
                        expectedHeadObjectID: expectedHeadObjectID
                    )
                case .pushToUpstream(let target):
                    try await gitService.pushToUpstream(target: target)
                case .rebaseOnUpstream:
                    try await gitService.rebaseOnUpstream(repository: repositoryURL)
                case .continueRebase:
                    try await gitService.continueRebase(repository: repositoryURL)
                case .abortRebase:
                    try await gitService.abortRebase(repository: repositoryURL)
                }
            } catch {
                failure = .git(error, title: mutation.failureTitle)
            }
            guard let self else { return }
            finishMutation(
                repositoryID: repositoryID,
                generation: generation,
                operationID: operationID,
                wasCommit: mutation.isCommit,
                refreshUpstream: mutation.refreshesUpstream,
                failure: failure
            )
        }
    }

    func finishMutation(
        repositoryID: UUID,
        generation: UInt64,
        operationID: UUID,
        wasCommit: Bool,
        refreshUpstream: Bool = false,
        failure: OperationFailure?
    ) {
        let ownsTask = mutationID == operationID
        if ownsTask {
            mutationTask = nil
            mutationID = nil
        }
        if runtime.invalidateHistory(for: [repositoryID]) {
            clearSelectedHistory()
            loadNextHistoryPage()
        }
        runtime.enqueueStatusRefreshes(
            for: [repositoryID],
            refreshUpstream: refreshUpstream,
            requestKind: .destructiveOperation
        )
        guard mutationGeneration == generation,
              state.uiState.selectedRepoID == repositoryID else {
            if ownsTask {
                mutationState = .idle
                publish()
            }
            return
        }
        clearSelectedDiff()
        if let failure {
            mutationState = .failed(failure)
        } else {
            mutationState = .idle
            if wasCommit {
                amendSession = nil
                commitMessage = ""
                usesDefaultCommitMessage = true
            }
        }
        publish()
    }

    func cancelSelectedMutation(clearMessage: Bool) {
        mutationGeneration &+= 1
        mutationTask?.cancel()
        mutationState = mutationTask == nil ? .idle : .running
        if clearMessage {
            amendSession = nil
            commitMessage = ""
            usesDefaultCommitMessage = true
        }
    }

}
