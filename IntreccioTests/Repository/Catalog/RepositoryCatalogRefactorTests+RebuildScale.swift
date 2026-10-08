import Foundation
@testable import Intreccio
import XCTest

extension RepositoryCatalogRefactorTests {
    func testRebuildHandlesLargeCandidateAndSnapshotSets() {
        let count = 4_096
        let sourceID = UUID()
        let snapshotIDs = (0..<count).map { _ in UUID() }
        let source = WatchRoot(
            id: sourceID,
            displayName: "Large",
            bookmarkData: Data(),
            lastResolvedPath: "/large",
            resourceID: nil,
            exclusions: []
        )
        let repositories = (0..<count).map { index in
            let path = "/large/repository-\(index)"
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return ScannedRepository(
                url: url,
                canonicalURL: url,
                relativePath: "repository-\(index)",
                resourceID: "resource-\(index)"
            )
        }
        var state = PersistedState()
        state.watchRoots = [source]
        state.repoSnapshots = (0..<count).reversed().map { index in
            RepositorySnapshot(
                id: snapshotIDs[index],
                sourceID: sourceID,
                relativePath: "old-\(index)",
                canonicalPath: "/old/repository-\(index)",
                resourceID: "resource-\(index)",
                availability: .available
            )
        }
        let result = RepositoryCatalogRebuilder.rebuild(
            state: state,
            sourceScans: [sourceID: RepoScanResult(
                repositories: repositories,
                warnings: [],
                incompleteReason: nil,
                visitedDirectoryCount: count,
                duration: .zero
            )],
            standaloneURLs: [:]
        )
        let expectedIndices = (0..<count).sorted {
            "/large/repository-\($0)".localizedStandardCompare("/large/repository-\($1)") == .orderedAscending
        }

        XCTAssertEqual(result.repositories.count, count)
        XCTAssertEqual(result.snapshots.count, count)
        XCTAssertEqual(result.repositories.map(\.id), expectedIndices.map { snapshotIDs[$0] })
        XCTAssertEqual(result.snapshots.map(\.id), expectedIndices.map { snapshotIDs[$0] })
        XCTAssertEqual(
            result.repositories.map(\.canonicalURL.path),
            expectedIndices.map { "/large/repository-\($0)" }
        )
    }
    func testRepositoryCatalogIndexTargetLookupPreservesCatalogOrder() {
        let first = makeRuntimeRepository(path: "catalog-index-first")
        let second = makeRuntimeRepository(path: "catalog-index-second")
        let unavailableID = UUID()
        let unavailableURL = URL(fileURLWithPath: "catalog-index-unavailable", isDirectory: true)
        let unavailable = RepoDescriptor(
            id: unavailableID,
            source: .standalone(id: unavailableID),
            url: unavailableURL,
            canonicalURL: unavailableURL,
            resourceID: nil,
            relativePath: nil,
            availability: .unavailable(reason: "missing")
        )
        let index = RepositoryCatalogIndex(repositories: [first, unavailable, second])

        XCTAssertEqual(
            index.availableRepositories(for: Set([second.id, unavailable.id, first.id])),
            [first, second]
        )
        XCTAssertEqual(index.repository(for: unavailable.id), unavailable)
    }

    func testRepositoryCatalogIndexKeepsFirstDuplicateRepository() {
        let repositoryID = UUID()
        let firstURL = URL(fileURLWithPath: "catalog-index-duplicate-first", isDirectory: true)
        let secondURL = URL(fileURLWithPath: "catalog-index-duplicate-second", isDirectory: true)
        let first = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: firstURL,
            canonicalURL: firstURL,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let duplicate = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: secondURL,
            canonicalURL: secondURL,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        XCTAssertEqual(RepositoryCatalogIndex.firstRepositories([first, duplicate]), [first])
        XCTAssertEqual(RepositoryCatalogIndex(repositories: [first, duplicate]).repository(for: repositoryID), first)
    }

}
