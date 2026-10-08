import Foundation

@MainActor
struct RepositoryGitHubResolutionSnapshot {
    let githubURLs: RepositorySnapshotMap<URL>
    let generations: RepositorySnapshotMap<UInt64>
    let completedRepositoryIDs: RepositorySnapshotSet
    let hasLookupTask: Bool

    init(
        githubURLs: RepositorySnapshotMap<URL>,
        generations: RepositorySnapshotMap<UInt64>,
        completedRepositoryIDs: RepositorySnapshotSet,
        hasLookupTask: Bool
    ) {
        self.githubURLs = githubURLs
        self.generations = generations
        self.completedRepositoryIDs = completedRepositoryIDs
        self.hasLookupTask = hasLookupTask
    }

    init(
        githubURLs: [UUID: URL],
        generations: [UUID: UInt64],
        completedRepositoryIDs: Set<UUID>,
        hasLookupTask: Bool
    ) {
        self.init(
            githubURLs: RepositorySnapshotMap(githubURLs),
            generations: RepositorySnapshotMap(generations),
            completedRepositoryIDs: RepositorySnapshotSet(completedRepositoryIDs),
            hasLookupTask: hasLookupTask
        )
    }
}

nonisolated struct RepositoryGitHubResolutionResult: Sendable {
    let url: URL?
    let didUpdate: Bool
}

nonisolated enum RepositoryGitHubResolutionEventKey: Hashable, Sendable {
    case urlResolved
}

nonisolated enum RepositoryGitHubResolutionEvent: Sendable, Equatable {
    case urlResolved

    var coalescingKey: RepositoryGitHubResolutionEventKey { .urlResolved }
}

@MainActor
final class RepositoryGitHubResolutionController {
    let gitService: GitService

    private let githubURLLookup: @Sendable (URL) async throws -> URL?

    private static let maximumConcurrentLookups = 2
    private var githubURLs = RepositorySnapshotMap<URL>()
    private var githubLookupTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingGitHubRepositoryIDs: [UUID] = []
    private var pendingGitHubRepositoryIDSet = Set<UUID>()
    private var pendingGitHubRepositoryOffset = 0
    private var githubLookupTokens: [UUID: UUID] = [:]
    private var githubGenerations = RepositorySnapshotMap<UInt64>()
    private var githubIdentities: [UUID: GitHubIdentity] = [:]
    private var githubCompleted = RepositorySnapshotSet()
    private var context: RepositoryRuntimeContext?
    private(set) var isShuttingDown = false

    private struct GitHubIdentity: Equatable, Sendable {
        let canonicalURL: URL
        let resourceID: String?
    }

    private let eventStream: BoundedKeyedAsyncStream<
        RepositoryGitHubResolutionEvent,
        RepositoryGitHubResolutionEventKey
    >
    var events: AsyncStream<RepositoryGitHubResolutionEvent> { eventStream.asyncStream }

    init(
        gitService: GitService,
        githubURLLookup: (@Sendable (URL) async throws -> URL?)? = nil
    ) {
        self.gitService = gitService
        self.githubURLLookup = githubURLLookup ?? { [gitService] repository in
            try await gitService.githubURL(repository: repository)
        }
        self.eventStream = BoundedKeyedAsyncStream(
            maximumPendingElements: 1,
            key: { $0.coalescingKey }
        )
    }

    deinit {
        githubLookupTasks.values.forEach { $0.cancel() }
        eventStream.finish()
    }

    var snapshot: RepositoryGitHubResolutionSnapshot {
        RepositoryGitHubResolutionSnapshot(
            githubURLs: githubURLs,
            generations: githubGenerations,
            completedRepositoryIDs: githubCompleted,
            hasLookupTask: !githubLookupTasks.isEmpty || !pendingGitHubRepositoryIDSet.isEmpty
        )
    }
#if DEBUG
    var pendingEventCountForTesting: Int { eventStream.pendingCount }
#endif

    func update(context: RepositoryRuntimeContext) {
        self.context = context
    }

    func scheduleGitHubURLLookups(for repositories: [RepoDescriptor], forceRefresh: Bool) {
        let targetRepositoryIDs = Set(repositories.map(\.id))
        guard !isShuttingDown else { return }
        guard context != nil else {
            scheduleGitHubURLLookups(
                availableRepositories: repositories.filter { $0.availability == .available },
                targetRepositoryIDs: targetRepositoryIDs,
                forceRefresh: forceRefresh,
                reconcileAll: false
            )
            return
        }
        scheduleGitHubURLLookups(
            targetRepositoryIDs: targetRepositoryIDs,
            forceRefresh: forceRefresh
        )
    }

    func scheduleGitHubURLLookups(
        for repositories: [RepoDescriptor],
        targetRepositoryIDs: Set<UUID>,
        forceRefresh: Bool
    ) {
        guard !isShuttingDown else { return }
        guard context != nil else {
            scheduleGitHubURLLookups(
                availableRepositories: repositories.filter {
                    targetRepositoryIDs.contains($0.id) && $0.availability == .available
                },
                targetRepositoryIDs: targetRepositoryIDs,
                forceRefresh: forceRefresh,
                reconcileAll: false
            )
            return
        }
        scheduleGitHubURLLookups(
            targetRepositoryIDs: targetRepositoryIDs,
            forceRefresh: forceRefresh
        )
    }

    func scheduleGitHubURLLookups(
        targetRepositoryIDs: Set<UUID>,
        forceRefresh: Bool,
        reconcileAll: Bool = false
    ) {
        guard !isShuttingDown,
              let context,
              !context.isShuttingDown else { return }
        let availableRepositories = reconcileAll
            ? context.repositories.filter { $0.availability == .available }
            : context.repositoryIndex.availableRepositories(for: targetRepositoryIDs)
        scheduleGitHubURLLookups(
            availableRepositories: availableRepositories,
            targetRepositoryIDs: targetRepositoryIDs,
            forceRefresh: forceRefresh,
            reconcileAll: reconcileAll
        )
    }

    private func scheduleGitHubURLLookups(
        availableRepositories: [RepoDescriptor],
        targetRepositoryIDs: Set<UUID>,
        forceRefresh: Bool,
        reconcileAll: Bool
    ) {
        let availableIDs = Set(availableRepositories.map(\.id))
        let repositoryIDsToClear = reconcileAll
            ? Set(githubIdentities.keys).subtracting(availableIDs)
            : targetRepositoryIDs.subtracting(availableIDs)
        for repositoryID in repositoryIDsToClear {
            clearGitHubState(for: repositoryID)
        }

        var repositoryIDsToSchedule = targetRepositoryIDs
        var invalidatedRepositoryIDs = Set<UUID>()

        for repository in availableRepositories {
            let identity = GitHubIdentity(
                canonicalURL: repository.canonicalURL,
                resourceID: repository.resourceID
            )
            if githubIdentities[repository.id] != identity {
                githubIdentities[repository.id] = identity
                githubCompleted = githubCompleted.removing(repository.id)
                githubURLs = githubURLs.setting(nil, for: repository.id)
                _ = nextGitHubGeneration(for: repository.id)
                cancelLookup(for: repository.id)
                repositoryIDsToSchedule.insert(repository.id)
                invalidatedRepositoryIDs.insert(repository.id)
            }
        }

        if forceRefresh {
            for repository in availableRepositories where targetRepositoryIDs.contains(repository.id) {
                if !invalidatedRepositoryIDs.contains(repository.id) {
                    _ = nextGitHubGeneration(for: repository.id)
                    githubCompleted = githubCompleted.removing(repository.id)
                    githubURLs = githubURLs.setting(nil, for: repository.id)
                    cancelLookup(for: repository.id)
                    invalidatedRepositoryIDs.insert(repository.id)
                }
                repositoryIDsToSchedule.insert(repository.id)
            }
        }

        for repository in availableRepositories
            where repositoryIDsToSchedule.contains(repository.id)
                && !githubCompleted.contains(repository.id)
                && (githubLookupTasks[repository.id] == nil
                    || invalidatedRepositoryIDs.contains(repository.id)) {
            enqueue(repositoryID: repository.id)
        }
        startPendingGitHubURLLookups()
    }

    private func enqueue(repositoryID: UUID) {
        guard pendingGitHubRepositoryIDSet.insert(repositoryID).inserted else { return }
        pendingGitHubRepositoryIDs.append(repositoryID)
    }

    private func removePending(repositoryID: UUID) {
        guard pendingGitHubRepositoryIDSet.remove(repositoryID) != nil else { return }
        guard pendingGitHubRepositoryIDs.count - pendingGitHubRepositoryOffset
            > pendingGitHubRepositoryIDSet.count + 128 else { return }
        compactPendingQueue()
    }

    private func compactPendingQueue() {
        var seen = Set<UUID>()
        let remaining = pendingGitHubRepositoryIDs.dropFirst(pendingGitHubRepositoryOffset)
        pendingGitHubRepositoryIDs = remaining.filter {
            pendingGitHubRepositoryIDSet.contains($0) && seen.insert($0).inserted
        }
        pendingGitHubRepositoryOffset = 0
    }

    private func nextPendingRepositoryID() -> UUID? {
        while pendingGitHubRepositoryOffset < pendingGitHubRepositoryIDs.count {
            let repositoryID = pendingGitHubRepositoryIDs[pendingGitHubRepositoryOffset]
            pendingGitHubRepositoryOffset += 1
            guard pendingGitHubRepositoryIDSet.remove(repositoryID) != nil else { continue }
            if pendingGitHubRepositoryOffset >= 128,
               pendingGitHubRepositoryOffset * 2 >= pendingGitHubRepositoryIDs.count {
                pendingGitHubRepositoryIDs.removeFirst(pendingGitHubRepositoryOffset)
                pendingGitHubRepositoryOffset = 0
            }
            return repositoryID
        }
        pendingGitHubRepositoryIDs.removeAll(keepingCapacity: true)
        pendingGitHubRepositoryOffset = 0
        return nil
    }

    private func startPendingGitHubURLLookups() {
        guard !isShuttingDown else { return }
        var deferredRepositoryIDs: [UUID] = []
        while githubLookupTasks.count < Self.maximumConcurrentLookups,
              let repositoryID = nextPendingRepositoryID() {
            guard let context,
                  !context.isShuttingDown,
                  let repository = context.repositoryIndex.repository(for: repositoryID),
                  repository.availability == .available,
                  !githubCompleted.contains(repositoryID) else { continue }
            guard githubLookupTasks[repositoryID] == nil else {
                deferredRepositoryIDs.append(repositoryID)
                continue
            }
            let generation = githubGenerations[repositoryID] ?? 0
            let identity = GitHubIdentity(
                canonicalURL: repository.canonicalURL,
                resourceID: repository.resourceID
            )
            let canonicalURL = repository.canonicalURL
            let token = UUID()
            let lookup = githubURLLookup
            githubLookupTokens[repositoryID] = token
            githubLookupTasks[repositoryID] = Task { [weak self, lookup] in
                defer {
                    self?.finishGitHubURLLookup(repositoryID: repositoryID, token: token)
                }
                guard !Task.isCancelled else { return }
                let webURL: URL?
                do {
                    webURL = try await lookup(canonicalURL)
                } catch {
                    guard !Task.isCancelled else { return }
                    webURL = nil
                }
                guard !Task.isCancelled,
                      let self,
                      self.isCurrentLookup(
                          repositoryID: repositoryID,
                          generation: generation,
                          identity: identity
                      ) else { return }
                self.githubURLs = self.githubURLs.setting(webURL, for: repositoryID)
                self.githubCompleted = self.githubCompleted.inserting(repositoryID)
                await self.eventStream.send(.urlResolved)
            }
        }
        deferredRepositoryIDs.forEach { enqueue(repositoryID: $0) }
    }

    private func finishGitHubURLLookup(repositoryID: UUID, token: UUID) {
        guard githubLookupTokens[repositoryID] == token else { return }
        githubLookupTokens[repositoryID] = nil
        githubLookupTasks[repositoryID] = nil
        startPendingGitHubURLLookups()
    }

    private func isCurrentLookup(
        repositoryID: UUID,
        generation: UInt64,
        identity: GitHubIdentity
    ) -> Bool {
        guard !isShuttingDown,
              let context,
              !context.isShuttingDown,
              githubGenerations[repositoryID] == generation,
              githubIdentities[repositoryID] == identity,
              let current = context.repositoryIndex.repository(for: repositoryID),
              current.availability == .available,
              current.canonicalURL == identity.canonicalURL,
              current.resourceID == identity.resourceID else { return false }
        return true
    }

    private func cancelLookup(for repositoryID: UUID) {
        removePending(repositoryID: repositoryID)
        githubLookupTasks[repositoryID]?.cancel()
    }

    private func clearGitHubState(for repositoryID: UUID) {
        githubIdentities[repositoryID] = nil
        githubGenerations = githubGenerations.setting(nil, for: repositoryID)
        githubCompleted = githubCompleted.removing(repositoryID)
        githubURLs = githubURLs.setting(nil, for: repositoryID)
        cancelLookup(for: repositoryID)
    }

    private func nextGitHubGeneration(for repositoryID: UUID) -> UInt64 {
        let generation = (githubGenerations[repositoryID] ?? 0) &+ 1
        githubGenerations = githubGenerations.setting(generation, for: repositoryID)
        return generation
    }

    private func invalidateLookupState(for repositoryID: UUID) {
        _ = nextGitHubGeneration(for: repositoryID)
        githubCompleted = githubCompleted.removing(repositoryID)
        githubURLs = githubURLs.setting(nil, for: repositoryID)
        cancelLookup(for: repositoryID)
    }

    func invalidateGitHubURLLookup(for repositoryID: UUID) {
        guard !isShuttingDown else { return }
        invalidateLookupState(for: repositoryID)
        guard let context,
              !context.isShuttingDown,
              let repository = context.repositoryIndex.repository(for: repositoryID),
              repository.availability == .available else { return }
        githubIdentities[repositoryID] = GitHubIdentity(
            canonicalURL: repository.canonicalURL,
            resourceID: repository.resourceID
        )
        enqueue(repositoryID: repositoryID)
        startPendingGitHubURLLookups()
    }

    func refreshGitHubURL(for repositoryID: UUID) async throws -> RepositoryGitHubResolutionResult {
        guard !isShuttingDown,
              let context,
              !context.isShuttingDown,
              let repository = context.repositoryIndex.repository(for: repositoryID),
              repository.availability == .available else {
            return RepositoryGitHubResolutionResult(url: nil, didUpdate: false)
        }
        let identity = GitHubIdentity(
            canonicalURL: repository.canonicalURL,
            resourceID: repository.resourceID
        )
        invalidateLookupState(for: repositoryID)
        githubIdentities[repositoryID] = identity
        let generation = githubGenerations[repositoryID] ?? 0
        let webURL: URL?
        do {
            webURL = try await githubURLLookup(repository.canonicalURL)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            return RepositoryGitHubResolutionResult(url: nil, didUpdate: false)
        }
        guard !Task.isCancelled,
              isCurrentLookup(
                  repositoryID: repositoryID,
                  generation: generation,
                  identity: identity
              ) else {
            throw GitHubURLRefreshError.superseded
        }
        githubURLs = githubURLs.setting(webURL, for: repositoryID)
        githubCompleted = githubCompleted.inserting(repositoryID)
        return RepositoryGitHubResolutionResult(url: webURL, didUpdate: true)
    }

    func refreshGitHubURLWithRetry(for repositoryID: UUID) async -> RepositoryGitHubResolutionResult? {
        for attempt in 0..<2 {
            do {
                return try await refreshGitHubURL(for: repositoryID)
            } catch is CancellationError {
                return nil
            } catch is GitHubURLRefreshError {
                guard attempt == 0 else { return nil }
            } catch {
                return nil
            }
        }
        return nil
    }

    func cancelAndDrain() async {
        isShuttingDown = true
        for repositoryID in githubGenerations.keys {
            _ = nextGitHubGeneration(for: repositoryID)
        }
        let tasks = Array(githubLookupTasks.values)
        tasks.forEach { $0.cancel() }
        githubLookupTasks.removeAll()
        githubLookupTokens.removeAll()
        pendingGitHubRepositoryIDs.removeAll()
        pendingGitHubRepositoryIDSet.removeAll()
        pendingGitHubRepositoryOffset = 0
        await TaskCompletionDrain.waitForCompletion(tasks)
    }

    func finishShutdown() {
        isShuttingDown = true
        eventStream.finish()
    }

    func resumeAfterFailedShutdown() {
        isShuttingDown = false
    }
}
