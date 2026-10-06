import Foundation

nonisolated enum ChangesMutationPolicy {
    static func stageableChanges(_ changes: [FileChange]) -> [FileChange]? {
        guard !changes.isEmpty,
              !changes.contains(where: { $0.kind == .unmerged || !$0.isGitAddressable }),
              changes.contains(where: \.hasUnstagedChange) else { return nil }
        return changes
    }

    static func changes(_ changes: [FileChange], inFolder folder: String) -> [FileChange] {
        changes.filter { change in
            GitIgnoreWriter.contains(change.path, inFolder: folder)
                || change.originalPath.map { GitIgnoreWriter.contains($0, inFolder: folder) } == true
        }
    }

    static func normalMutationAvailable(
        status: RepoStatus?,
        mutationRunning: Bool
    ) -> Bool {
        guard let status else { return false }
        return !mutationRunning && !status.isRebaseInProgress
    }

    static func canStage(
        changes: [FileChange],
        status: RepoStatus?,
        mutationRunning: Bool
    ) -> Bool {
        normalMutationAvailable(status: status, mutationRunning: mutationRunning)
            && stageableChanges(changes) != nil
    }

    static func canStageAll(
        status: RepoStatus?,
        content: RepositoryStatusContent?,
        mutationRunning: Bool
    ) -> Bool {
        guard let status,
              normalMutationAvailable(status: status, mutationRunning: mutationRunning),
              status.changes.filter(\.hasUnstagedChange).allSatisfy(\.isGitAddressable) else { return false }
        let resolvedContent = content ?? RepositoryStatusContent(status: status)
        return resolvedContent.conflictCount == 0 && resolvedContent.unstagedCount > 0
    }

    static func canUnstage(
        changes: [FileChange],
        status: RepoStatus?,
        mutationRunning: Bool
    ) -> Bool {
        normalMutationAvailable(status: status, mutationRunning: mutationRunning)
            && changes.allSatisfy(\.isGitAddressable)
            && changes.contains(where: \.hasStagedChange)
    }

    static func canUnstageAll(
        status: RepoStatus?,
        content: RepositoryStatusContent?,
        mutationRunning: Bool
    ) -> Bool {
        guard let status,
              normalMutationAvailable(status: status, mutationRunning: mutationRunning),
              status.changes.filter(\.hasStagedChange).allSatisfy(\.isGitAddressable) else { return false }
        let resolvedContent = content ?? RepositoryStatusContent(status: status)
        return resolvedContent.stagedCount > 0
    }

    static func canDiscard(
        changes: [FileChange],
        status: RepoStatus?,
        mutationRunning: Bool
    ) -> Bool {
        guard normalMutationAvailable(status: status, mutationRunning: mutationRunning),
              !changes.isEmpty,
              changes.allSatisfy(\.isGitAddressable) else { return false }
        return !Dictionary(grouping: changes, by: \.gitPath).contains(where: { path, pathChanges in
            path.hasTrailingSlash && pathChanges.allSatisfy { $0.kind == .untracked }
        })
    }

    static func canIgnoreSelection(_ changes: [FileChange]) -> Bool {
        !changes.isEmpty
            && changes.allSatisfy(\.isIgnoreAddressable)
            && changes.contains(where: \.hasUnstagedChange)
            && !changes.contains(where: { $0.kind == .unmerged })
    }

    static func canIgnore(
        selectedChanges: [FileChange],
        selectedPath: String,
        targetPath: String,
        isDirectory: Bool,
        status: RepoStatus?,
        mutationRunning: Bool,
        targetChanges: [FileChange]? = nil
    ) -> Bool {
        guard normalMutationAvailable(status: status, mutationRunning: mutationRunning),
              canIgnoreSelection(selectedChanges),
              (try? GitIgnoreWriter.pattern(
                  selectedPath: selectedPath,
                  targetPath: targetPath,
                  isDirectory: isDirectory
              )) != nil else { return false }
        return targetChanges?.contains(where: { $0.kind == .unmerged }) != true
    }

    static func stashControlAvailability(
        status: RepoStatus?,
        mutationRunning: Bool,
        conflictCount: Int? = nil
    ) -> (canStash: Bool, canRestore: Bool) {
        guard let status,
              normalMutationAvailable(status: status, mutationRunning: mutationRunning) else { return (false, false) }
        let hasConflicts = conflictCount.map { $0 > 0 } ?? status.hasConflicts
        let canStash = status.branch.objectID != nil && !status.changes.isEmpty && !hasConflicts
        let canRestore = status.branch.objectID != nil && status.hasStash && status.changes.isEmpty
        return (canStash, canRestore)
    }

    static func rebaseControlAvailability(
        status: RepoStatus?,
        mutationRunning: Bool,
        conflictCount: Int? = nil
    ) -> (canStart: Bool, canContinue: Bool, canAbort: Bool) {
        guard let status else { return (false, false, false) }
        let hasConflicts = conflictCount.map { $0 > 0 } ?? status.hasConflicts
        if status.isRebaseInProgress {
            return (false, !mutationRunning && !hasConflicts, !mutationRunning)
        }
        let canStart = !mutationRunning
            && status.branch.head != nil
            && status.branch.upstream != nil
            && status.branch.behind > 0
            && status.changes.isEmpty
        return (canStart, false, false)
    }
}