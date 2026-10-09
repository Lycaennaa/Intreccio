import Foundation

nonisolated enum WorktreeTransferEligibility {
    static func failure(
        sourceStatus: RepoStatus,
        mainStatus: RepoStatus? = nil
    ) -> GitServiceError? {
        if let failure = sourceFailure(sourceStatus) { return failure }
        guard let mainStatus else { return nil }
        return mainFailure(mainStatus)
    }

    private static func sourceFailure(_ status: RepoStatus) -> GitServiceError? {
        if status.isRebaseInProgress { return .rebaseAlreadyInProgress }
        if status.branch.objectID == nil { return .sourceWorktreeRequiresCommit }
        if status.changes.isEmpty { return .noWorktreeChangesToBring }
        let conflicts = status.changes.filter { $0.kind == .unmerged }.map(\.path).sorted()
        if !conflicts.isEmpty { return .conflictedWorktreeForTransfer(conflicts) }
        if let submodule = status.changes.first(where: { $0.submoduleState?.hasPrefix("S") == true }) {
            return .unsupportedWorktreeTransferSubmodule(submodule.path)
        }
        if let nestedRepository = status.changes.first(where: {
            $0.kind == .untracked && $0.path.hasSuffix("/")
        }) {
            return .unsupportedWorktreeTransferPath(nestedRepository.path)
        }
        if let unsupportedPath = status.changes.first(where: { !$0.isAddressable }) {
            return .unsupportedWorktreeTransferPath(unsupportedPath.path)
        }
        return nil
    }

    private static func mainFailure(_ status: RepoStatus) -> GitServiceError? {
        if status.isRebaseInProgress { return .rebaseAlreadyInProgress }
        if status.branch.objectID == nil { return .mainWorktreeRequiresCommit }
        if !status.isClean {
            return .dirtyMainWorktreeForTransfer(Array(Set(status.changes.map(\.path))).sorted())
        }
        return nil
    }
}

nonisolated private struct WorktreeTransferState {
    let source: URL
    let sourceStatus: RepoStatus
    let main: URL
    let mainStatus: RepoStatus
}

extension GitService {
    func bringWorktreeChangesToMain(from sourceRepository: URL, to mainRepository: URL) async throws {
        let repositories = try worktreeTransferRepositories(from: sourceRepository, to: mainRepository)
        let sourceStatus = try await status(repository: repositories.source, priority: .selectedRepository)
        if let failure = WorktreeTransferEligibility.failure(sourceStatus: sourceStatus) { throw failure }
        let mainStatus = try await status(repository: repositories.main, priority: .normal)
        if let failure = WorktreeTransferEligibility.failure(sourceStatus: sourceStatus, mainStatus: mainStatus) {
            throw failure
        }
        let index = try await makeWorktreeTransferIndex(repository: repositories.source)
        defer { try? FileManager.default.removeItem(at: index.directory) }

        _ = try await runner.run(
            repository: repositories.source,
            arguments: ["read-tree", "HEAD"],
            environment: index.environment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
        let patch = try await worktreeTransferPatch(
            repository: repositories.source,
            indexEnvironment: index.environment
        )
        guard !patch.isEmpty else { throw GitServiceError.noWorktreeChangesToBring }
        try await checkWorktreeTransferPatch(patch, in: repositories.main)
        try await verifyWorktreeTransferState(
            WorktreeTransferState(
                source: repositories.source,
                sourceStatus: sourceStatus,
                main: repositories.main,
                mainStatus: mainStatus
            ),
            patch: patch,
            indexEnvironment: index.environment
        )
        let transferPaths = Array(Set(sourceStatus.changes.map(\.path))).sorted()
        try await applyWorktreeTransferPatch(
            patch,
            to: repositories.main,
            paths: transferPaths
        )
    }

    private func applyWorktreeTransferPatch(
        _ patch: Data,
        to repository: URL,
        paths: [String]
    ) async throws {
        try Task.checkCancellation()
        let request = ProcessExecutionRequest(
            repository: repository,
            arguments: ["apply", "--index", "--binary"],
            input: patch,
            environment: mutationEnvironment,
            acceptedExitCodes: [0],
            outputLimit: ProcessRunner.defaultOutputLimit,
            priority: .normal,
            cancellationBehavior: .finishAfterLaunch,
            outputLimitBehavior: .discardExcess
        )
        // Shutdown drains this mutation; once Git starts applying, it must finish instead of being interrupted.
        do {
            _ = try await runner.executeWithoutTimeout(request)
        } catch let processError as ProcessRunnerError {
            switch processError {
            case .nonZeroExit, .outputLimitExceeded:
                throw GitServiceError.worktreeTransferApplyFailed(
                    paths: paths,
                    reason: processError.description
                )
            default:
                throw processError
            }
        }
    }

    private func worktreeTransferRepositories(
        from sourceRepository: URL,
        to mainRepository: URL
    ) throws -> (source: URL, main: URL) {
        let source = RepositoryPathPolicy.canonicalURL(sourceRepository)
        let main = RepositoryPathPolicy.canonicalURL(mainRepository)
        guard source != main,
              let sourceInfo = GitDirectoryInfo.read(at: source),
              sourceInfo.isLinkedWorktree,
              let mainInfo = GitDirectoryInfo.read(at: main),
              !mainInfo.isLinkedWorktree,
              sourceInfo.commonGitDirectoryURL == mainInfo.commonGitDirectoryURL else {
            throw GitServiceError.worktreeTransferRequiresLinkedSource
        }
        return (source, main)
    }

    private func makeWorktreeTransferIndex(
        repository: URL
    ) async throws -> (directory: URL, environment: [String: String]) {
        let result = try await runner.run(
            repository: repository,
            arguments: ["rev-parse", "--absolute-git-dir"],
            environment: readEnvironment,
            priority: .selectedRepository
        )
        let gitDirectoryPath = String(bytes: result.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !gitDirectoryPath.isEmpty else {
            throw GitServiceError.worktreeTransferRequiresLinkedSource
        }
        let directory = URL(fileURLWithPath: gitDirectoryPath, isDirectory: true)
            .appendingPathComponent("intreccio-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var environment = mutationEnvironment
        environment["GIT_INDEX_FILE"] = directory.appendingPathComponent("index").path
        return (directory, environment)
    }

    private func worktreeTransferPatch(
        repository: URL,
        indexEnvironment: [String: String]
    ) async throws -> Data {
        _ = try await runner.run(
            repository: repository,
            arguments: ["add", "--all"],
            environment: indexEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
        let result = try await runner.run(
            repository: repository,
            arguments: ["diff", "--cached", "--binary", "HEAD"],
            environment: indexEnvironment,
            outputLimit: ProcessRunner.defaultOutputLimit,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
        return result.standardOutput
    }

    private func checkWorktreeTransferPatch(_ patch: Data, in repository: URL) async throws {
        _ = try await runner.run(
            repository: repository,
            arguments: ["apply", "--check", "--binary"],
            input: patch,
            environment: mutationEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .normal
        )
    }

    private func verifyWorktreeTransferState(
        _ transferState: WorktreeTransferState,
        patch: Data,
        indexEnvironment: [String: String]
    ) async throws {
        let latestSourceStatus = try await status(
            repository: transferState.source,
            priority: .selectedRepository
        )
        let latestMainStatus = try await status(repository: transferState.main, priority: .normal)
        guard latestSourceStatus == transferState.sourceStatus else {
            throw GitServiceError.worktreeTransferStateChanged
        }
        if let failure = WorktreeTransferEligibility.failure(
            sourceStatus: latestSourceStatus,
            mainStatus: latestMainStatus
        ) {
            throw failure
        }
        guard latestMainStatus == transferState.mainStatus else {
            throw GitServiceError.worktreeTransferStateChanged
        }
        let latestPatch = try await worktreeTransferPatch(
            repository: transferState.source,
            indexEnvironment: indexEnvironment
        )
        guard latestPatch == patch else { throw GitServiceError.worktreeTransferStateChanged }
    }
}
