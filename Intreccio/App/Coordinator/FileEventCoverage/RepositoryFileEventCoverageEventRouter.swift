import Foundation

@MainActor
final class RepositoryFileEventCoverageEventRouter {
    private static let maximumConcurrentRepositoryRoutes = 2

    private struct RepositoryRouteRequest: Sendable {
        let target: RepositoryFileEventTarget
        let relevantPaths: [RepositoryFileEventPath]
    }

    private struct IndexedRepositoryEvents: Sendable {
        let index: Int
        let events: [RepositoryFileEventCoverageEvent]
    }

    typealias IgnoredPathResolver = @Sendable (URL, [String]) async -> Set<String>

    private let ignoredPathResolver: IgnoredPathResolver

    private let topology: RepositoryFileEventCoverageWatcherTopology
    private let caseSensitivityProvider: (URL) -> Bool
    private var context: RepositoryRuntimeContext?
    private var caseSensitiveByRepositoryPath: [URL: Bool] = [:]

    init(
        topology: RepositoryFileEventCoverageWatcherTopology,
        caseSensitivityProvider: @escaping (URL) -> Bool,
        ignoredPathResolver: @escaping IgnoredPathResolver = { _, _ in [] }
    ) {
        self.topology = topology
        self.caseSensitivityProvider = caseSensitivityProvider
        self.ignoredPathResolver = ignoredPathResolver
    }

    func update(context: RepositoryRuntimeContext) {
        self.context = context
    }

    func updateCoverage(context: RepositoryRuntimeContext) {
        self.context = context
        let availableRepositoryPaths = Set(context.repositories
            .filter { $0.availability == .available }
            .map { RepositoryPathPolicy.canonicalURL($0.canonicalURL) })
        caseSensitiveByRepositoryPath = caseSensitiveByRepositoryPath.filter {
            availableRepositoryPaths.contains($0.key)
        }
        for repository in context.repositories where repository.availability == .available {
            _ = caseSensitiveVolume(for: repository.canonicalURL)
        }
    }

    func routeRepositoryFileEvents(
        _ batch: FileEventBatch,
        repositoryID: UUID
    ) async -> [RepositoryFileEventCoverageEvent] {
        guard !Task.isCancelled,
              let context,
              !context.isShuttingDown,
              let repository = context.repositoryIndex.repository(for: repositoryID),
              repository.availability == .available else { return [] }

        let target = RepositoryFileEventTarget(repository)
        let caseSensitive = caseSensitiveVolume(for: repository.canonicalURL)
        let normalizedBatch = SourceRepositoryNormalizedFileEventBatch(
            batch,
            needsCaseInsensitivePaths: !caseSensitive
        )
        let classifier = normalizedBatch.classifier(caseSensitiveVolume: caseSensitive)
        let normalizedTargetPathComponents = classifier.normalizedPathComponents(target.pathComponents)
        let relevantPaths = normalizedBatch.paths.compactMap { path -> RepositoryFileEventPath? in
            let normalizedEventPathComponents = classifier.normalizedPathComponents(for: path)
            guard normalizedEventPathComponents.starts(with: normalizedTargetPathComponents) else { return nil }
            return classifier.classify(path)
        }
        return await routeRepositoryFileEvents(
            batch,
            target: target,
            relevantPaths: relevantPaths,
            caseSensitive: caseSensitive
        )
    }

    func routeSourceFileEvents(
        _ batch: FileEventBatch,
        sourceID: UUID
    ) async -> [RepositoryFileEventCoverageEvent] {
        guard !Task.isCancelled,
              let context,
              !context.isShuttingDown,
              let source = context.state.watchRoots.first(where: { $0.id == sourceID }) else { return [] }

        let sourceURL = RepositoryPathPolicy.canonicalURL(
            URL(fileURLWithPath: source.lastResolvedPath, isDirectory: true)
        )
        let sourceIndex: SourceRepositoryPathIndex
        if let indexedSource = topology.sourceRepositoryPathIndexes[sourceID],
           indexedSource.sourceURL == sourceURL {
            sourceIndex = indexedSource
        } else {
            sourceIndex = RepositoryFileEventCoveragePlanner.makeSourceIndex(
                for: source,
                sourceURL: sourceURL,
                repositories: context.repositories,
                caseSensitivityProvider: caseSensitivityProvider
            )
        }
        return await routeSourceFileEvents(
            batch,
            sourceID: sourceID,
            relevantEvents: sourceIndex.partition(batch),
            caseSensitive: sourceIndex.caseSensitiveVolume
        )
    }

    func routeSourceFileEvents(
        _ batch: FileEventBatch,
        sourceID: UUID,
        relevantEvents: [SourceRepositoryFileEvent],
        caseSensitive: Bool
    ) async -> [RepositoryFileEventCoverageEvent] {
        guard !Task.isCancelled,
              !relevantEvents.isEmpty
                  || batch.hasUnrepresentedChanges
                  || (batch.requiresFullRescan && batch.paths.isEmpty) else { return [] }

        let sourceEvents: [RepositoryFileEventCoverageEvent]
        if batch.hasUnrepresentedChanges || batch.requiresFullRescan {
            sourceEvents = [.rescanSource(sourceID, fromWatchRoot: true)]
        } else {
            let needsRescan = relevantEvents.contains { event in
                guard let repository = event.deepestRepository else { return true }
                guard repository.availability == .available else { return true }
                return event.eventPath.isSourceRescan
                    && RepositoryFileEventPathClassifier.isRepositoryStructuralPath(
                        event.eventPath.pathComponents,
                        repositoryPathComponents: repository.pathComponents,
                        caseSensitive: caseSensitive
                    )
            }
            sourceEvents = needsRescan ? [.rescanSource(sourceID, fromWatchRoot: true)] : []
        }

        var repositoryPathsByID: [UUID: [RepositoryFileEventPath]] = [:]
        var repositoryTargetsByID: [UUID: RepositoryFileEventTarget] = [:]
        var repositoryOrder: [UUID] = []
        for event in relevantEvents {
            for repository in event.repositories where repository.availability == .available {
                guard let owner = topology.repositoryCoverageOwners[repository.id],
                      case .watchRoot(let ownerSourceID) = owner,
                      ownerSourceID == sourceID else { continue }
                if repositoryTargetsByID[repository.id] == nil {
                    repositoryOrder.append(repository.id)
                }
                repositoryTargetsByID[repository.id] = repository
                repositoryPathsByID[repository.id, default: []].append(event.eventPath)
            }
        }
        let requests = repositoryOrder.compactMap { repositoryID -> RepositoryRouteRequest? in
            guard let target = repositoryTargetsByID[repositoryID],
                  let relevantPaths = repositoryPathsByID[repositoryID] else { return nil }
            return RepositoryRouteRequest(target: target, relevantPaths: relevantPaths)
        }
        let repositoryEvents = await routeRepositoryFileEvents(
            batch,
            requests: requests,
            caseSensitive: caseSensitive
        )
        guard !Task.isCancelled else { return [] }
        return coalesce(sourceEvents + repositoryEvents)
    }

    private func routeRepositoryFileEvents(
        _ batch: FileEventBatch,
        target: RepositoryFileEventTarget,
        relevantPaths: [RepositoryFileEventPath],
        caseSensitive: Bool
    ) async -> [RepositoryFileEventCoverageEvent] {
        guard !Task.isCancelled, !relevantPaths.isEmpty else { return [] }
        guard let repository = context?.repositoryIndex.repository(for: target.id) else { return [] }
        let filteredPaths = await filterIgnoredPaths(
            batch,
            repository: repository,
            target: target,
            relevantPaths: relevantPaths,
            caseSensitive: caseSensitive
        )
        guard !Task.isCancelled else { return [] }
        guard let currentContext = context,
              !currentContext.isShuttingDown,
              let currentRepository = currentContext.repositoryIndex.repository(for: target.id),
              RepositoryFileEventTarget(currentRepository) == target else { return [] }
        guard !filteredPaths.isEmpty else { return [] }

        var events: [RepositoryFileEventCoverageEvent] = []
        if filteredPaths.contains(where: {
            RepositoryFileEventPathClassifier.isGitHubConfigurationPath(
                $0.pathComponents,
                repositoryPathComponents: target.pathComponents,
                caseSensitive: caseSensitive
            )
        }) {
            events.append(.invalidateGitHubURL(target.id))
        }
        let sourceOwnsCoverage = topology.repositoryCoverageOwners[target.id].map {
            if case .watchRoot = $0 { return true }
            return false
        } ?? false
        let hasStructuralChange = !sourceOwnsCoverage && (
            batch.hasUnrepresentedChanges || filteredPaths.contains {
                ($0.isSourceRescan || batch.requiresFullRescan)
                    && RepositoryFileEventPathClassifier.isRepositoryStructuralPath(
                        $0.pathComponents,
                        repositoryPathComponents: target.pathComponents,
                        caseSensitive: caseSensitive
                    )
            }
        )
        if hasStructuralChange {
            events.append(.rescanSource(target.sourceID, fromWatchRoot: false))
        }
        events.append(.refreshStatus(target.id))
        return events
    }

    private func routeRepositoryFileEvents(
        _ batch: FileEventBatch,
        requests: [RepositoryRouteRequest],
        caseSensitive: Bool
    ) async -> [RepositoryFileEventCoverageEvent] {
        guard !Task.isCancelled, !requests.isEmpty else { return [] }
        return await withTaskGroup(of: IndexedRepositoryEvents.self) { group in
            defer { group.cancelAll() }
            var events = [[RepositoryFileEventCoverageEvent]?](
                repeating: nil,
                count: requests.count
            )
            var nextIndex = 0
            let initialCount = min(Self.maximumConcurrentRepositoryRoutes, requests.count)

            while nextIndex < initialCount {
                let index = nextIndex
                nextIndex += 1
                let request = requests[index]
                group.addTask { [self] in
                    IndexedRepositoryEvents(
                        index: index,
                        events: await self.routeRepositoryFileEvents(
                            batch,
                            target: request.target,
                            relevantPaths: request.relevantPaths,
                            caseSensitive: caseSensitive
                        )
                    )
                }
            }

            while let indexedEvents = await group.next() {
                guard !Task.isCancelled else { return [] }
                events[indexedEvents.index] = indexedEvents.events
                guard nextIndex < requests.count else { continue }
                let index = nextIndex
                nextIndex += 1
                let request = requests[index]
                group.addTask { [self] in
                    IndexedRepositoryEvents(
                        index: index,
                        events: await self.routeRepositoryFileEvents(
                            batch,
                            target: request.target,
                            relevantPaths: request.relevantPaths,
                            caseSensitive: caseSensitive
                        )
                    )
                }
            }

            return events.compactMap(\.self).flatMap(\.self)
        }
    }

    private func filterIgnoredPaths(
        _ batch: FileEventBatch,
        repository: RepoDescriptor,
        target: RepositoryFileEventTarget,
        relevantPaths: [RepositoryFileEventPath],
        caseSensitive: Bool
    ) async -> [RepositoryFileEventPath] {
        guard !Task.isCancelled else { return [] }
        guard !batch.requiresFullRescan,
              !batch.hasUnrepresentedChanges else { return relevantPaths }

        let candidatePaths = relevantPaths.filter {
            !isRepositoryMetadataPath(
                $0.pathComponents,
                repositoryPathComponents: target.pathComponents,
                caseSensitive: caseSensitive
            )
        }
        let relativePathsByEventPath: [String: String] = Dictionary(uniqueKeysWithValues: candidatePaths.compactMap { path in
            guard let relativePath = relativePath(
                path,
                repositoryPathComponents: target.pathComponents,
                caseSensitive: caseSensitive
            ) else { return nil }
            return (path.path, relativePath)
        })
        guard !relativePathsByEventPath.isEmpty else { return relevantPaths }

        let ignoredPaths = await ignoredPathResolver(
            repository.canonicalURL,
            Array(Set(relativePathsByEventPath.values))
        )
        guard !Task.isCancelled else { return [] }
        guard !ignoredPaths.isEmpty else { return relevantPaths }
        return relevantPaths.filter { path in
            guard !isRepositoryMetadataPath(
                path.pathComponents,
                repositoryPathComponents: target.pathComponents,
                caseSensitive: caseSensitive
            ),
            let relativePath = relativePathsByEventPath[path.path] else { return true }
            return !ignoredPaths.contains(relativePath)
        }
    }

    private func isRepositoryMetadataPath(
        _ eventPathComponents: [String],
        repositoryPathComponents: [String],
        caseSensitive: Bool
    ) -> Bool {
        let normalizedEventPath = normalizedPathComponents(
            eventPathComponents,
            caseSensitive: caseSensitive
        )
        let normalizedRepositoryPath = normalizedPathComponents(
            repositoryPathComponents,
            caseSensitive: caseSensitive
        )
        guard normalizedEventPath.starts(with: normalizedRepositoryPath) else { return false }
        guard normalizedEventPath.count > normalizedRepositoryPath.count else { return true }
        return normalizedEventPath[normalizedRepositoryPath.count] == ".git"
            || normalizedEventPath.last == ".gitignore"
    }

    private func relativePath(
        _ eventPath: RepositoryFileEventPath,
        repositoryPathComponents: [String],
        caseSensitive: Bool
    ) -> String? {
        let normalizedEventPath = normalizedPathComponents(
            eventPath.pathComponents,
            caseSensitive: caseSensitive
        )
        let normalizedRepositoryPath = normalizedPathComponents(
            repositoryPathComponents,
            caseSensitive: caseSensitive
        )
        guard normalizedEventPath.starts(with: normalizedRepositoryPath) else { return nil }
        let relativeComponents = eventPath.pathComponents.dropFirst(repositoryPathComponents.count)
        return relativeComponents.isEmpty ? "." : relativeComponents.joined(separator: "/")
    }

    private func normalizedPathComponents(
        _ pathComponents: [String],
        caseSensitive: Bool
    ) -> [String] {
        pathComponents.map { caseSensitive ? $0 : $0.lowercased() }
    }

    private func caseSensitiveVolume(for url: URL) -> Bool {
        let canonicalURL = RepositoryPathPolicy.canonicalURL(url)
        if let cached = caseSensitiveByRepositoryPath[canonicalURL] { return cached }
        let value = caseSensitivityProvider(canonicalURL)
        caseSensitiveByRepositoryPath[canonicalURL] = value
        return value
    }

    private func coalesce(
        _ events: [RepositoryFileEventCoverageEvent]
    ) -> [RepositoryFileEventCoverageEvent] {
        var seen = Set<RepositoryFileEventCoverageEvent>()
        return events.filter { seen.insert($0).inserted }
    }
}
