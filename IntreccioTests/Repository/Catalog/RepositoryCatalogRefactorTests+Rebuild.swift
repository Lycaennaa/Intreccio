import Foundation
@testable import Intreccio
import XCTest

extension RepositoryCatalogRefactorTests {
    func testRebuildPreservesSnapshotMatchingParityAcrossConflictsAndUnmatchedSnapshots() {
        let watchRootID = UUID()
        let standaloneID = UUID()
        let alphaID = UUID()
        let betaID = UUID()
        let conflictResourceID = UUID()
        let conflictPathID = UUID()
        let pathResourceID = UUID()
        let standaloneSnapshotID = UUID()
        let missingID = UUID()
        let excludedID = UUID()
        let removedID = UUID()
        let removedSourceID = UUID()
        let watchRoot = WatchRoot(
            id: watchRootID,
            displayName: "Workspace",
            bookmarkData: Data(),
            lastResolvedPath: "/workspace",
            resourceID: "workspace-resource",
            exclusions: ["excluded"]
        )
        let standalone = StandaloneRepository(
            id: standaloneID,
            displayName: "Standalone",
            bookmarkData: Data(),
            lastResolvedPath: "/standalone",
            resourceID: nil
        )
        func scanned(_ path: String, relativePath: String, resourceID: String?) -> ScannedRepository {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return ScannedRepository(
                url: url,
                canonicalURL: url,
                relativePath: relativePath,
                resourceID: resourceID
            )
        }

        var state = PersistedState()
        state.watchRoots = [watchRoot]
        state.standaloneRepos = [standalone]
        state.repoSnapshots = [
            RepositorySnapshot(
                id: alphaID,
                sourceID: watchRootID,
                relativePath: "old-alpha",
                canonicalPath: "/old/alpha",
                resourceID: "alpha-resource",
                availability: .available
            ),
            RepositorySnapshot(
                id: betaID,
                sourceID: watchRootID,
                relativePath: "old-beta",
                canonicalPath: "/old/beta",
                resourceID: "shared-resource",
                availability: .available
            ),
            RepositorySnapshot(
                id: conflictResourceID,
                sourceID: watchRootID,
                relativePath: "conflict",
                canonicalPath: "/workspace/conflict",
                resourceID: "different-resource",
                availability: .available
            ),
            RepositorySnapshot(
                id: conflictPathID,
                sourceID: watchRootID,
                relativePath: "conflict",
                canonicalPath: "/workspace/conflict",
                resourceID: nil,
                availability: .available
            ),
            RepositorySnapshot(
                id: pathResourceID,
                sourceID: watchRootID,
                relativePath: "path",
                canonicalPath: "/workspace/path",
                resourceID: "path-resource",
                availability: .available
            ),
            RepositorySnapshot(
                id: standaloneSnapshotID,
                sourceID: standaloneID,
                relativePath: nil,
                canonicalPath: "/standalone",
                resourceID: nil,
                availability: .available
            ),
            RepositorySnapshot(
                id: missingID,
                sourceID: watchRootID,
                relativePath: "missing",
                canonicalPath: "/workspace/missing",
                resourceID: "missing-resource",
                availability: .available
            ),
            RepositorySnapshot(
                id: excludedID,
                sourceID: watchRootID,
                relativePath: "excluded/child",
                canonicalPath: "/workspace/excluded/child",
                resourceID: "excluded-resource",
                availability: .available
            ),
            RepositorySnapshot(
                id: removedID,
                sourceID: removedSourceID,
                relativePath: nil,
                canonicalPath: "/removed",
                resourceID: "removed-resource",
                availability: .available
            )
        ]
        let scan = RepoScanResult(
            repositories: [
                scanned("/workspace/zeta", relativePath: "zeta", resourceID: "shared-resource"),
                scanned("/workspace/path", relativePath: "path", resourceID: nil),
                scanned("/workspace/conflict", relativePath: "conflict", resourceID: "new-resource"),
                scanned("/workspace/beta", relativePath: "beta", resourceID: "shared-resource"),
                scanned("/workspace/alpha", relativePath: "alpha", resourceID: "alpha-resource"),
                scanned("/workspace/path", relativePath: "path", resourceID: nil)
            ],
            warnings: [],
            incompleteReason: nil,
            visitedDirectoryCount: 1,
            duration: .zero
        )

        let result = RepositoryCatalogRebuilder.rebuild(
            state: state,
            sourceScans: [watchRootID: scan],
            standaloneRepositories: [
                standaloneID: StandaloneRepositoryLocation(
                    url: URL(fileURLWithPath: "/standalone", isDirectory: true),
                    gitDirectoryInfo: nil
                )
            ]
        )

        XCTAssertEqual(
            result.repositories.map(\.id),
            [alphaID, betaID, conflictPathID, pathResourceID, standaloneSnapshotID, missingID]
        )
        XCTAssertEqual(
            result.repositories.map(\.canonicalURL.path),
            [
                "/workspace/alpha",
                "/workspace/beta",
                "/workspace/conflict",
                "/workspace/path",
                "/standalone",
                "/workspace/missing"
            ]
        )
        XCTAssertEqual(result.snapshots, [
            RepositorySnapshot(
                id: alphaID,
                sourceID: watchRootID,
                relativePath: "alpha",
                canonicalPath: "/workspace/alpha",
                resourceID: "alpha-resource",
                availability: .available
            ),
            RepositorySnapshot(
                id: betaID,
                sourceID: watchRootID,
                relativePath: "beta",
                canonicalPath: "/workspace/beta",
                resourceID: "shared-resource",
                availability: .available
            ),
            RepositorySnapshot(
                id: conflictPathID,
                sourceID: watchRootID,
                relativePath: "conflict",
                canonicalPath: "/workspace/conflict",
                resourceID: "new-resource",
                availability: .available
            ),
            RepositorySnapshot(
                id: pathResourceID,
                sourceID: watchRootID,
                relativePath: "path",
                canonicalPath: "/workspace/path",
                resourceID: nil,
                availability: .available
            ),
            RepositorySnapshot(
                id: standaloneSnapshotID,
                sourceID: standaloneID,
                relativePath: nil,
                canonicalPath: "/standalone",
                resourceID: nil,
                availability: .available
            ),
            RepositorySnapshot(
                id: missingID,
                sourceID: watchRootID,
                relativePath: "missing",
                canonicalPath: "/workspace/missing",
                resourceID: "missing-resource",
                availability: .unavailable(reason: "Repository is missing or access is unavailable.")
            ),
            RepositorySnapshot(
                id: excludedID,
                sourceID: watchRootID,
                relativePath: "excluded/child",
                canonicalPath: "/workspace/excluded/child",
                resourceID: "excluded-resource",
                availability: .available
            )
        ])
        XCTAssertFalse(result.repositories.contains { $0.id == conflictResourceID })
        XCTAssertFalse(result.repositories.contains { $0.id == excludedID })
        XCTAssertFalse(result.repositories.contains { $0.id == removedID })
    }

    func testIncompleteScanPreservesCachedLinkedWorktreeMetadata() {
        let sourceID = UUID()
        let mainID = UUID()
        let linkedID = UUID()
        let source = WatchRoot(
            id: sourceID,
            displayName: "Workspace",
            bookmarkData: Data(),
            lastResolvedPath: "/workspace",
            resourceID: nil,
            exclusions: []
        )
        var state = PersistedState()
        state.watchRoots = [source]
        state.repoSnapshots = [
            RepositorySnapshot(
                id: mainID,
                sourceID: sourceID,
                relativePath: "main",
                canonicalPath: "/workspace/main",
                resourceID: nil,
                availability: .available
            ),
            RepositorySnapshot(
                id: linkedID,
                sourceID: sourceID,
                relativePath: "linked",
                canonicalPath: "/workspace/linked",
                resourceID: nil,
                availability: .available
            )
        ]
        let sourceDescriptor = RepositorySource.watchRoot(
            id: sourceID,
            name: source.displayName,
            path: source.lastResolvedPath
        )
        let mainURL = URL(fileURLWithPath: "/workspace/main", isDirectory: true)
        let linkedURL = URL(fileURLWithPath: "/workspace/linked", isDirectory: true)
        let commonGitDirectoryURL = URL(fileURLWithPath: "/workspace/main/.git", isDirectory: true)
        let previousRepositories = [
            RepoDescriptor(
                id: mainID,
                source: sourceDescriptor,
                url: mainURL,
                canonicalURL: mainURL,
                resourceID: nil,
                relativePath: "main",
                availability: .available,
                gitDirectoryInfo: GitDirectoryInfo(
                    commonGitDirectoryURL: commonGitDirectoryURL,
                    isLinkedWorktree: false
                )
            ),
            RepoDescriptor(
                id: linkedID,
                source: sourceDescriptor,
                url: linkedURL,
                canonicalURL: linkedURL,
                resourceID: nil,
                relativePath: "linked",
                availability: .available,
                gitDirectoryInfo: GitDirectoryInfo(
                    commonGitDirectoryURL: commonGitDirectoryURL,
                    isLinkedWorktree: true
                )
            )
        ]
        let scan = RepoScanResult(
            repositories: [],
            warnings: [],
            incompleteReason: "Scan stopped at repository limit.",
            visitedDirectoryCount: 50,
            duration: .zero
        )

        let result = RepositoryCatalogRebuilder.rebuild(
            state: state,
            sourceScans: [sourceID: scan],
            standaloneRepositories: [:],
            previousRepositories: previousRepositories
        )

        let linked = result.repositories.first { $0.id == linkedID }
        XCTAssertEqual(linked?.availability, .available)
        XCTAssertTrue(linked?.isLinkedWorktree == true)
        XCTAssertEqual(linked?.mainRepositoryURL, mainURL)
    }

    func testExcludedSnapshotFallbackPreservesLinkedWorktreeMetadata() {
        let excludedSourceID = UUID()
        let fallbackSourceID = UUID()
        let linkedID = UUID()
        let excludedSource = WatchRoot(
            id: excludedSourceID,
            displayName: "Excluded source",
            bookmarkData: Data(),
            lastResolvedPath: "/workspace",
            resourceID: nil,
            exclusions: ["linked"]
        )
        let fallbackSource = WatchRoot(
            id: fallbackSourceID,
            displayName: "Fallback source",
            bookmarkData: Data(),
            lastResolvedPath: "/workspace",
            resourceID: nil,
            exclusions: []
        )
        var state = PersistedState()
        state.watchRoots = [excludedSource, fallbackSource]
        state.repoSnapshots = [RepositorySnapshot(
            id: linkedID,
            sourceID: excludedSourceID,
            relativePath: "linked",
            canonicalPath: "/workspace/linked",
            resourceID: nil,
            availability: .available
        )]
        let source = RepositorySource.watchRoot(
            id: excludedSourceID,
            name: excludedSource.displayName,
            path: excludedSource.lastResolvedPath
        )
        let linkedURL = URL(fileURLWithPath: "/workspace/linked", isDirectory: true)
        let commonGitDirectoryURL = URL(fileURLWithPath: "/workspace/main/.git", isDirectory: true)
        let previousRepository = RepoDescriptor(
            id: linkedID,
            source: source,
            url: linkedURL,
            canonicalURL: linkedURL,
            resourceID: nil,
            relativePath: "linked",
            availability: .available,
            gitDirectoryInfo: GitDirectoryInfo(
                commonGitDirectoryURL: commonGitDirectoryURL,
                isLinkedWorktree: true
            )
        )

        let result = RepositoryCatalogRebuilder.rebuild(
            state: state,
            sourceScans: [
                excludedSourceID: RepoScanResult(
                    repositories: [],
                    warnings: [],
                    incompleteReason: nil,
                    visitedDirectoryCount: 1,
                    duration: .zero
                ),
                fallbackSourceID: RepoScanResult(
                    repositories: [],
                    warnings: [],
                    incompleteReason: "Scan stopped at repository limit.",
                    visitedDirectoryCount: 50,
                    duration: .zero
                )
            ],
            standaloneRepositories: [:],
            previousRepositories: [previousRepository]
        )

        let linked = result.repositories.first { $0.id == linkedID }
        XCTAssertEqual(linked?.source.id, fallbackSourceID)
        XCTAssertTrue(linked?.isLinkedWorktree == true)
    }

    func testRebuildPreservesCanonicalPathMatchingThroughSymlinks() throws {
        let directory = try makeTestDirectory()
        let realURL = directory.appendingPathComponent("Real", isDirectory: true)
        let aliasURL = directory.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: realURL)

        let sourceID = UUID()
        let snapshotID = UUID()
        let source = WatchRoot(
            id: sourceID,
            displayName: "Workspace",
            bookmarkData: Data(),
            lastResolvedPath: directory.path,
            resourceID: nil,
            exclusions: []
        )
        var state = PersistedState()
        state.watchRoots = [source]
        state.repoSnapshots = [RepositorySnapshot(
            id: snapshotID,
            sourceID: sourceID,
            relativePath: "Real",
            canonicalPath: realURL.path,
            resourceID: nil,
            availability: .available
        )]
        let result = RepositoryCatalogRebuilder.rebuild(
            state: state,
            sourceScans: [sourceID: RepoScanResult(
                repositories: [ScannedRepository(
                    url: aliasURL,
                    canonicalURL: aliasURL,
                    relativePath: "Alias",
                    resourceID: nil
                )],
                warnings: [],
                incompleteReason: nil,
                visitedDirectoryCount: 1,
                duration: .zero
            )],
            standaloneRepositories: [:]
        )

        XCTAssertEqual(result.repositories.map(\.id), [snapshotID])
        XCTAssertEqual(result.repositories.first?.canonicalURL.path, aliasURL.path)
        XCTAssertEqual(result.snapshots.first?.canonicalPath, aliasURL.path)
    }
}
