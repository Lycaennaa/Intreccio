import Darwin
import Foundation

nonisolated enum GitServiceError: Error, Equatable, CustomStringConvertible {
    case invalidObjectID(String)
    case expectedSingleCommit(Int)
    case emptyMutationSelection
    case staleMutationSelection([String])
    case conflictedPaths([String])
    case discardWouldOverwritePaths([String])
    case discardPathInspectionFailed(path: String, code: Int32)
    case unsupportedDiscardSubmodule(String)
    case unsupportedDiscardPath(String)
    case unsupportedMixedDiscard([String])
    case unsupportedIgnoreSelection(String)
    case ignoreRollbackFailed(gitError: String, rollbackError: String)
    case blankCommitMessage
    case nothingStaged
    case staleAmendTarget(expected: String, actual: String?)
    case amendMetadataLimit(Int)
    case unsupportedUpstreamRef(String)
    case upstreamRefNotFound(String)
    case detachedHead
    case missingUpstream
    case upstreamHasNoNewCommits
    case branchHasNoOutgoingCommits
    case branchBehindUpstream
    case invalidPushDestination(String)
    case pushTargetChanged
    case rebaseAlreadyInProgress
    case rebaseNotInProgress
    case dirtyWorktreeForRebase([String])
    case unresolvedRebaseConflicts([String])
    case noChangesToStash
    case stashRequiresCommit
    case unsupportedStashSubmodule(String)
    case unsupportedStashPath(String)
    case noStash
    case dirtyWorktreeForStashRestore([String])
    case unresolvedStashConflicts([String])
    case worktreeTransferRequiresLinkedSource
    case noWorktreeChangesToBring
    case dirtyMainWorktreeForTransfer([String])
    case conflictedWorktreeForTransfer([String])
    case unsupportedWorktreeTransferSubmodule(String)
    case unsupportedWorktreeTransferPath(String)
    case worktreeTransferStateChanged
    case sourceWorktreeRequiresCommit
    case mainWorktreeRequiresCommit
    case worktreeTransferApplyFailed(paths: [String], reason: String)
    case operationStateInspectionFailed(path: String, code: Int32)

    var description: String {
        switch self {
        case .invalidObjectID(let objectID): "Invalid Git object ID: \(objectID)"
        case .expectedSingleCommit(let count): "Expected one commit, received \(count)"
        case .emptyMutationSelection: "No changed files were selected"
        case .staleMutationSelection(let paths): "Changes are stale for: \(paths.joined(separator: ", "))"
        case .conflictedPaths(let paths): "Resolve conflicts before staging: \(paths.joined(separator: ", "))"
        case .discardWouldOverwritePaths(let paths):
            "Discard would overwrite separate changes at: \(paths.joined(separator: ", "))"
        case .discardPathInspectionFailed(let path, let code):
            "Could not inspect \(path) before discarding: \(String(cString: strerror(code)))"
        case .unsupportedDiscardSubmodule(let path):
            "Discarding submodule changes is not supported because it could delete nested repository work: \(path)"
        case .unsupportedDiscardPath(let path): "Cannot discard an untracked directory or nested repository: \(path)"
        case .unsupportedMixedDiscard(let paths):
            "Discard tracked and untracked files separately: \(paths.joined(separator: ", "))"
        case .unsupportedIgnoreSelection(let path): "Only unstaged files can be added to .gitignore: \(path)"
        case .ignoreRollbackFailed(let gitError, let rollbackError):
            "\(gitError)\n\nThe .gitignore rollback also failed: \(rollbackError)"
        case .blankCommitMessage: "Commit message cannot be blank"
        case .nothingStaged: "There are no staged changes to commit"
        case .staleAmendTarget(let expected, let actual):
            "Cannot amend commit \(expected) because HEAD is now \(actual ?? "unborn")"
        case .amendMetadataLimit(let count):
            "Cannot safely prepare amend metadata with \(count) top-level Git metadata entries"
        case .unsupportedUpstreamRef(let ref):
            "Cannot refresh an upstream mapped outside remote-tracking refs: \(ref)"
        case .upstreamRefNotFound(let ref):
            "The configured upstream ref was not found on the remote: \(ref)"
        case .detachedHead: "This operation requires a checked-out local branch"
        case .missingUpstream: "The current branch has no configured upstream"
        case .upstreamHasNoNewCommits: "The current branch is not behind its upstream"
        case .branchHasNoOutgoingCommits: "The current branch has no commits to push"
        case .branchBehindUpstream: "Rebase the current branch before pushing"
        case .invalidPushDestination(let ref): "The configured push destination is invalid: \(ref)"
        case .pushTargetChanged: "The branch or push destination changed after confirmation. Review and confirm again."
        case .rebaseAlreadyInProgress: "A rebase is already in progress"
        case .rebaseNotInProgress: "No rebase is in progress"
        case .dirtyWorktreeForRebase(let paths):
            "Commit, discard, or stash changes before rebasing: \(paths.joined(separator: ", "))"
        case .unresolvedRebaseConflicts(let paths):
            "Resolve and stage rebase conflicts before continuing: \(paths.joined(separator: ", "))"
        case .noChangesToStash: "There are no changes to stash"
        case .stashRequiresCommit: "Create the first commit before using stashes"
        case .unsupportedStashSubmodule(let path):
            "Cannot stash submodule changes because nested repository work would be left behind: \(path)"
        case .unsupportedStashPath(let path): "Cannot stash an untracked directory or nested repository: \(path)"
        case .noStash: "There is no stash to restore"
        case .dirtyWorktreeForStashRestore(let paths):
            "Commit, discard, or stash current changes before restoring a stash: \(paths.joined(separator: ", "))"
        case .unresolvedStashConflicts(let paths):
            "Resolve conflicts before stashing changes: \(paths.joined(separator: ", "))"
        case .worktreeTransferRequiresLinkedSource:
            "Bring changes from a linked worktree into its clean main worktree"
        case .noWorktreeChangesToBring: "The selected worktree has no changes to bring"
        case .dirtyMainWorktreeForTransfer(let paths):
            "Commit, stash, or discard main worktree changes before bringing worktree changes: "
                + paths.joined(separator: ", ")
        case .conflictedWorktreeForTransfer(let paths):
            "Resolve worktree conflicts before bringing changes: \(paths.joined(separator: ", "))"
        case .unsupportedWorktreeTransferSubmodule(let path):
            "Cannot bring submodule changes because nested repository work could be overwritten: \(path)"
        case .unsupportedWorktreeTransferPath(let path):
            "Cannot safely bring changes from this path: \(path)"
        case .worktreeTransferStateChanged:
            "A worktree changed while preparing the transfer. Refresh and try again."
        case .sourceWorktreeRequiresCommit: "Create the first commit before bringing worktree changes"
        case .mainWorktreeRequiresCommit: "Create the first main-worktree commit before bringing changes"
        case .worktreeTransferApplyFailed(let paths, let reason):
            "Transfer failed for \(paths.joined(separator: ", ")): \(reason). "
                + "Main may contain partial transfer changes. "
                + "They were left in place to avoid overwriting concurrent edits."
        case .operationStateInspectionFailed(path: let path, code: let code):
            "Could not inspect Git operation state at \(path): \(String(cString: strerror(code)))"
        }
    }
}

actor GitService {
    static let diffOutputLimit = 2 * 1_024 * 1_024
    static let diffPathspecByteLimit = 512 * 1_024
    static let diffPathspecCountLimit = 4_096
    static let historyPageSize = 15

    let runner: any ProcessRunning
    let githubCLI: GitHubCLI
    let sccLineCounter: (any SLOCCounter)?
    var untrackedDiffAnalysisCacheRepository: URL?
    var untrackedDiffAnalysisCache = UntrackedDiffAnalysisCache()

    init() {
        self.runner = GitProcessRunner()
        self.githubCLI = GitHubCLI()
        self.sccLineCounter = SCCLineCounter.bundled()
    }

    init(
        runner: any ProcessRunning,
        sccLineCounter: (any SLOCCounter)? = nil,
        githubCLI: GitHubCLI = GitHubCLI()
    ) {
        self.runner = runner
        self.githubCLI = githubCLI
        self.sccLineCounter = sccLineCounter
    }

    func githubRepositories() async throws -> [GitHubRepository] {
        try await githubCLI.repositories()
    }

    func repositoryRoot(at directory: URL) async throws -> URL {
        let result = try await runner.run(
            repository: directory,
            arguments: ["rev-parse", "--show-toplevel"],
            environment: readEnvironment
        )
        let path = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RepositoryPathPolicy.canonicalURL(
            URL(fileURLWithPath: path, isDirectory: true)
        )
    }

    func githubURL(
        repository: URL,
        priority: ProcessPriority = .normal
    ) async throws -> URL? {
        let result = try await runner.run(
            repository: repository,
            arguments: ["config", "--local", "--no-includes", "--get-regexp", #"^remote\..*\.url$"#],
            environment: readEnvironment,
            acceptedExitCodes: [0, 1],
            outputLimit: 64 * 1_024,
            priority: priority
        )
        guard result.exitCode == 0 else { return nil }

        var remoteURLs = [(name: String, value: String)]()
        for line in String(decoding: result.standardOutput, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let fields = line.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count == 2 else { continue }
            let key = String(fields[0])
            guard key.hasPrefix("remote."), key.hasSuffix(".url") else { continue }
            let nameStart = key.index(key.startIndex, offsetBy: "remote.".count)
            let nameEnd = key.index(key.endIndex, offsetBy: -".url".count)
            guard nameStart < nameEnd else { continue }
            remoteURLs.append((String(key[nameStart..<nameEnd]), String(fields[1])))
        }
        remoteURLs.sort {
            if ($0.name == "origin") != ($1.name == "origin") { return $0.name == "origin" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return remoteURLs.compactMap { GitHubRepositoryURL.webURL(from: $0.value) }.first
    }

}
