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

extension GitService {
    func preparePushTarget(repository: URL) async throws -> GitPushTarget {
        let refreshed = try await statusWithUpstreamRefresh(
            repository: repository,
            refreshUpstream: true,
            priority: .selectedRepository
        )
        return try await makePushTarget(repository: repository, refreshed: refreshed)
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

        for pushURL in target.pushURLs {
            _ = try await runner.run(
                repository: repository,
                arguments: [
                    "push", "--porcelain", "--", pushURL,
                    "\(target.headObjectID):\(target.remoteRef)"
                ],
                environment: networkEnvironment,
                timeout: ProcessRunner.mutationTimeout,
                priority: .selectedRepository
            )
        }
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

    private func pushURLs(repository: URL, remote: String) async throws -> [String] {
        let result = try await runner.run(
            repository: repository,
            arguments: ["remote", "get-url", "--push", "--all", "--", remote],
            environment: readEnvironment,
            acceptedExitCodes: [0, 1, 128],
            outputLimit: 64 * 1_024,
            priority: .selectedRepository
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
