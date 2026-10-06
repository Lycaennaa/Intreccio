import Foundation

extension GitService {
    func stage(repository: URL, paths requestedPaths: [String]) async throws {
        try await stage(repository: repository, paths: requestedPaths.map(GitPath.init))
    }

    func stage(repository: URL, paths requestedPaths: [GitPath]) async throws {
        let paths = try await mutationPaths(
            repository: repository,
            requestedPaths: requestedPaths,
            requireStaged: false,
            rejectConflicts: true
        )
        _ = try await runner.run(
            repository: repository,
            arguments: ["add", "-A", "--"] + paths,
            environment: mutationEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
    }

    func unstage(repository: URL, paths requestedPaths: [String]) async throws {
        try await unstage(repository: repository, paths: requestedPaths.map(GitPath.init))
    }

    func unstage(repository: URL, paths requestedPaths: [GitPath]) async throws {
        let status = try await status(repository: repository, priority: .selectedRepository)
        let paths = try validatedMutationPaths(
            requestedPaths: requestedPaths,
            status: status,
            requireStaged: true,
            rejectConflicts: false
        )
        let arguments = status.branch.objectID == nil
            ? ["rm", "--cached", "-r", "--ignore-unmatch", "--"] + paths
            : ["restore", "--staged", "--"] + paths
        _ = try await runner.run(
            repository: repository,
            arguments: arguments,
            environment: mutationEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
    }

    func stashChanges(repository: URL) async throws {
        let status = try await status(repository: repository, priority: .selectedRepository)
        guard !status.isRebaseInProgress else { throw GitServiceError.rebaseAlreadyInProgress }
        guard status.branch.objectID != nil else { throw GitServiceError.stashRequiresCommit }
        let conflicts = status.changes.filter { $0.kind == .unmerged }.map(\.path).sorted()
        guard conflicts.isEmpty else { throw GitServiceError.unresolvedStashConflicts(conflicts) }
        guard !status.changes.isEmpty else { throw GitServiceError.noChangesToStash }
        if let submodule = status.changes.first(where: { $0.submoduleState?.hasPrefix("S") == true }) {
            throw GitServiceError.unsupportedStashSubmodule(submodule.path)
        }
        if let path = status.changes.first(where: { $0.kind == .untracked && $0.path.hasSuffix("/") })?.path {
            throw GitServiceError.unsupportedStashPath(path)
        }
        _ = try await runner.run(
            repository: repository,
            arguments: ["stash", "push", "--include-untracked"],
            environment: mutationEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
    }

    func restoreLatestStash(repository: URL) async throws {
        let status = try await status(repository: repository, priority: .selectedRepository)
        guard !status.isRebaseInProgress else { throw GitServiceError.rebaseAlreadyInProgress }
        guard status.branch.objectID != nil else { throw GitServiceError.stashRequiresCommit }
        guard status.hasStash else { throw GitServiceError.noStash }
        let changedPaths = Array(Set(status.changes.map(\.path))).sorted()
        guard changedPaths.isEmpty else { throw GitServiceError.dirtyWorktreeForStashRestore(changedPaths) }
        _ = try await runner.run(
            repository: repository,
            arguments: ["stash", "pop", "--index"],
            environment: mutationEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
    }

    func rebaseOnUpstream(repository: URL) async throws {
        let status = try await status(repository: repository, priority: .selectedRepository)
        guard !status.isRebaseInProgress else { throw GitServiceError.rebaseAlreadyInProgress }
        guard status.branch.head != nil else { throw GitServiceError.detachedHead }
        guard status.branch.upstream != nil else { throw GitServiceError.missingUpstream }
        guard status.branch.behind > 0 else { throw GitServiceError.upstreamHasNoNewCommits }
        let changedPaths = Array(Set(status.changes.map(\.path))).sorted()
        guard changedPaths.isEmpty else { throw GitServiceError.dirtyWorktreeForRebase(changedPaths) }
        _ = try await runner.run(
            repository: repository,
            arguments: ["rebase", "@{upstream}"],
            environment: rebaseEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
    }

    func continueRebase(repository: URL) async throws {
        let status = try await status(repository: repository, priority: .selectedRepository)
        guard status.isRebaseInProgress else { throw GitServiceError.rebaseNotInProgress }
        let conflicts = status.changes.filter { $0.kind == .unmerged }.map(\.path).sorted()
        guard conflicts.isEmpty else { throw GitServiceError.unresolvedRebaseConflicts(conflicts) }
        _ = try await runner.run(
            repository: repository,
            arguments: ["rebase", "--continue"],
            environment: rebaseEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
    }

    func abortRebase(repository: URL) async throws {
        let status = try await status(repository: repository, priority: .selectedRepository)
        guard status.isRebaseInProgress else { throw GitServiceError.rebaseNotInProgress }
        _ = try await runner.run(
            repository: repository,
            arguments: ["rebase", "--abort"],
            environment: rebaseEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
    }

    func discard(repository: URL, changes requestedChanges: [FileChange]) async throws {
        guard !requestedChanges.isEmpty else { throw GitServiceError.emptyMutationSelection }
        guard requestedChanges.allSatisfy(\.isGitAddressable) else {
            throw GitServiceError.staleMutationSelection(requestedChanges.map(\.displayPath).sorted())
        }
        let requestedByPath = Dictionary(grouping: requestedChanges, by: \.path)
        let requestedPaths = Set(requestedByPath.keys)
        let status = try await status(repository: repository, priority: .selectedRepository)
        guard !status.isRebaseInProgress else { throw GitServiceError.rebaseAlreadyInProgress }
        let stalePaths = requestedByPath.compactMap { path, requested in
            let current = status.changes.filter { $0.path == path }
            return current.count == requested.count && current.allSatisfy(requested.contains) ? nil : path
        }
        guard stalePaths.isEmpty else {
            throw GitServiceError.staleMutationSelection(stalePaths.sorted())
        }
        let changes = status.changes.filter { requestedPaths.contains($0.path) }
        if let path = changes
            .filter({ $0.submoduleState?.hasPrefix("S") == true })
            .map(\.path)
            .sorted()
            .first {
            throw GitServiceError.unsupportedDiscardSubmodule(path)
        }

        let changesByPath = Dictionary(grouping: changes, by: \.path)
        let untrackedPaths = Set(changesByPath.compactMap { path, pathChanges in
            pathChanges.allSatisfy { $0.kind == .untracked } ? path : nil
        })
        if let path = untrackedPaths.filter({ $0.hasSuffix("/") }).sorted().first {
            throw GitServiceError.unsupportedDiscardPath(path)
        }

        let renameSources = Set(changes.compactMap { change in
            change.kind == .renamed ? change.originalPath : nil
        })
        var occupiedRenameSources = Set(status.changes.lazy
            .filter { renameSources.contains($0.path) && !requestedPaths.contains($0.path) }
            .map(\.path))
        for source in renameSources where !occupiedRenameSources.contains(source) {
            guard let sourceIdentity = try fileIdentity(repository: repository, path: source) else { continue }
            var aliasesDestination = false
            for change in changes where change.kind == .renamed && change.originalPath == source {
                guard source.compare(change.path, options: [.caseInsensitive, .literal]) == .orderedSame,
                      let destinationIdentity = try fileIdentity(repository: repository, path: change.path) else {
                    continue
                }
                if sourceIdentity.refersToSameFile(as: destinationIdentity) {
                    aliasesDestination = true
                    break
                }
            }
            if !aliasesDestination { occupiedRenameSources.insert(source) }
        }
        guard occupiedRenameSources.isEmpty else {
            throw GitServiceError.discardWouldOverwritePaths(occupiedRenameSources.sorted())
        }

        let trackedChanges = changes.filter { !untrackedPaths.contains($0.path) }
        let trackedPaths = Set(Self.discardAffectedPaths(for: trackedChanges))
        let pathsToDelete = untrackedPaths.subtracting(trackedPaths).sorted()
        if !trackedPaths.isEmpty, !pathsToDelete.isEmpty {
            throw GitServiceError.unsupportedMixedDiscard(requestedPaths.sorted())
        }

        if !trackedPaths.isEmpty {
            let paths = trackedPaths.sorted().map { ":(literal)\($0)" }
            let arguments = status.branch.objectID == nil
                ? ["rm", "-f", "--"] + paths
                : ["restore", "--source=HEAD", "--staged", "--worktree", "--"] + paths
            _ = try await runner.run(
                repository: repository,
                arguments: arguments,
                environment: mutationEnvironment,
                timeout: ProcessRunner.mutationTimeout,
                priority: .selectedRepository
            )
        }

        if !pathsToDelete.isEmpty {
            _ = try await runner.run(
                repository: repository,
                arguments: ["clean", "-f", "--"] + pathsToDelete.map { ":(literal)\($0)" },
                environment: mutationEnvironment,
                timeout: ProcessRunner.mutationTimeout,
                priority: .selectedRepository
            )
        }
    }

    nonisolated static func discardAffectedPathValues(for changes: [FileChange]) -> [GitPath] {
        Array(Set(changes.flatMap { change in
            change.kind == .renamed
                ? [change.gitPath, change.originalGitPath].compactMap { $0 }
                : [change.gitPath]
        })).sorted { $0.displayString.localizedStandardCompare($1.displayString) == .orderedAscending }
    }

    nonisolated static func discardAffectedPaths(for changes: [FileChange]) -> [String] {
        discardAffectedPathValues(for: changes).map(\.decodedString)
    }


    func fileIdentity(repository: URL, path: String) throws -> FileIdentity? {
        var information = stat()
        let fileURL = repository.appendingPathComponent(path)
        let result = fileURL.path.withCString { lstat($0, &information) }
        guard result == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw GitServiceError.discardPathInspectionFailed(path: path, code: code)
        }
        return FileIdentity(information)
    }

    func addToGitIgnore(
        repository: URL,
        selectedPath: String,
        targetPath: String,
        isDirectory: Bool
    ) async throws {
        try await addToGitIgnore(
            repository: repository,
            selectedPath: GitPath(selectedPath),
            targetPath: GitPath(targetPath),
            isDirectory: isDirectory
        )
    }

    func addToGitIgnore(
        repository: URL,
        selectedPath: GitPath,
        targetPath: GitPath,
        isDirectory: Bool
    ) async throws {
        guard selectedPath.isIgnoreAddressable,
              targetPath.isIgnoreAddressable else {
            throw GitServiceError.unsupportedIgnoreSelection(selectedPath.displayString)
        }
        let status = try await status(repository: repository, priority: .selectedRepository)
        guard !status.isRebaseInProgress else { throw GitServiceError.rebaseAlreadyInProgress }
        let selectedChanges = status.changes.filter { $0.gitPath == selectedPath }
        guard !selectedChanges.isEmpty else {
            throw GitServiceError.staleMutationSelection([selectedPath.displayString])
        }
        guard selectedChanges.contains(where: \.hasUnstagedChange),
              !selectedChanges.contains(where: { $0.kind == .unmerged }) else {
            throw GitServiceError.unsupportedIgnoreSelection(selectedPath.displayString)
        }
        let targetChanges = status.changes.filter { change in
            if isDirectory {
                return change.gitPath == targetPath
                    || change.gitPath.isDescendant(of: targetPath)
                    || change.originalGitPath.map { $0 == targetPath || $0.isDescendant(of: targetPath) } == true
            }
            return change.gitPath == targetPath || change.originalGitPath == targetPath
        }
        let conflicted = targetChanges.filter { $0.kind == .unmerged }.map(\.displayPath).sorted()
        guard conflicted.isEmpty else { throw GitServiceError.conflictedPaths(conflicted) }
        let pattern = try GitIgnoreWriter.pattern(
            selectedPath: selectedPath,
            targetPath: targetPath,
            isDirectory: isDirectory
        )
        let receipt = try GitIgnoreWriter.append(pattern: pattern, repository: repository)
        do {
            _ = try await runner.run(
                repository: repository,
                arguments: ["rm", "--cached", "-r", "-f", "--ignore-unmatch", "--", ":(literal)\(targetPath.decodedString)"],
                environment: mutationEnvironment,
                timeout: ProcessRunner.mutationTimeout,
                priority: .selectedRepository
            )
        } catch {
            do {
                try GitIgnoreWriter.rollback(receipt, repository: repository)
            } catch let rollbackError {
                throw GitServiceError.ignoreRollbackFailed(
                    gitError: String(describing: error),
                    rollbackError: String(describing: rollbackError)
                )
            }
            throw error
        }
        try GitIgnoreWriter.commit(receipt, repository: repository)
    }

    func commit(repository: URL, message: String) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitServiceError.blankCommitMessage
        }
        let status = try await status(repository: repository, priority: .selectedRepository)
        guard !status.isRebaseInProgress else { throw GitServiceError.rebaseAlreadyInProgress }
        guard status.changes.contains(where: \.hasStagedChange) else {
            throw GitServiceError.nothingStaged
        }
        _ = try await runner.run(
            repository: repository,
            arguments: ["commit", "-F", "-"],
            input: Data(message.utf8),
            environment: mutationEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
        let head = try await runner.run(
            repository: repository,
            arguments: ["rev-parse", "--verify", "HEAD"],
            environment: readEnvironment,
            priority: .selectedRepository
        )
        return String(decoding: head.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func amend(repository: URL, message: String, expectedHeadObjectID: String) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitServiceError.blankCommitMessage
        }
        let status = try await status(repository: repository, priority: .selectedRepository)
        guard !status.isRebaseInProgress else { throw GitServiceError.rebaseAlreadyInProgress }
        let currentHeadObjectID = try await headObjectID(repository: repository)
        guard currentHeadObjectID == expectedHeadObjectID else {
            throw GitServiceError.staleAmendTarget(
                expected: expectedHeadObjectID,
                actual: currentHeadObjectID
            )
        }
        let gitDirectoryResult = try await runner.run(
            repository: repository,
            arguments: ["rev-parse", "--path-format=absolute", "--git-dir"],
            environment: readEnvironment,
            priority: .selectedRepository
        )
        let hooksPathResult = try await runner.run(
            repository: repository,
            arguments: ["rev-parse", "--path-format=absolute", "--git-path", "hooks"],
            environment: readEnvironment,
            priority: .selectedRepository
        )
        let symbolicHeadResult = try await runner.run(
            repository: repository,
            arguments: ["symbolic-ref", "--quiet", "HEAD"],
            environment: readEnvironment,
            acceptedExitCodes: [0, 1],
            priority: .selectedRepository
        )
        let gitDirectory = URL(fileURLWithPath: String(decoding: gitDirectoryResult.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        let hooksDirectory = URL(fileURLWithPath: String(decoding: hooksPathResult.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        let symbolicHead = String(decoding: symbolicHeadResult.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedRef = symbolicHead.isEmpty ? "HEAD" : symbolicHead
        let temporaryHooksDirectory = gitDirectory.appendingPathComponent(
            "gdc-amend-hooks-\(UUID().uuidString)",
            isDirectory: true
        )
        let referenceHookURL = temporaryHooksDirectory.appendingPathComponent("reference-transaction")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: temporaryHooksDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryHooksDirectory) }

        let existingHooks: [URL]
        var hooksPathIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: hooksDirectory.path, isDirectory: &hooksPathIsDirectory),
           hooksPathIsDirectory.boolValue {
            existingHooks = try fileManager.contentsOfDirectory(
                at: hooksDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } else {
            existingHooks = []
        }
        guard existingHooks.count <= 1_024 else {
            throw GitServiceError.amendMetadataLimit(existingHooks.count)
        }
        for hook in existingHooks where hook.lastPathComponent != "reference-transaction" {
            let temporaryHook = temporaryHooksDirectory.appendingPathComponent(hook.lastPathComponent)
            if fileManager.isExecutableFile(atPath: hook.path) {
                let wrapper = [
                    "#!/bin/sh",
                    "unset GIT_CONFIG_PARAMETERS",
                    "exec \(Self.shellSingleQuoted(hook.path)) \"$@\"",
                    "",
                ].joined(separator: "\n")
                try Data(wrapper.utf8).write(to: temporaryHook, options: .withoutOverwriting)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryHook.path)
            } else {
                try fileManager.createSymbolicLink(at: temporaryHook, withDestinationURL: hook)
            }
        }
        let existingReferenceHook = hooksDirectory.appendingPathComponent("reference-transaction")
        let referenceHookScript = [
            "#!/bin/sh",
            "state=$1",
            "valid=0",
            "changes_commit_ref=0",
            "records=",
            "while read -r old new ref; do",
            "  records=\"$records$old $new $ref\\n\"",
            "  if [ \"$ref\" != AUTO_MERGE ]; then changes_commit_ref=1; fi",
            "  if [ \"$old\" = \"$GDC_EXPECTED_HEAD\" ] && [ \"$ref\" = \"$GDC_EXPECTED_REF\" ]; then valid=1; fi",
            "done",
            "if [ \"$state\" = prepared ]; then",
            "  if [ \"$valid\" -ne 1 ] && [ \"$changes_commit_ref\" -eq 1 ]; then",
            "    echo 'Amend target changed before the reference transaction.' >&2",
            "    exit 1",
            "  fi",
            "fi",
            "if [ -n \"$GDC_REFERENCE_HOOK\" ]; then",
            "  unset GIT_CONFIG_PARAMETERS",
            "  printf '%b' \"$records\" | \"$GDC_REFERENCE_HOOK\" \"$state\"",
            "  exit $?",
            "fi",
            "exit 0",
            "",
        ].joined(separator: "\n")
        try Data(referenceHookScript.utf8).write(to: referenceHookURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: referenceHookURL.path)

        var amendEnvironment = mutationEnvironment
        amendEnvironment["GDC_EXPECTED_HEAD"] = expectedHeadObjectID
        amendEnvironment["GDC_EXPECTED_REF"] = expectedRef
        if fileManager.isExecutableFile(atPath: existingReferenceHook.path) {
            amendEnvironment["GDC_REFERENCE_HOOK"] = existingReferenceHook.path
        }
        _ = try await runner.run(
            repository: repository,
            arguments: [
                "-c", "core.hooksPath=\(temporaryHooksDirectory.path)",
                "commit", "--amend", "-F", "-"
            ],
            input: Data(message.utf8),
            environment: amendEnvironment,
            timeout: ProcessRunner.mutationTimeout,
            priority: .selectedRepository
        )
        let head = try await runner.run(
            repository: repository,
            arguments: ["rev-parse", "--verify", "HEAD"],
            environment: readEnvironment,
            priority: .selectedRepository
        )
        return String(decoding: head.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func mutationPaths(
        repository: URL,
        requestedPaths: [String],
        requireStaged: Bool,
        rejectConflicts: Bool
    ) async throws -> [String] {
        try await mutationPaths(
            repository: repository,
            requestedPaths: requestedPaths.map(GitPath.init),
            requireStaged: requireStaged,
            rejectConflicts: rejectConflicts
        )
    }

    func mutationPaths(
        repository: URL,
        requestedPaths: [GitPath],
        requireStaged: Bool,
        rejectConflicts: Bool
    ) async throws -> [String] {
        let status = try await status(repository: repository, priority: .selectedRepository)
        return try validatedMutationPaths(
            requestedPaths: requestedPaths,
            status: status,
            requireStaged: requireStaged,
            rejectConflicts: rejectConflicts
        )
    }

    func validatedMutationPaths(
        requestedPaths: [String],
        status: RepoStatus,
        requireStaged: Bool,
        rejectConflicts: Bool
    ) throws -> [String] {
        try validatedMutationPaths(
            requestedPaths: requestedPaths.map(GitPath.init),
            status: status,
            requireStaged: requireStaged,
            rejectConflicts: rejectConflicts
        )
    }

    func validatedMutationPaths(
        requestedPaths: [GitPath],
        status: RepoStatus,
        requireStaged: Bool,
        rejectConflicts: Bool
    ) throws -> [String] {
        guard !status.isRebaseInProgress else { throw GitServiceError.rebaseAlreadyInProgress }
        let requested = Set(requestedPaths)
        guard !requested.isEmpty else { throw GitServiceError.emptyMutationSelection }
        let matching = status.changes.filter {
            requested.contains($0.gitPath) && (!requireStaged || $0.hasStagedChange)
        }
        let unsafe = matching.filter { !$0.isGitAddressable }.map(\.displayPath).sorted()
        guard unsafe.isEmpty else { throw GitServiceError.staleMutationSelection(unsafe) }
        let found = Set(matching.map(\.gitPath))
        let stale = requested.subtracting(found).map(\.displayString).sorted()
        guard stale.isEmpty else { throw GitServiceError.staleMutationSelection(stale) }
        if rejectConflicts {
            let conflicted = matching.filter { $0.kind == .unmerged }.map(\.displayPath).sorted()
            guard conflicted.isEmpty else { throw GitServiceError.conflictedPaths(conflicted) }
        }
        let pathValues = Set(matching.flatMap { [$0.gitPath, $0.originalGitPath].compactMap { $0 } })
        guard pathValues.allSatisfy(\.isAddressable) else {
            throw GitServiceError.staleMutationSelection(pathValues.map(\.displayString).sorted())
        }
        return pathValues.sorted { $0.displayString.localizedStandardCompare($1.displayString) == .orderedAscending }
            .map(\.decodedString)
    }

}
