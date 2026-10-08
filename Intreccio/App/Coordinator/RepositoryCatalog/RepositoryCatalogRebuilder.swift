import Foundation

nonisolated struct RepositoryCatalogRebuildResult: Sendable {
    let repositories: [RepoDescriptor]
    let snapshots: [RepositorySnapshot]
}

nonisolated enum RepositoryCatalogRebuilder {
    private struct Candidate {
        let source: RepositorySource
        let url: URL
        let canonicalURL: URL
        let resourceID: String?
        let gitDirectoryInfo: GitDirectoryInfo?
        let relativePath: String?
        let specificity: Int
    }
    private struct CatalogBuild {
        var repositories: [RepoDescriptor] = []
        var snapshots: [RepositorySnapshot] = []
        var unmatchedSnapshotIDs: Set<UUID> = []
        var candidateCanonicalPaths = Set<String>()
    }

    private struct SnapshotMatchIndex {
        let byResourceID: [String: [RepositorySnapshot]]
        let byCanonicalPath: [String: [RepositorySnapshot]]
        var unmatchedSnapshotIDs: Set<UUID>
        var resourceIdentities = Set<String>()
        var canonicalPaths = Set<String>()
    }

    private struct IncompleteFallback {
        let sourceID: UUID
        let source: RepositorySource
        let relativePath: String
        let specificity: Int
    }

    static func rebuild(
        state: PersistedState,
        sourceScans: [UUID: RepoScanResult],
        standaloneRepositories: [UUID: StandaloneRepositoryLocation],
        previousRepositories: [RepoDescriptor] = [],
        snapshotGitDirectoryInfos: [UUID: GitDirectoryInfo] = [:]
    ) -> RepositoryCatalogRebuildResult {
        let previousRepositoriesByID = previousRepositories.reduce(into: [UUID: RepoDescriptor]()) {
            $0[$1.id] = $1
        }
        let candidates = makeCandidates(
            state: state,
            sourceScans: sourceScans,
            standaloneRepositories: standaloneRepositories
        )
        var build = makeAvailableRepositories(
            candidates: candidates,
            snapshots: state.repoSnapshots,
            previousRepositoriesByID: previousRepositoriesByID
        )
        appendUnavailableRepositories(
            to: &build,
            state: state,
            sourceScans: sourceScans,
            previousRepositoriesByID: previousRepositoriesByID,
            snapshotGitDirectoryInfos: snapshotGitDirectoryInfos
        )
        let repositories = attachMainWorktreeURLs(to: build.repositories)
        return RepositoryCatalogRebuildResult(repositories: repositories, snapshots: build.snapshots)
    }
    static func snapshotsNeedingGitDirectoryInfo(
        state: PersistedState,
        sourceScans: [UUID: RepoScanResult],
        standaloneRepositories: [UUID: StandaloneRepositoryLocation],
        previousRepositories: [RepoDescriptor]
    ) -> [RepositorySnapshot] {
        let candidates = makeCandidates(
            state: state,
            sourceScans: sourceScans,
            standaloneRepositories: standaloneRepositories
        )
        let candidatePaths = Set(candidates.map { RepositoryPathPolicy.canonicalPath($0.canonicalURL.path) })
        let candidateResourceIDs = Set(candidates.compactMap(\.resourceID))
        let previousRepositoriesByID = previousRepositories.reduce(into: [UUID: RepoDescriptor]()) {
            $0[$1.id] = $1
        }
        return state.repoSnapshots.filter { snapshot in
            guard snapshot.availability == .available,
                  !candidatePaths.contains(RepositoryPathPolicy.canonicalPath(snapshot.canonicalPath)),
                  snapshot.resourceID.map({ !candidateResourceIDs.contains($0) }) ?? true,
                  source(for: snapshot.sourceID, in: state) != nil else { return false }
            let url = URL(fileURLWithPath: snapshot.canonicalPath, isDirectory: true)
            guard previousGitDirectoryInfo(
                id: snapshot.id,
                canonicalURL: url,
                repositoriesByID: previousRepositoriesByID
            ) == nil else { return false }
            if isSnapshotExcluded(snapshot, in: state) {
                return incompleteFallback(for: snapshot, state: state, sourceScans: sourceScans) != nil
            }
            return sourceScans[snapshot.sourceID]?.incompleteReason != nil
                || sourceScans[snapshot.sourceID] == nil
        }
    }

    private static func makeCandidates(
        state: PersistedState,
        sourceScans: [UUID: RepoScanResult],
        standaloneRepositories: [UUID: StandaloneRepositoryLocation]
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for source in state.watchRoots {
            let sourceKind = RepositorySource.watchRoot(
                id: source.id,
                name: source.displayName,
                path: source.lastResolvedPath
            )
            for repository in sourceScans[source.id]?.repositories ?? [] {
                candidates.append(Candidate(
                    source: sourceKind,
                    url: repository.url,
                    canonicalURL: repository.canonicalURL,
                    resourceID: repository.resourceID,
                    gitDirectoryInfo: repository.gitDirectoryInfo,
                    relativePath: repository.relativePath,
                    specificity: URL(fileURLWithPath: source.lastResolvedPath).pathComponents.count
                ))
            }
        }
        for source in state.standaloneRepos {
            guard let repository = standaloneRepositories[source.id] else { continue }
            candidates.append(Candidate(
                source: .standalone(id: source.id),
                url: repository.url,
                canonicalURL: repository.url,
                resourceID: source.resourceID,
                gitDirectoryInfo: repository.gitDirectoryInfo,
                relativePath: nil,
                specificity: -1
            ))
        }
        candidates.sort {
            if $0.specificity != $1.specificity { return $0.specificity > $1.specificity }
            return $0.canonicalURL.path.localizedStandardCompare($1.canonicalURL.path) == .orderedAscending
        }
        return candidates
    }

    private static func makeAvailableRepositories(
        candidates: [Candidate],
        snapshots: [RepositorySnapshot],
        previousRepositoriesByID: [UUID: RepoDescriptor]
    ) -> CatalogBuild {
        var index = makeSnapshotMatchIndex(snapshots)
        var build = CatalogBuild()
        for candidate in candidates {
            appendAvailableRepository(
                candidate,
                to: &build,
                using: &index,
                previousRepositoriesByID: previousRepositoriesByID
            )
        }
        build.unmatchedSnapshotIDs = index.unmatchedSnapshotIDs
        build.candidateCanonicalPaths = index.canonicalPaths
        return build
    }

    private static func makeSnapshotMatchIndex(_ snapshots: [RepositorySnapshot]) -> SnapshotMatchIndex {
        var byResourceID: [String: [RepositorySnapshot]] = [:]
        var byCanonicalPath: [String: [RepositorySnapshot]] = [:]
        var unmatchedSnapshotIDs = Set<UUID>()
        for snapshot in snapshots {
            let pathIdentity = RepositoryPathPolicy.canonicalPath(snapshot.canonicalPath)
            byCanonicalPath[pathIdentity, default: []].append(snapshot)
            if let resourceID = snapshot.resourceID {
                byResourceID[resourceID, default: []].append(snapshot)
            }
            unmatchedSnapshotIDs.insert(snapshot.id)
        }
        return SnapshotMatchIndex(
            byResourceID: byResourceID,
            byCanonicalPath: byCanonicalPath,
            unmatchedSnapshotIDs: unmatchedSnapshotIDs
        )
    }

    private static func appendAvailableRepository(
        _ candidate: Candidate,
        to build: inout CatalogBuild,
        using index: inout SnapshotMatchIndex,
        previousRepositoriesByID: [UUID: RepoDescriptor]
    ) {
        let pathIdentity = RepositoryPathPolicy.canonicalPath(candidate.canonicalURL.path)
        guard !index.canonicalPaths.contains(pathIdentity) else { return }
        if let resourceID = candidate.resourceID, index.resourceIdentities.contains(resourceID) { return }
        index.canonicalPaths.insert(pathIdentity)
        if let resourceID = candidate.resourceID { index.resourceIdentities.insert(resourceID) }
        let previous = matchedSnapshot(for: candidate, pathIdentity: pathIdentity, index: index)
        let id = previous?.id ?? UUID()
        let gitDirectoryInfo = candidate.gitDirectoryInfo ?? previousGitDirectoryInfo(
            id: id,
            canonicalURL: candidate.canonicalURL,
            repositoriesByID: previousRepositoriesByID
        )
        index.unmatchedSnapshotIDs.remove(id)
        build.snapshots.append(RepositorySnapshot(
            id: id,
            sourceID: candidate.source.id,
            relativePath: candidate.relativePath,
            canonicalPath: candidate.canonicalURL.path,
            resourceID: candidate.resourceID,
            availability: .available
        ))
        build.repositories.append(RepoDescriptor(
            id: id,
            source: candidate.source,
            url: candidate.url,
            canonicalURL: candidate.canonicalURL,
            resourceID: candidate.resourceID,
            relativePath: candidate.relativePath,
            availability: .available,
            gitDirectoryInfo: gitDirectoryInfo
        ))
    }

    private static func matchedSnapshot(
        for candidate: Candidate,
        pathIdentity: String,
        index: SnapshotMatchIndex
    ) -> RepositorySnapshot? {
        guard let resourceID = candidate.resourceID else {
            return index.byCanonicalPath[pathIdentity]?.first { index.unmatchedSnapshotIDs.contains($0.id) }
        }
        return index.byResourceID[resourceID]?.first { index.unmatchedSnapshotIDs.contains($0.id) }
            ?? index.byCanonicalPath[pathIdentity]?.first {
                index.unmatchedSnapshotIDs.contains($0.id) && $0.resourceID == nil
            }
    }

    private static func appendUnavailableRepositories(
        to build: inout CatalogBuild,
        state: PersistedState,
        sourceScans: [UUID: RepoScanResult],
        previousRepositoriesByID: [UUID: RepoDescriptor],
        snapshotGitDirectoryInfos: [UUID: GitDirectoryInfo]
    ) {
        let validSourceIDs = Set(state.watchRoots.map(\.id) + state.standaloneRepos.map(\.id))
        for snapshot in state.repoSnapshots
            where build.unmatchedSnapshotIDs.contains(snapshot.id) && validSourceIDs.contains(snapshot.sourceID) {
            let pathIdentity = RepositoryPathPolicy.canonicalPath(snapshot.canonicalPath)
            if build.candidateCanonicalPaths.contains(pathIdentity) { continue }
            if isSnapshotExcluded(snapshot, in: state) {
                appendExcludedSnapshot(
                    snapshot,
                    to: &build,
                    state: state,
                    sourceScans: sourceScans,
                    previousRepositoriesByID: previousRepositoriesByID,
                    snapshotGitDirectoryInfos: snapshotGitDirectoryInfos
                )
                continue
            }
            guard let source = source(for: snapshot.sourceID, in: state) else { continue }
            var unavailable = snapshot
            if sourceScans[snapshot.sourceID]?.incompleteReason == nil {
                unavailable.availability = .unavailable(reason: "Repository is missing or access is unavailable.")
            }
            let url = URL(fileURLWithPath: snapshot.canonicalPath, isDirectory: true)
            build.snapshots.append(unavailable)
            build.repositories.append(RepoDescriptor(
                id: snapshot.id,
                source: source,
                url: url,
                canonicalURL: url,
                resourceID: snapshot.resourceID,
                relativePath: snapshot.relativePath,
                availability: unavailable.availability,
                gitDirectoryInfo: previousGitDirectoryInfo(
                    id: snapshot.id,
                    canonicalURL: url,
                    repositoriesByID: previousRepositoriesByID
                ) ?? snapshotGitDirectoryInfos[snapshot.id]
            ))
        }
    }

    private static func appendExcludedSnapshot(
        _ snapshot: RepositorySnapshot,
        to build: inout CatalogBuild,
        state: PersistedState,
        sourceScans: [UUID: RepoScanResult],
        previousRepositoriesByID: [UUID: RepoDescriptor],
        snapshotGitDirectoryInfos: [UUID: GitDirectoryInfo]
    ) {
        guard let fallback = incompleteFallback(for: snapshot, state: state, sourceScans: sourceScans) else {
            build.snapshots.append(snapshot)
            return
        }
        build.snapshots.append(RepositorySnapshot(
            id: snapshot.id,
            sourceID: fallback.sourceID,
            relativePath: fallback.relativePath,
            canonicalPath: snapshot.canonicalPath,
            resourceID: snapshot.resourceID,
            availability: snapshot.availability
        ))
        let url = URL(fileURLWithPath: snapshot.canonicalPath, isDirectory: true)
        build.repositories.append(RepoDescriptor(
            id: snapshot.id,
            source: fallback.source,
            url: url,
            canonicalURL: url,
            resourceID: snapshot.resourceID,
            relativePath: fallback.relativePath,
            availability: snapshot.availability,
            gitDirectoryInfo: previousGitDirectoryInfo(
                id: snapshot.id,
                canonicalURL: url,
                repositoriesByID: previousRepositoriesByID
            ) ?? snapshotGitDirectoryInfos[snapshot.id]
            ))
    }

    private static func attachMainWorktreeURLs(to repositories: [RepoDescriptor]) -> [RepoDescriptor] {
        var mainURLsByGitDirectory: [String: URL] = [:]
        for repository in repositories where !repository.isLinkedWorktree {
            guard let commonGitDirectoryURL = repository.commonGitDirectoryURL else { continue }
            mainURLsByGitDirectory[commonGitDirectoryURL.standardizedFileURL.path] = repository.canonicalURL
        }
        return repositories.map { repository in
            guard repository.isLinkedWorktree,
                  let commonGitDirectoryURL = repository.commonGitDirectoryURL,
                  let mainRepositoryURL = mainURLsByGitDirectory[commonGitDirectoryURL.standardizedFileURL.path]
            else { return repository }
            return repository.withMainRepositoryURL(mainRepositoryURL)
        }
    }

    private static func previousGitDirectoryInfo(
        id: UUID,
        canonicalURL: URL,
        repositoriesByID: [UUID: RepoDescriptor]
    ) -> GitDirectoryInfo? {
        guard let repository = repositoriesByID[id],
              repository.canonicalURL.standardizedFileURL == canonicalURL.standardizedFileURL else {
            return nil
        }
        return repository.gitDirectoryInfo
    }

    private static func isSnapshotExcluded(
        _ snapshot: RepositorySnapshot,
        in state: PersistedState
    ) -> Bool {
        guard let relativePath = snapshot.relativePath,
              let source = state.watchRoots.first(where: { $0.id == snapshot.sourceID }) else { return false }
        let root = URL(fileURLWithPath: source.lastResolvedPath, isDirectory: true)
        return RepositoryPathPolicy.isExcluded(
            relativePath: relativePath,
            by: source.exclusions,
            root: root
        )
    }

    private static func incompleteFallback(
        for snapshot: RepositorySnapshot,
        state: PersistedState,
        sourceScans: [UUID: RepoScanResult]
    ) -> IncompleteFallback? {
        let repositoryURL = RepositoryPathPolicy.canonicalURL(
            URL(fileURLWithPath: snapshot.canonicalPath, isDirectory: true)
        )
        return state.watchRoots
            .filter { $0.id != snapshot.sourceID }
            .filter { sourceScans[$0.id]?.incompleteReason != nil }
            .compactMap { root -> IncompleteFallback? in
                let rootURL = RepositoryPathPolicy.canonicalURL(
                    URL(fileURLWithPath: root.lastResolvedPath, isDirectory: true)
                )
                guard RepositoryPathPolicy.contains(rootURL, repositoryURL),
                      let relativePath = RepositoryPathPolicy.relativePath(from: rootURL, to: repositoryURL),
                      !RepositoryPathPolicy.isExcluded(
                        relativePath: relativePath,
                        by: root.exclusions,
                        root: rootURL
                      ) else {
                    return nil
                }
                return IncompleteFallback(
                    sourceID: root.id,
                    source: .watchRoot(id: root.id, name: root.displayName, path: root.lastResolvedPath),
                    relativePath: relativePath,
                    specificity: rootURL.pathComponents.count
                )
            }
            .max(by: { $0.specificity < $1.specificity })
    }

    private static func source(for id: UUID, in state: PersistedState) -> RepositorySource? {
        if let root = state.watchRoots.first(where: { $0.id == id }) {
            return .watchRoot(id: root.id, name: root.displayName, path: root.lastResolvedPath)
        }
        if state.standaloneRepos.contains(where: { $0.id == id }) {
            return .standalone(id: id)
        }
        return nil
    }
}
