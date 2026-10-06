import Foundation

nonisolated enum RepositoryFileEventCoverageOwner: Equatable {
    case watchRoot(UUID)
    case independentRepository
}

nonisolated struct RepositoryFileEventSourceGroupKey: Hashable {
    let coveragePaths: [String]
}

nonisolated struct RepositoryFileEventSourceGroupPlan {
    let sources: [WatchRoot]
    let coverageURLs: [URL]
    let key: RepositoryFileEventSourceGroupKey
}

nonisolated enum RepositoryFileEventCoveragePlanner {
    private struct DisjointSet {
        private var parents: [Int]
        private var ranks: [Int]

        init(count: Int) {
            parents = Array(0..<count)
            ranks = Array(repeating: 0, count: count)
        }

        mutating func find(_ value: Int) -> Int {
            let parent = parents[value]
            guard parent != value else { return value }
            let root = find(parent)
            parents[value] = root
            return root
        }

        mutating func union(_ lhs: Int, _ rhs: Int) {
            let lhsRoot = find(lhs)
            let rhsRoot = find(rhs)
            guard lhsRoot != rhsRoot else { return }
            if ranks[lhsRoot] < ranks[rhsRoot] {
                parents[lhsRoot] = rhsRoot
            } else if ranks[lhsRoot] > ranks[rhsRoot] {
                parents[rhsRoot] = lhsRoot
            } else {
                parents[rhsRoot] = lhsRoot
                ranks[lhsRoot] += 1
            }
        }
    }

    private struct SourceRoot {
        let sourceIndex: Int
        let pathComponents: [String]
        let caseSensitive: Bool
    }

    static func makeSourceIndexes(
        _ sources: [WatchRoot],
        repositories: [RepoDescriptor],
        caseSensitivityProvider: @escaping (URL) -> Bool
    ) -> [UUID: SourceRepositoryPathIndex] {
        var repositoryTargetsBySourceID: [UUID: [RepositoryFileEventTarget]] = [:]
        for repository in repositories {
            guard case .watchRoot(let sourceID, _, _) = repository.source else { continue }
            repositoryTargetsBySourceID[sourceID, default: []].append(
                RepositoryFileEventTarget(repository)
            )
        }

        var indexes: [UUID: SourceRepositoryPathIndex] = [:]
        for source in sources {
            let sourceURL = RepositoryPathPolicy.canonicalURL(
                URL(fileURLWithPath: source.lastResolvedPath, isDirectory: true)
            )
            indexes[source.id] = makeSourceIndex(
                for: source,
                sourceURL: sourceURL,
                repositoryTargets: repositoryTargetsBySourceID[source.id] ?? [],
                caseSensitivityProvider: caseSensitivityProvider
            )
        }
        return indexes
    }

    static func makeSourceIndex(
        for source: WatchRoot,
        sourceURL: URL,
        repositories: [RepoDescriptor],
        caseSensitivityProvider: @escaping (URL) -> Bool
    ) -> SourceRepositoryPathIndex {
        let repositoryTargets = repositories.compactMap { repository -> RepositoryFileEventTarget? in
            guard case .watchRoot(let repositorySourceID, _, _) = repository.source,
                  repositorySourceID == source.id else { return nil }
            return RepositoryFileEventTarget(repository)
        }
        return makeSourceIndex(
            for: source,
            sourceURL: sourceURL,
            repositoryTargets: repositoryTargets,
            caseSensitivityProvider: caseSensitivityProvider
        )
    }

    private static func makeSourceIndex(
        for source: WatchRoot,
        sourceURL: URL,
        repositoryTargets: [RepositoryFileEventTarget],
        caseSensitivityProvider: @escaping (URL) -> Bool
    ) -> SourceRepositoryPathIndex {
        SourceRepositoryPathIndex(
            sourceURL: sourceURL,
            exclusions: source.exclusions,
            repositories: repositoryTargets,
            caseSensitivityProvider: caseSensitivityProvider
        )
    }

    static func makeSourceEventGroupPlans(
        _ sources: [WatchRoot],
        indexes: [UUID: SourceRepositoryPathIndex]
    ) -> [RepositoryFileEventSourceGroupPlan] {
        var disjointSet = DisjointSet(count: sources.count)
        let sourceRoots = sources.indices.compactMap { sourceIndex -> SourceRoot? in
            guard let index = indexes[sources[sourceIndex].id] else { return nil }
            return SourceRoot(
                sourceIndex: sourceIndex,
                pathComponents: index.sourceURL.pathComponents,
                caseSensitive: index.caseSensitiveVolume
            )
        }.sorted {
            if $0.pathComponents.count != $1.pathComponents.count {
                return $0.pathComponents.count < $1.pathComponents.count
            }
            if $0.caseSensitive != $1.caseSensitive {
                return !$0.caseSensitive
            }
            return $0.sourceIndex < $1.sourceIndex
        }

        var sensitiveAncestorIndex = RepositoryFileEventPathPrefixIndex()
        var insensitiveAncestorIndex = RepositoryFileEventPathPrefixIndex()
        for sourceRoot in sourceRoots {
            let insensitivePathComponents = sourceRoot.pathComponents.map { $0.lowercased() }
            if let relatedSourceIndex = sensitiveAncestorIndex.firstValue(
                onPrefixOf: sourceRoot.pathComponents
            ) {
                disjointSet.union(sourceRoot.sourceIndex, relatedSourceIndex)
            }
            if let relatedSourceIndex = insensitiveAncestorIndex.firstValue(
                onPrefixOf: insensitivePathComponents
            ) {
                disjointSet.union(sourceRoot.sourceIndex, relatedSourceIndex)
            }

            if sourceRoot.caseSensitive {
                sensitiveAncestorIndex.insert(
                    sourceRoot.pathComponents,
                    value: sourceRoot.sourceIndex
                )
            } else {
                insensitiveAncestorIndex.insert(
                    insensitivePathComponents,
                    value: sourceRoot.sourceIndex
                )
            }
        }

        var sourceIndicesByComponent: [Int: [Int]] = [:]
        for sourceIndex in sources.indices {
            let component = disjointSet.find(sourceIndex)
            sourceIndicesByComponent[component, default: []].append(sourceIndex)
        }
        let components = sourceIndicesByComponent.values.sorted { $0[0] < $1[0] }
        return components.map { sourceIndices in
            let componentSources = sourceIndices.map { sources[$0] }
            let coverageURLs = FileSystemEventMonitor.normalizedCoverage(componentSources.map {
                URL(fileURLWithPath: $0.lastResolvedPath, isDirectory: true)
            })
            return RepositoryFileEventSourceGroupPlan(
                sources: componentSources,
                coverageURLs: coverageURLs,
                key: RepositoryFileEventSourceGroupKey(coveragePaths: coverageURLs.map(\.path))
            )
        }
    }

    static func makeCoverageOwners(
        repositories: [RepoDescriptor],
        sourceIDs: Set<UUID>,
        indexes: [UUID: SourceRepositoryPathIndex]
    ) -> [UUID: RepositoryFileEventCoverageOwner] {
        var owners: [UUID: RepositoryFileEventCoverageOwner] = [:]
        for repository in repositories where repository.availability == .available {
            switch repository.source {
            case .watchRoot(let sourceID, _, _)
                where sourceIDs.contains(sourceID)
                    && indexes[sourceID]?.covers(repository.canonicalURL) == true:
                owners[repository.id] = .watchRoot(sourceID)
            default:
                owners[repository.id] = .independentRepository
            }
        }
        return owners
    }
}