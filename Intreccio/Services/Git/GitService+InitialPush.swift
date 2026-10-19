import Foundation

extension GitService {
    func statusForInitialOriginPush(
        _ status: RepoStatus,
        repository: URL,
        priority: ProcessPriority
    ) async throws -> RepoStatus {
        guard status.branch.upstream == nil, status.branch.head != nil else { return status }
        var status = status
        let originPushURLs: [String]
        do {
            originPushURLs = try await pushURLs(
                repository: repository,
                remote: "origin",
                priority: priority
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return status
        }
        status.hasOriginPushDestination = !originPushURLs.isEmpty
        guard status.hasOriginPushDestination, status.branch.objectID != nil else { return status }
        do {
            status.pushAccess = try await pushAccess(for: originPushURLs)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            status.pushAccess = .unavailable
        }
        return status
    }
    func makeInitialOriginPushTarget(
        repository: URL,
        status: RepoStatus,
        branch: String
    ) async throws -> GitPushTarget {
        guard !status.isRebaseInProgress else { throw GitServiceError.rebaseAlreadyInProgress }
        guard status.branch.objectID != nil else {
            throw GitServiceError.branchHasNoOutgoingCommits
        }
        let headObjectID = try await currentHeadObjectID(repository: repository)
        guard status.branch.objectID == headObjectID else {
            throw GitServiceError.pushTargetChanged
        }
        let remoteRef = "refs/heads/\(branch)"
        let destination = try await validatedPushDestination(
            repository: repository,
            refreshed: GitUpstreamRefreshResult(
                status: status,
                remote: "origin",
                remoteRef: remoteRef
            )
        )
        let pushURLs = try await initialPushURLs(
            repository: repository,
            remote: destination.remote
        )
        let trackingRef = "refs/remotes/\(destination.remote)/\(branch)"
        try await rejectSymbolicRemoteTrackingConflicts(
            remote: destination.remote,
            branch: branch,
            repository: repository
        )
        _ = try await validateFetchMapping(
            remote: destination.remote,
            sourceRef: remoteRef,
            trackingRef: trackingRef,
            repository: repository
        )
        let expectedRemoteHeads = try await validateInitialPushDestinations(
            repository: repository,
            pushURLs: pushURLs,
            remoteRef: destination.remoteRef,
            headObjectID: headObjectID
        )
        let ahead = expectedRemoteHeads.allSatisfy { $0 == headObjectID }
            ? 0
            : try await localCommitCount(repository: repository, headObjectID: headObjectID)
        return GitPushTarget(
            repository: RepositoryPathPolicy.canonicalURL(repository),
            branch: branch,
            upstream: "origin/\(branch)",
            remote: destination.remote,
            remoteRef: destination.remoteRef,
            headObjectID: headObjectID,
            ahead: ahead,
            pushURLs: pushURLs,
            initialPushExpectedRemoteHeads: expectedRemoteHeads
        )
    }

    private func initialPushURLs(repository: URL, remote: String) async throws -> [String] {
        let fetchURLResult = try await runner.run(
            repository: repository,
            arguments: ["remote", "get-url", remote],
            environment: readEnvironment,
            acceptedExitCodes: [0, 1, 128],
            outputLimit: 16 * 1_024,
            priority: .selectedRepository
        )
        guard fetchURLResult.exitCode == 0,
              let fetchURL = String(bytes: fetchURLResult.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !fetchURL.isEmpty else {
            throw GitServiceError.invalidPushDestination(remote)
        }
        let pushURLs = try await pushURLs(repository: repository, remote: remote)
        guard pushURLs.contains(fetchURL) else {
            throw GitServiceError.invalidPushDestination(
                "\(remote) fetch URL is not a configured push destination"
            )
        }
        return pushURLs
    }

    private func localCommitCount(repository: URL, headObjectID: String) async throws -> Int {
        let result = try await runner.run(
            repository: repository,
            arguments: ["rev-list", "--count", headObjectID],
            environment: readEnvironment,
            outputLimit: 128,
            priority: .selectedRepository
        )
        guard let countText = String(bytes: result.standardOutput, encoding: .utf8) else {
            throw GitServiceError.branchHasNoOutgoingCommits
        }
        let trimmedCount = countText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(trimmedCount), count > 0 else {
            throw GitServiceError.branchHasNoOutgoingCommits
        }
        return count
    }

    private func validateInitialPushDestinations(
        repository: URL,
        pushURLs: [String],
        remoteRef: String,
        headObjectID: String
    ) async throws -> [String] {
        var expectedRemoteHeads = [String]()
        expectedRemoteHeads.reserveCapacity(pushURLs.count)
        let absentRemoteHead = String(repeating: "0", count: headObjectID.count)
        for pushURL in pushURLs {
            let result = try await runner.run(
                repository: repository,
                arguments: ["ls-remote", "--refs", "--", pushURL, remoteRef],
                environment: networkEnvironment,
                outputLimit: 12 * 1_024,
                timeout: ProcessRunner.networkTimeout,
                priority: .selectedRepository
            )
            guard let advertised = String(bytes: result.standardOutput, encoding: .utf8) else {
                throw GitServiceError.invalidPushDestination(remoteRef)
            }
            var advertisedHead: String?
            for line in advertised.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 2 else {
                    throw GitServiceError.invalidPushDestination(remoteRef)
                }
                guard String(fields[1]) == remoteRef else { continue }
                guard advertisedHead == nil else {
                    throw GitServiceError.invalidPushDestination(remoteRef)
                }
                advertisedHead = String(fields[0])
            }
            if let advertisedHead {
                guard advertisedHead == headObjectID else {
                    throw GitServiceError.pushTargetChanged
                }
                expectedRemoteHeads.append(advertisedHead)
            } else {
                expectedRemoteHeads.append(absentRemoteHead)
            }
        }
        return expectedRemoteHeads
    }

    func configureInitialPushUpstream(
        _ target: GitPushTarget,
        repository: URL
    ) async throws {
        // Every configured destination accepted the push, so conflicting refs here are stale.
        try await rejectSymbolicRemoteTrackingConflicts(
            remote: target.remote,
            branch: target.branch,
            repository: repository
        )
        try await removeConflictingRemoteTrackingRefs(target, repository: repository)
        _ = try await runner.run(
            repository: repository,
            arguments: [
                "update-ref", "--no-deref",
                "refs/remotes/\(target.remote)/\(target.branch)",
                target.headObjectID
            ],
            environment: mutationEnvironment,
            outputLimit: 128,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
        let trackingRef = "refs/remotes/\(target.remote)/\(target.branch)"
        let mappedRef = try await validateFetchMapping(
            remote: target.remote,
            sourceRef: target.remoteRef,
            trackingRef: trackingRef,
            repository: repository
        )
        if mappedRef == nil {
            _ = try await runner.run(
                repository: repository,
                arguments: ["remote", "set-branches", "--add", target.remote, target.branch],
                environment: mutationEnvironment,
                outputLimit: 128,
                timeout: ProcessRunner.mutationTimeout,
                priority: .selectedRepository
            )
        }
        _ = try await runner.run(
            repository: repository,
            arguments: [
                "config", "--local", "--replace-all",
                "branch.\(target.branch).remote", target.remote
            ],
            environment: mutationEnvironment,
            outputLimit: 128,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
        _ = try await runner.run(
            repository: repository,
            arguments: [
                "config", "--local", "--replace-all",
                "branch.\(target.branch).merge", target.remoteRef
            ],
            environment: mutationEnvironment,
            outputLimit: 128,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
    }

    private func validateFetchMapping(
        remote: String,
        sourceRef: String,
        trackingRef: String,
        repository: URL
    ) async throws -> String? {
        let state = try await fetchRefspecState(
            remote: remote,
            sourceRef: sourceRef,
            repository: repository
        )
        guard !state.isExcluded else {
            throw GitServiceError.invalidPushDestination(
                "\(remote) fetch refspec excludes \(sourceRef)"
            )
        }
        if let mappedRef = state.mappedRef, mappedRef != trackingRef {
            throw GitServiceError.invalidPushDestination(
                "\(remote) fetch refspec maps \(sourceRef) to \(mappedRef), not \(trackingRef)"
            )
        }
        return state.mappedRef
    }

    private func fetchRefspecState(
        remote: String,
        sourceRef: String,
        repository: URL
    ) async throws -> (isExcluded: Bool, mappedRef: String?) {
        let result = try await runner.run(
            repository: repository,
            arguments: ["config", "--get-all", "remote.\(remote).fetch"],
            environment: readEnvironment,
            acceptedExitCodes: [0, 1],
            outputLimit: 64 * 1_024,
            priority: .selectedRepository
        )
        guard let text = String(bytes: result.standardOutput, encoding: .utf8) else {
            throw GitServiceError.pushTargetChanged
        }
        let refspecs = text.split(whereSeparator: \.isNewline).map(String.init)
        return (
            isExcluded: refspecs.contains {
                self.fetchRefspecExcludes($0, sourceRef: sourceRef)
            },
            mappedRef: refspecs.lazy.compactMap {
                self.fetchRefspecDestination($0, sourceRef: sourceRef)
            }.first
        )
    }

    private func fetchRefspecExcludes(_ refspec: String, sourceRef: String) -> Bool {
        guard refspec.hasPrefix("^") else { return false }
        return wildcardCapture(in: String(refspec.dropFirst()), matching: sourceRef) != nil
    }

    private func fetchRefspecDestination(_ refspec: String, sourceRef: String) -> String? {
        let refspec = refspec.hasPrefix("+") ? String(refspec.dropFirst()) : refspec
        guard !refspec.hasPrefix("^") else { return nil }
        let fields = refspec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2,
              let sourceWildcard = wildcardCapture(in: String(fields[0]), matching: sourceRef) else {
            return nil
        }
        let destinationPattern = String(fields[1])
        guard let wildcard = destinationPattern.firstIndex(of: "*") else {
            return sourceWildcard.isEmpty ? destinationPattern : nil
        }
        let prefix = String(destinationPattern[..<wildcard])
        let suffix = String(destinationPattern[destinationPattern.index(after: wildcard)...])
        guard !suffix.contains("*") else { return nil }
        return prefix + sourceWildcard + suffix
    }

    private func wildcardCapture(in pattern: String, matching ref: String) -> String? {
        guard let wildcard = pattern.firstIndex(of: "*") else {
            return pattern == ref ? "" : nil
        }
        let prefix = String(pattern[..<wildcard])
        let suffix = String(pattern[pattern.index(after: wildcard)...])
        guard !suffix.contains("*"),
              ref.hasPrefix(prefix),
              ref.hasSuffix(suffix),
              ref.count >= prefix.count + suffix.count else {
            return nil
        }
        return String(ref.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private func rejectSymbolicRemoteTrackingConflicts(
        remote: String,
        branch: String,
        repository: URL
    ) async throws {
        let trackingRef = "refs/remotes/\(remote)/\(branch)"
        let result = try await runner.run(
            repository: repository,
            arguments: ["for-each-ref", "--format=%(refname)", trackingRef],
            environment: readEnvironment,
            outputLimit: 64 * 1_024,
            priority: .selectedRepository
        )
        guard let text = String(bytes: result.standardOutput, encoding: .utf8) else {
            throw GitServiceError.pushTargetChanged
        }
        var conflicts = text.split(whereSeparator: \.isNewline).map(String.init).filter {
            $0 == trackingRef || $0.hasPrefix(trackingRef + "/")
        }
        var ancestor = "refs/remotes/\(remote)"
        for component in branch.split(separator: "/").dropLast() {
            ancestor += "/\(component)"
            conflicts.append(ancestor)
        }
        for conflict in conflicts {
            let symbolicRef = try await runner.run(
                repository: repository,
                arguments: ["symbolic-ref", "--quiet", conflict],
                environment: readEnvironment,
                acceptedExitCodes: [0, 1],
                outputLimit: 1_024,
                priority: .selectedRepository
            )
            guard symbolicRef.exitCode != 0 else {
                throw GitServiceError.invalidPushDestination(
                    "\(remote) tracking ref namespace has symbolic ref \(conflict)"
                )
            }
        }
    }

    private func removeConflictingRemoteTrackingRefs(
        _ target: GitPushTarget,
        repository: URL
    ) async throws {
        let trackingPrefix = "refs/remotes/\(target.remote)"
        let trackingRef = "\(trackingPrefix)/\(target.branch)"
        let descendants = try await runner.run(
            repository: repository,
            arguments: [
                "for-each-ref",
                "--format=%(refname) %(objectname)",
                trackingRef
            ],
            environment: readEnvironment,
            outputLimit: 64 * 1_024,
            priority: .selectedRepository
        )
        guard let descendantText = String(bytes: descendants.standardOutput, encoding: .utf8) else {
            throw GitServiceError.pushTargetChanged
        }
        var staleRefs = [(name: String, objectID: String)]()
        for line in descendantText.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else { throw GitServiceError.pushTargetChanged }
            let name = String(fields[0])
            guard name.hasPrefix(trackingRef + "/") else { continue }
            staleRefs.append((name, String(fields[1])))
        }

        var ancestor = trackingPrefix
        for component in target.branch.split(separator: "/").dropLast() {
            ancestor += "/\(component)"
            let result = try await runner.run(
                repository: repository,
                arguments: ["show-ref", "--verify", "--hash", ancestor],
                environment: readEnvironment,
                acceptedExitCodes: [0, 1],
                outputLimit: 128,
                priority: .selectedRepository
            )
            guard result.exitCode == 0 else { continue }
            guard let objectID = String(bytes: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !objectID.isEmpty else {
                throw GitServiceError.pushTargetChanged
            }
            staleRefs.append((ancestor, objectID))
        }

        for staleRef in staleRefs {
            _ = try await runner.run(
                repository: repository,
                arguments: [
                    "update-ref", "--no-deref", "-d",
                    staleRef.name, staleRef.objectID
                ],
                environment: mutationEnvironment,
                outputLimit: 128,
                timeout: ProcessRunner.mutationTimeout,
                priority: .selectedRepository
            )
        }
    }
}
