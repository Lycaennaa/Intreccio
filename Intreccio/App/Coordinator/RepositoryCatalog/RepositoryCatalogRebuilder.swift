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
        let relativePath: String?
        let specificity: Int
    }

    static func rebuild(
        state: PersistedState,
        sourceScans: [UUID: RepoScanResult],
        standaloneURLs: [UUID: URL]
    ) -> RepositoryCatalogRebuildResult {
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
                    relativePath: repository.relativePath,
                    specificity: URL(fileURLWithPath: source.lastResolvedPath).pathComponents.count
                ))
            }
        }
        for source in state.standaloneRepos {
            guard let url = standaloneURLs[source.id] else { continue }
            candidates.append(Candidate(
                source: .standalone(id: source.id),
                url: url,
                canonicalURL: url,
                resourceID: source.resourceID,
                relativePath: nil,
                specificity: -1
            ))
        }
        candidates.sort {
            if $0.specificity != $1.specificity { return $0.specificity > $1.specificity }
            return $0.canonicalURL.path.localizedStandardCompare($1.canonicalURL.path) == .orderedAscending
        }

        var resourceIdentities = Set<String>()
        var canonicalPaths = Set<String>()
        var snapshotsByResourceID: [String: [RepositorySnapshot]] = [:]
        var snapshotsByCanonicalPath: [String: [RepositorySnapshot]] = [:]
        var unmatchedSnapshotIDs = Set<UUID>()
        for snapshot in state.repoSnapshots {
            let pathIdentity = RepositoryPathPolicy.canonicalPath(snapshot.canonicalPath)
            snapshotsByCanonicalPath[pathIdentity, default: []].append(snapshot)
            if let resourceID = snapshot.resourceID {
                snapshotsByResourceID[resourceID, default: []].append(snapshot)
            }
            unmatchedSnapshotIDs.insert(snapshot.id)
        }
        var descriptors: [RepoDescriptor] = []
        var snapshots: [RepositorySnapshot] = []
        for candidate in candidates {
            let pathIdentity = RepositoryPathPolicy.canonicalPath(candidate.canonicalURL.path)
            if canonicalPaths.contains(pathIdentity) { continue }
            if let resourceID = candidate.resourceID, resourceIdentities.contains(resourceID) { continue }
            canonicalPaths.insert(pathIdentity)
            if let resourceID = candidate.resourceID { resourceIdentities.insert(resourceID) }
            let previous: RepositorySnapshot?
            if let resourceID = candidate.resourceID {
                previous = snapshotsByResourceID[resourceID]?.first {
                    unmatchedSnapshotIDs.contains($0.id)
                } ?? snapshotsByCanonicalPath[pathIdentity]?.first {
                    unmatchedSnapshotIDs.contains($0.id) && $0.resourceID == nil
                }
            } else {
                previous = snapshotsByCanonicalPath[pathIdentity]?.first {
                    unmatchedSnapshotIDs.contains($0.id)
                }
            }
            let id = previous?.id ?? UUID()
            unmatchedSnapshotIDs.remove(id)
            snapshots.append(RepositorySnapshot(
                id: id,
                sourceID: candidate.source.id,
                relativePath: candidate.relativePath,
                canonicalPath: candidate.canonicalURL.path,
                resourceID: candidate.resourceID,
                availability: .available
            ))
            descriptors.append(RepoDescriptor(
                id: id,
                source: candidate.source,
                url: candidate.url,
                canonicalURL: candidate.canonicalURL,
                resourceID: candidate.resourceID,
                relativePath: candidate.relativePath,
                availability: .available
            ))
        }

        let validSourceIDs = Set(state.watchRoots.map(\.id) + state.standaloneRepos.map(\.id))
        for snapshot in state.repoSnapshots
            where unmatchedSnapshotIDs.contains(snapshot.id) && validSourceIDs.contains(snapshot.sourceID) {
            if canonicalPaths.contains(RepositoryPathPolicy.canonicalPath(snapshot.canonicalPath)) { continue }
            if isSnapshotExcluded(snapshot, in: state) {
                if let fallback = incompleteFallback(for: snapshot, state: state, sourceScans: sourceScans) {
                    snapshots.append(RepositorySnapshot(
                        id: snapshot.id,
                        sourceID: fallback.sourceID,
                        relativePath: fallback.relativePath,
                        canonicalPath: snapshot.canonicalPath,
                        resourceID: snapshot.resourceID,
                        availability: snapshot.availability
                    ))
                    descriptors.append(RepoDescriptor(
                        id: snapshot.id,
                        source: fallback.source,
                        url: URL(fileURLWithPath: snapshot.canonicalPath, isDirectory: true),
                        canonicalURL: URL(fileURLWithPath: snapshot.canonicalPath, isDirectory: true),
                        resourceID: snapshot.resourceID,
                        relativePath: fallback.relativePath,
                        availability: snapshot.availability
                    ))
                } else {
                    snapshots.append(snapshot)
                }
                continue
            }
            guard let source = source(for: snapshot.sourceID, in: state) else { continue }
            var unavailable = snapshot
            if sourceScans[snapshot.sourceID]?.incompleteReason == nil {
                unavailable.availability = .unavailable(reason: "Repository is missing or access is unavailable.")
            }
            snapshots.append(unavailable)
            let url = URL(fileURLWithPath: snapshot.canonicalPath, isDirectory: true)
            descriptors.append(RepoDescriptor(
                id: snapshot.id,
                source: source,
                url: url,
                canonicalURL: url,
                resourceID: snapshot.resourceID,
                relativePath: snapshot.relativePath,
                availability: unavailable.availability
            ))
        }
        return RepositoryCatalogRebuildResult(repositories: descriptors, snapshots: snapshots)
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
    ) -> (sourceID: UUID, source: RepositorySource, relativePath: String)? {
        let repositoryURL = RepositoryPathPolicy.canonicalURL(
            URL(fileURLWithPath: snapshot.canonicalPath, isDirectory: true)
        )
        return state.watchRoots
            .filter { $0.id != snapshot.sourceID }
            .filter { sourceScans[$0.id]?.incompleteReason != nil }
            .compactMap { root -> (sourceID: UUID, source: RepositorySource, relativePath: String, specificity: Int)? in
                let rootURL = RepositoryPathPolicy.canonicalURL(
                    URL(fileURLWithPath: root.lastResolvedPath, isDirectory: true)
                )
                guard RepositoryPathPolicy.contains(rootURL, repositoryURL),
                      let relativePath = RepositoryPathPolicy.relativePath(from: rootURL, to: repositoryURL),
                      !RepositoryPathPolicy.isExcluded(relativePath: relativePath, by: root.exclusions, root: rootURL) else {
                    return nil
                }
                return (
                    root.id,
                    .watchRoot(id: root.id, name: root.displayName, path: root.lastResolvedPath),
                    relativePath,
                    rootURL.pathComponents.count
                )
            }
            .max(by: { $0.specificity < $1.specificity })
            .map { ($0.sourceID, $0.source, $0.relativePath) }
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