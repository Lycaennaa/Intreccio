import Foundation

nonisolated struct RepositoryFileEventTarget: Sendable, Equatable {
    let id: UUID
    let sourceID: UUID
    let pathComponents: [String]
    let availability: RepositoryAvailability

    init(_ repository: RepoDescriptor) {
        id = repository.id
        sourceID = repository.source.id
        pathComponents = RepositoryPathPolicy.standardizedURL(repository.canonicalURL).pathComponents
        availability = repository.availability
    }
}

nonisolated struct RepositoryFileEventPath: Sendable, Equatable {
    let path: String
    let pathComponents: [String]
    let isSourceRescan: Bool
}

nonisolated struct SourceRepositoryFileEvent: Sendable, Equatable {
    let eventPath: RepositoryFileEventPath
    let repositories: [RepositoryFileEventTarget]
    let deepestRepository: RepositoryFileEventTarget?
}

nonisolated struct SourceRepositoryNormalizedFileEventPath: Sendable {
    let path: String
    let pathComponents: [String]
    let caseInsensitivePathComponents: [String]
}

nonisolated struct SourceRepositoryNormalizedFileEventBatch: Sendable {
    let paths: [SourceRepositoryNormalizedFileEventPath]
    let sourceRescanPaths: Set<[String]>
    let caseInsensitiveSourceRescanPaths: Set<[String]>
    let normalizedPathCount: Int

    init(_ batch: FileEventBatch, needsCaseInsensitivePaths: Bool = true) {
        var normalizedPathByRawPath: [String: SourceRepositoryNormalizedFileEventPath] = [:]
        var normalizationCount = 0

        func normalize(_ rawPath: String) -> SourceRepositoryNormalizedFileEventPath {
            if let cached = normalizedPathByRawPath[rawPath] { return cached }
            let standardizedURL = RepositoryPathPolicy.standardizedURL(
                URL(fileURLWithPath: rawPath)
            )
            let pathComponents = standardizedURL.pathComponents
            let normalized = SourceRepositoryNormalizedFileEventPath(
                path: standardizedURL.path,
                pathComponents: pathComponents,
                caseInsensitivePathComponents: needsCaseInsensitivePaths
                    ? pathComponents.map { $0.lowercased() }
                    : pathComponents
            )
            normalizedPathByRawPath[rawPath] = normalized
            normalizationCount += 1
            return normalized
        }

        let normalizedPaths = batch.paths.map(normalize)
        var normalizedSourceRescanPaths = Set<[String]>()
        var caseInsensitiveSourceRescanPaths = Set<[String]>()
        for rawPath in batch.sourceRescanPaths {
            let normalized = normalize(rawPath)
            normalizedSourceRescanPaths.insert(normalized.pathComponents)
            caseInsensitiveSourceRescanPaths.insert(normalized.caseInsensitivePathComponents)
        }

        paths = normalizedPaths
        sourceRescanPaths = normalizedSourceRescanPaths
        self.caseInsensitiveSourceRescanPaths = caseInsensitiveSourceRescanPaths
        normalizedPathCount = normalizationCount
    }

    func classifier(caseSensitiveVolume: Bool) -> RepositoryFileEventPathClassifier {
        RepositoryFileEventPathClassifier(
            batch: self,
            caseSensitiveVolume: caseSensitiveVolume
        )
    }
}

nonisolated struct RepositoryFileEventPathClassifier: Sendable {
    let caseSensitiveVolume: Bool
    private let normalizedSourceRescanPaths: Set<[String]>

    init(
        batch: SourceRepositoryNormalizedFileEventBatch,
        caseSensitiveVolume: Bool
    ) {
        self.caseSensitiveVolume = caseSensitiveVolume
        normalizedSourceRescanPaths = caseSensitiveVolume
            ? batch.sourceRescanPaths
            : batch.caseInsensitiveSourceRescanPaths
    }

    func classify(_ path: SourceRepositoryNormalizedFileEventPath) -> RepositoryFileEventPath {
        RepositoryFileEventPath(
            path: path.path,
            pathComponents: path.pathComponents,
            isSourceRescan: normalizedSourceRescanPaths.contains(
                normalizedPathComponents(for: path)
            )
        )
    }

    func normalizedPathComponents(
        for path: SourceRepositoryNormalizedFileEventPath
    ) -> [String] {
        caseSensitiveVolume ? path.pathComponents : path.caseInsensitivePathComponents
    }

    func normalizedPathComponents(_ pathComponents: [String]) -> [String] {
        Self.normalizedPathComponents(pathComponents, caseSensitive: caseSensitiveVolume)
    }

    static func isRepositoryStructuralPath(
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
        return normalizedEventPath == normalizedRepositoryPath
            || (normalizedEventPath.last == ".git"
                && normalizedEventPath.dropLast().elementsEqual(normalizedRepositoryPath))
    }

    static func isGitHubConfigurationPath(
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
        guard normalizedEventPath.count == normalizedRepositoryPath.count + 2,
              normalizedEventPath.dropLast(2).elementsEqual(normalizedRepositoryPath) else {
            return false
        }
        let gitDirectoryIndex = normalizedRepositoryPath.count
        return normalizedEventPath[gitDirectoryIndex] == ".git"
            && ["config", "config.worktree"].contains(normalizedEventPath[gitDirectoryIndex + 1])
    }

    private static func normalizedPathComponents(
        _ pathComponents: [String],
        caseSensitive: Bool
    ) -> [String] {
        pathComponents.map { caseSensitive ? $0 : $0.lowercased() }
    }
}

nonisolated struct RepositoryFileEventPathPrefixIndex: Sendable {
    private struct Node: Sendable {
        var children: [String: Int] = [:]
        var value: Int?
    }

    private var nodes: [Node]

    init() {
        nodes = [Node()]
    }

    mutating func insert(_ pathComponents: [String], value: Int) {
        var nodeIndex = 0
        for component in pathComponents {
            if let childIndex = nodes[nodeIndex].children[component] {
                nodeIndex = childIndex
            } else {
                let childIndex = nodes.count
                nodes.append(Node())
                nodes[nodeIndex].children[component] = childIndex
                nodeIndex = childIndex
            }
        }
        if nodes[nodeIndex].value == nil {
            nodes[nodeIndex].value = value
        }
    }

    func firstValue(onPrefixOf pathComponents: [String]) -> Int? {
        if let value = nodes[0].value { return value }
        var nodeIndex = 0
        for component in pathComponents {
            guard let childIndex = nodes[nodeIndex].children[component] else { return nil }
            nodeIndex = childIndex
            if let value = nodes[nodeIndex].value { return value }
        }
        return nil
    }
}

nonisolated struct SourceRepositoryPathIndex: Sendable {
    private struct Node: Sendable {
        let children: [String: Int]
        let repositories: [RepositoryFileEventTarget]
    }

    private struct Builder {
        private struct MutableNode {
            var children: [String: Int] = [:]
            var repositories: [RepositoryFileEventTarget] = []
        }

        let sourcePathComponents: [String]
        let caseSensitiveVolume: Bool
        private var nodes: [MutableNode] = [MutableNode()]

        init(sourcePathComponents: [String], caseSensitiveVolume: Bool) {
            self.sourcePathComponents = sourcePathComponents
            self.caseSensitiveVolume = caseSensitiveVolume
        }

        mutating func insert(_ repository: RepositoryFileEventTarget) {
            let repositoryPathComponents = repository.pathComponents.map {
                caseSensitiveVolume ? $0 : $0.lowercased()
            }
            guard repositoryPathComponents.starts(with: sourcePathComponents) else { return }
            var nodeIndex = 0
            for component in repositoryPathComponents.dropFirst(sourcePathComponents.count) {
                if let childIndex = nodes[nodeIndex].children[component] {
                    nodeIndex = childIndex
                } else {
                    let childIndex = nodes.count
                    nodes.append(MutableNode())
                    nodes[nodeIndex].children[component] = childIndex
                    nodeIndex = childIndex
                }
            }
            nodes[nodeIndex].repositories.append(repository)
        }

        func build() -> [Node] {
            nodes.map { Node(children: $0.children, repositories: $0.repositories) }
        }
    }

    let sourceURL: URL
    let caseSensitiveVolume: Bool
    private let sourcePathComponents: [String]
    private let normalizedExclusions: Set<String>
    private let nodes: [Node]

    init(
        sourceURL: URL,
        exclusions: [String] = [],
        repositories: [RepositoryFileEventTarget] = [],
        caseSensitivityProvider: @escaping (URL) -> Bool = RepositoryPathPolicy.isCaseSensitiveVolume
    ) {
        let standardizedSourceURL = RepositoryPathPolicy.standardizedURL(sourceURL)
        let isCaseSensitive = caseSensitivityProvider(standardizedSourceURL)
        self.sourceURL = standardizedSourceURL
        caseSensitiveVolume = isCaseSensitive
        sourcePathComponents = standardizedSourceURL.pathComponents.map {
            isCaseSensitive ? $0 : $0.lowercased()
        }
        normalizedExclusions = Set(exclusions.map {
            RepositoryPathPolicy.normalizedRelativePath($0, caseSensitive: isCaseSensitive)
        })
        var builder = Builder(
            sourcePathComponents: sourcePathComponents,
            caseSensitiveVolume: isCaseSensitive
        )
        for repository in repositories {
            builder.insert(repository)
        }
        nodes = builder.build()
    }

    func covers(_ url: URL) -> Bool {
        normalizedPathComponents(
            RepositoryPathPolicy.standardizedURL(url).pathComponents
        ).starts(with: sourcePathComponents)
    }
    func partition(_ batch: FileEventBatch) -> [SourceRepositoryFileEvent] {
        partition(SourceRepositoryNormalizedFileEventBatch(batch))
    }

    func partition(
        _ batch: SourceRepositoryNormalizedFileEventBatch
    ) -> [SourceRepositoryFileEvent] {
        let classifier = batch.classifier(caseSensitiveVolume: caseSensitiveVolume)
        return batch.paths.compactMap { path in
            let eventPath = classifier.classify(path)
            let normalizedEventPathComponents = classifier.normalizedPathComponents(for: path)
            guard normalizedEventPathComponents.starts(with: sourcePathComponents) else { return nil }

            let relativeComponents = normalizedEventPathComponents.dropFirst(sourcePathComponents.count)
            let relativePath = relativeComponents.isEmpty
                ? "."
                : relativeComponents.joined(separator: "/")
            guard !isExcluded(normalizedRelativePath: relativePath) else { return nil }

            let repositories = matchingRepositories(for: normalizedEventPathComponents)
            var deepestRepository: RepositoryFileEventTarget?
            for repository in repositories
                where repository.pathComponents.count > (deepestRepository?.pathComponents.count ?? -1) {
                deepestRepository = repository
            }
            return SourceRepositoryFileEvent(
                eventPath: eventPath,
                repositories: repositories,
                deepestRepository: deepestRepository
            )
        }
    }

    func partitionedEventCount(_ batch: FileEventBatch) -> Int {
        partition(batch).count
    }

    private func normalizedPathComponents(_ pathComponents: [String]) -> [String] {
        pathComponents.map { caseSensitiveVolume ? $0 : $0.lowercased() }
    }

    private func isExcluded(normalizedRelativePath: String) -> Bool {
        let normalizedPath = normalizedRelativePath == "." ? "" : normalizedRelativePath
        return normalizedExclusions.contains { exclusion in
            exclusion.isEmpty
                || normalizedPath == exclusion
                || normalizedPath.hasPrefix(exclusion + "/")
        }
    }

    private func matchingRepositories(for pathComponents: [String]) -> [RepositoryFileEventTarget] {
        guard pathComponents.starts(with: sourcePathComponents) else { return [] }
        var nodeIndex = 0
        var repositories = nodes[nodeIndex].repositories
        for component in pathComponents.dropFirst(sourcePathComponents.count) {
            guard let childIndex = nodes[nodeIndex].children[component] else { break }
            nodeIndex = childIndex
            repositories.append(contentsOf: nodes[nodeIndex].repositories)
        }
        return repositories
    }
}
