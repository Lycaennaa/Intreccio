import Foundation

nonisolated struct GitPushTarget: Equatable, Sendable {
    let repository: URL
    let branch: String
    let upstream: String
    let remote: String
    let remoteRef: String
    let headObjectID: String
    let ahead: Int
    let pushURLs: [String]
}

private enum PushDestinationResult {
    case pushed(String)
    case failed(String)
    case cancelled(String, remoteMayHaveChanged: Bool)
}

extension GitService {
    func preparePushTarget(repository: URL) async throws -> GitPushTarget {
        let refreshed = try await statusWithUpstreamRefresh(
            repository: repository,
            refreshUpstream: true,
            priority: .selectedRepository
        )
        let target = try await makePushTarget(repository: repository, refreshed: refreshed)
        try await requireAnyPushDestinationAccess(for: target)
        return target
    }

    func pushToUpstream(target: GitPushTarget) async throws {
        let repository = RepositoryPathPolicy.canonicalURL(target.repository)
        let refreshed = try await statusWithUpstreamRefresh(
            repository: repository,
            refreshUpstream: true,
            priority: .selectedRepository
        )
        let currentTarget = try await makePushTarget(repository: repository, refreshed: refreshed)
        guard currentTarget == target else { throw GitServiceError.pushTargetChanged }
        try await pushConfiguredDestinations(currentTarget, repository: repository)
    }

    private func makePushTarget(
        repository: URL,
        refreshed: GitUpstreamRefreshResult
    ) async throws -> GitPushTarget {
        let status = refreshed.status
        guard !status.isRebaseInProgress else { throw GitServiceError.rebaseAlreadyInProgress }
        guard let branch = status.branch.head else { throw GitServiceError.detachedHead }
        guard let upstream = status.branch.upstream else { throw GitServiceError.missingUpstream }
        guard status.branch.ahead > 0 else { throw GitServiceError.branchHasNoOutgoingCommits }
        guard status.branch.behind == 0 else { throw GitServiceError.branchBehindUpstream }
        let destination = try await validatedPushDestination(repository: repository, refreshed: refreshed)
        let headObjectID = try await currentHeadObjectID(repository: repository)
        let pushURLs = try await pushURLs(repository: repository, remote: destination.remote)

        return GitPushTarget(
            repository: RepositoryPathPolicy.canonicalURL(repository),
            branch: branch,
            upstream: upstream,
            remote: destination.remote,
            remoteRef: destination.remoteRef,
            headObjectID: headObjectID,
            ahead: status.branch.ahead,
            pushURLs: pushURLs
        )
    }

    private func validatedPushDestination(
        repository: URL,
        refreshed: GitUpstreamRefreshResult
    ) async throws -> (remote: String, remoteRef: String) {
        guard let remote = refreshed.remote,
              let remoteRef = refreshed.remoteRef,
              remote != ".",
              remoteRef.hasPrefix("refs/heads/") else {
            throw GitServiceError.invalidPushDestination(refreshed.remoteRef ?? "upstream")
        }
        let validation = try await runner.run(
            repository: repository,
            arguments: ["check-ref-format", remoteRef],
            environment: readEnvironment,
            acceptedExitCodes: [0, 1],
            outputLimit: 128,
            priority: .selectedRepository
        )
        guard validation.exitCode == 0 else {
            throw GitServiceError.invalidPushDestination(remoteRef)
        }
        return (remote, remoteRef)
    }

    private func currentHeadObjectID(repository: URL) async throws -> String {
        let head = try await runner.run(
            repository: repository,
            arguments: ["rev-parse", "--verify", "--quiet", "HEAD"],
            environment: readEnvironment,
            acceptedExitCodes: [0, 1],
            outputLimit: 128,
            priority: .selectedRepository
        )
        guard head.exitCode == 0,
              let value = String(bytes: head.standardOutput, encoding: .utf8) else {
            throw GitServiceError.detachedHead
        }
        let objectID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard objectID.count == 40 || objectID.count == 64,
              objectID.allSatisfy(\.isHexDigit) else {
            throw GitServiceError.invalidObjectID(objectID)
        }
        return objectID
    }

    private func pushURLs(
        repository: URL,
        remote: String,
        priority: ProcessPriority = .selectedRepository
    ) async throws -> [String] {
        let result = try await runner.run(
            repository: repository,
            arguments: ["remote", "get-url", "--push", "--all", "--", remote],
            environment: readEnvironment,
            acceptedExitCodes: [0, 1, 128],
            outputLimit: 64 * 1_024,
            priority: priority
        )
        let configuredURLs = try result.standardOutput
            .split(separator: 10, omittingEmptySubsequences: true)
            .map { line in
                guard let url = String(bytes: line, encoding: .utf8) else {
                    throw GitServiceError.invalidPushDestination(remote)
                }
                return url.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        if result.exitCode == 0, !configuredURLs.isEmpty { return configuredURLs }
        if URLComponents(string: remote)?.scheme != nil || remote.hasPrefix("git@") { return [remote] }
        throw GitServiceError.invalidPushDestination(remote)
    }

}
extension GitService {

    func pushAccessForStatus(
        _ status: RepoStatus,
        repository: URL,
        priority: ProcessPriority
    ) async throws -> PushAccess {
        guard status.branch.ahead > 0 else { return .notGitHub }
        guard let branch = status.branch.head, status.branch.upstream != nil else { return .unavailable }

        do {
            let result = try await runner.run(
                repository: repository,
                arguments: [
                    "for-each-ref", "--format=%(upstream:remotename)",
                    "--count=1", "refs/heads/\(branch)"
                ],
                environment: readEnvironment,
                outputLimit: 1_024,
                priority: priority
            )
            guard let remote = String(bytes: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return .unavailable }
            guard !remote.isEmpty else { return .unavailable }
            guard remote != "." else { return .notGitHub }
            let urls = try await pushURLs(repository: repository, remote: remote, priority: priority)
            return try await pushAccess(for: urls)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return .unavailable
        }
    }

    private func pushAccess(for urls: [String]) async throws -> PushAccess {
        var seen = Set<URL>()
        var repositories = [URL]()
        for url in urls {
            guard let repository = GitHubRepositoryURL.webURL(from: url) else { continue }
            if seen.insert(repository).inserted { repositories.append(repository) }
        }
        guard !repositories.isEmpty else { return .notGitHub }
        return try await githubAccess(for: repositories)
    }

    private func githubAccess(for repositories: [URL]) async throws -> PushAccess {
        var permissionCheckError: Error?
        var hasDeniedPermission = false
        for repository in repositories {
            do {
                let hasWriteAccess = try await githubCLI.hasWriteAccess(to: repository)
                try Task.checkCancellation()
                if !hasWriteAccess { hasDeniedPermission = true }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                permissionCheckError = permissionCheckError ?? error
            }
        }
        if hasDeniedPermission { return .denied }
        if let permissionCheckError { throw permissionCheckError }
        return .allowed
    }

    private func requireAnyPushDestinationAccess(for target: GitPushTarget) async throws {
        let access = try await pushAccess(for: target.pushURLs)
        let repositories = target.pushURLs.compactMap(GitHubRepositoryURL.webURL(from:))
            .map { String($0.path.dropFirst()) }
            .joined(separator: ", ")
        switch access {
        case .allowed, .notGitHub:
            return
        case .denied:
            throw GitServiceError.remoteWriteAccessDenied(repositories)
        case .unavailable:
            throw GitServiceError.remoteWriteAccessUnavailable(repositories)
        }
    }
    private func pushConfiguredDestinations(
        _ target: GitPushTarget,
        repository: URL
    ) async throws {
        var succeeded = [String]()
        var failures = [String]()
        destinations: for (index, pushURL) in target.pushURLs.enumerated() {
            switch await pushDestination(
                target,
                repository: repository,
                pushURL: pushURL,
                index: index
            ) {
            case .pushed(let destination):
                succeeded.append(destination)
            case .failed(let failure):
                failures.append(failure)
            case .cancelled(let destination, let remoteMayHaveChanged):
                if succeeded.isEmpty, failures.isEmpty, !remoteMayHaveChanged {
                    throw CancellationError()
                }
                let outcome = remoteMayHaveChanged ? "remote result may be uncertain" : "push cancelled"
                failures.append("\(destination): \(outcome)")
                failures.append("Remaining destinations were not attempted after cancellation")
                break destinations
            }
        }
        if !failures.isEmpty {
            throw GitServiceError.pushDestinationsFailed(succeeded: succeeded, failures: failures)
        }
    }

    private func pushDestination(
        _ target: GitPushTarget,
        repository: URL,
        pushURL: String,
        index: Int
    ) async -> PushDestinationResult {
        let githubRepository = GitHubRepositoryURL.webURL(from: pushURL)
        let destination = githubRepository.map { String($0.path.dropFirst()) }
            ?? "remote destination \(index + 1)"
        guard !Task.isCancelled else { return .cancelled(destination, remoteMayHaveChanged: false) }

        let arguments = [
            "push", "--porcelain", "--", pushURL,
            "\(target.headObjectID):\(target.remoteRef)"
        ]
        do {
            if let githubRepository {
                let request = ProcessExecutionRequest(
                    repository: repository,
                    arguments: arguments,
                    input: nil,
                    environment: networkEnvironment,
                    acceptedExitCodes: [0],
                    outputLimit: ProcessRunner.defaultOutputLimit,
                    priority: .selectedRepository
                )
                let githubCLI = self.githubCLI
                _ = try await runner.executeAfterAdmission(
                    request,
                    timeout: ProcessRunner.mutationTimeout
                ) {
                    let hasWriteAccess = try await githubCLI.hasWriteAccess(to: githubRepository)
                    try Task.checkCancellation()
                    guard hasWriteAccess else {
                        throw GitServiceError.remoteWriteAccessDenied(destination)
                    }
                }
            } else {
                _ = try await runner.run(
                    repository: repository,
                    arguments: arguments,
                    environment: networkEnvironment,
                    timeout: ProcessRunner.mutationTimeout,
                    priority: .selectedRepository
                )
            }
            return .pushed(destination)
        } catch {
            if Task.isCancelled {
                let remoteMayHaveChanged = error is ProcessRunnerError
                return .cancelled(destination, remoteMayHaveChanged: remoteMayHaveChanged)
            }
            if let serviceError = error as? GitServiceError,
               case .remoteWriteAccessDenied = serviceError {
                return .failed("\(destination): GitHub write access denied")
            }
            if error is GitHubCLIError {
                return .failed("\(destination): GitHub write access could not be verified")
            }
            return .failed("\(destination): Git push failed")
        }
    }
}
