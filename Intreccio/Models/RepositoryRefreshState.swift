import Foundation

nonisolated struct RepositoryStatusContent: Sendable, Equatable {
    let changeCount: Int
    let stagedCount: Int
    let stagedPathCount: Int
    let unstagedCount: Int
    let conflictCount: Int

    init(status: RepoStatus) {
        var changedPaths = Set<GitPath>()
        var stagedCount = 0
        var stagedPaths = Set<GitPath>()
        var unstagedCount = 0
        var conflictCount = 0
        for change in status.changes {
            if change.kind != .ignored { changedPaths.insert(change.gitPath) }
            if change.hasStagedChange {
                stagedCount += 1
                stagedPaths.insert(change.gitPath)
            }
            if change.hasUnstagedChange { unstagedCount += 1 }
            if change.kind == .unmerged { conflictCount += 1 }
        }
        changeCount = changedPaths.count
        self.stagedCount = stagedCount
        stagedPathCount = stagedPaths.count
        self.unstagedCount = unstagedCount
        self.conflictCount = conflictCount
    }
}

nonisolated struct RepositorySubmoduleActivity: Sendable, Equatable {
    let workingTreeChangeCount: Int
    let aheadCommitCount: Int
    let behindCommitCount: Int
    let parentCommitDiffers: Bool

    init(
        childState: RepositoryRefreshState?,
        parentState: RepositoryRefreshState?,
        submodulePath: String?
    ) {
        let childStatus = childState?.status
        workingTreeChangeCount = childState?.changeCount ?? 0
        let hasUpstream = childStatus?.branch.upstream != nil
        aheadCommitCount = hasUpstream ? childStatus?.branch.ahead ?? 0 : 0
        behindCommitCount = hasUpstream ? childStatus?.branch.behind ?? 0 : 0
        if let parentStatus = parentState?.status, let submodulePath {
            parentCommitDiffers = parentStatus.changes.contains { change in
                guard change.path == submodulePath else { return false }
                return change.indexState != .unmodified
                    || change.submoduleState?.dropFirst().first == "C"
            }
        } else {
            parentCommitDiffers = false
        }
    }

    var hasActivity: Bool {
        workingTreeChangeCount > 0 || aheadCommitCount > 0 || parentCommitDiffers
    }

    var sidebarBadge: String? {
        var indicators = [String]()
        if workingTreeChangeCount > 0 { indicators.append("Changes \(workingTreeChangeCount)") }
        if aheadCommitCount > 0 { indicators.append("Ahead \(aheadCommitCount)") }
        if behindCommitCount > 0 { indicators.append("Behind \(behindCommitCount)") }
        if parentCommitDiffers { indicators.append("Parent commit differs") }
        return indicators.isEmpty ? nil : indicators.joined(separator: " · ")
    }
}

nonisolated enum RepositoryRefreshPhase: Sendable, Equatable {
    case idle
    case queued
    case running
    case failed(OperationFailure)
}

nonisolated struct RepositoryRefreshState: Sendable, Equatable {
    var phase: RepositoryRefreshPhase = .idle
    var status: RepoStatus? {
        didSet { statusContent = nil }
    }
    var statusGeneration: UInt64 = 0
    var statusContentGeneration: UInt64 = 0
    var historyGeneration: UInt64 = 0
    private(set) var statusContent: RepositoryStatusContent?

    init(
        phase: RepositoryRefreshPhase = .idle,
        status: RepoStatus? = nil,
        statusGeneration: UInt64 = 0,
        statusContentGeneration: UInt64 = 0,
        historyGeneration: UInt64 = 0
    ) {
        self.phase = phase
        self.status = status
        self.statusGeneration = statusGeneration
        self.statusContentGeneration = statusContentGeneration
        self.historyGeneration = historyGeneration
        statusContent = status.map { RepositoryStatusContent(status: $0) }
    }

    mutating func updateStatus(_ status: RepoStatus?, content: RepositoryStatusContent?) {
        self.status = status
        statusContent = status == nil ? nil : content
    }

    var changeCount: Int? {
        guard let status else { return nil }
        return statusContent?.changeCount ?? RepositoryStatusContent(status: status).changeCount
    }

    var sidebarBadge: String? {
        guard let status, let changeCount else { return nil }
        var indicators = ["L\(changeCount)"]
        if status.branch.ahead > 0, status.pushAccess.allowsPush {
            indicators.append("P\(status.branch.ahead)")
        }
        if status.branch.behind > 0 { indicators.append("U\(status.branch.behind)") }
        return indicators.joined(separator: " || ")
    }

    static func == (lhs: RepositoryRefreshState, rhs: RepositoryRefreshState) -> Bool {
        lhs.phase == rhs.phase
            && lhs.status == rhs.status
            && lhs.statusGeneration == rhs.statusGeneration
            && lhs.statusContentGeneration == rhs.statusContentGeneration
            && lhs.historyGeneration == rhs.historyGeneration
    }
}

nonisolated enum RepositoryMutationState: Sendable, Equatable {
    case idle
    case running
    case failed(OperationFailure)
}
