import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension RepositoryRuntimeControllerTests {
    func testRepositoryFileEventRoutesRescanAndSchedulesRefreshLocally() async throws {
        let directory = try makeTestDirectory()
        let repositoryID = UUID()
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: directory,
            canonicalURL: directory,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate

        let gitDirectory = directory.appendingPathComponent(".git", isDirectory: true)
        await runtime.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [gitDirectory.path],
                sourceRescanPaths: [gitDirectory.path],
                requiresFullRescan: false
            ),
            repositoryID: repositoryID
        )

        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[repositoryID], 1)
        XCTAssertEqual(delegate.changes.count, 1)
        if let change = delegate.changes.first {
            switch change {
            case .action(.rescanSource(let sourceID)):
                XCTAssertEqual(sourceID, repository.source.id)
            default:
                XCTFail("Expected a catalog rescan action")
            }
        }

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }

    func testSourceFileEventRoutesCatalogRescan() async throws {
        let directory = try makeTestDirectory()
        let sourceID = UUID()
        var state = PersistedState()
        state.watchRoots = [
            WatchRoot(
                id: sourceID,
                displayName: "Workspace",
                bookmarkData: Data(),
                lastResolvedPath: directory.path,
                resourceID: nil,
                exclusions: []
            )
        ]
        let delegate = RuntimeTestDelegate(state: state, repositories: [])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        runtime.updateEventCoverage()

        let changedPath = directory.appendingPathComponent("new-repository").path
        await runtime.routeSourceFileEvents(
            FileEventBatch(
                paths: [changedPath],
                sourceRescanPaths: [changedPath],
                requiresFullRescan: true
            ),
            sourceID: sourceID
        )

        XCTAssertEqual(runtime.eventCoverageSnapshot.sourceWatcherIDs, [sourceID])
        XCTAssertEqual(delegate.changes.count, 1)
        if let change = delegate.changes.first {
            switch change {
            case .action(.rescanSource(let changedSourceID)):
                XCTAssertEqual(changedSourceID, sourceID)
            default:
                XCTFail("Expected a catalog rescan action")
            }
        }
        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }
    func testWatchedRootOwnsNestedRepositoryCoverageAndRoutesEvents() async throws {
        let directory = try makeTestDirectory()
        let sourceID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        var state = PersistedState()
        state.watchRoots = [
            WatchRoot(
                id: sourceID,
                displayName: "Workspace",
                bookmarkData: Data(),
                lastResolvedPath: directory.path,
                resourceID: nil,
                exclusions: []
            )
        ]
        let firstURL = directory.appendingPathComponent("first", isDirectory: true)
        let secondURL = directory.appendingPathComponent("second", isDirectory: true)
        let source = RepositorySource.watchRoot(
            id: sourceID,
            name: "Workspace",
            path: directory.path
        )
        let first = RepoDescriptor(
            id: firstID,
            source: source,
            url: firstURL,
            canonicalURL: firstURL,
            resourceID: nil,
            relativePath: "first",
            availability: .available
        )
        let second = RepoDescriptor(
            id: secondID,
            source: source,
            url: secondURL,
            canonicalURL: secondURL,
            resourceID: nil,
            relativePath: "second",
            availability: .available
        )
        let delegate = RuntimeTestDelegate(state: state, repositories: [first, second])
        let probe = ImmediateGitHubLookupProbe()
        let runtime = RepositoryRuntimeController(
            gitService: GitService(),
            githubURLLookup: { repository in await probe.lookup(repository) }
        )
        runtime.delegate = delegate
        runtime.updateEventCoverage()
        runtime.scheduleGitHubURLLookups(for: [first, second], forceRefresh: false)
        try await waitUntil(description: "nested repository GitHub URLs") {
            runtime.githubResolutionSnapshot.completedRepositoryIDs == Set([firstID, secondID])
        }
        let secondGitHubGeneration = runtime.githubResolutionSnapshot.generations[secondID]

        XCTAssertEqual(runtime.eventCoverageSnapshot.sourceWatcherIDs, [sourceID])
        XCTAssertTrue(runtime.eventCoverageSnapshot.repositoryWatcherIDs.isEmpty)
        XCTAssertEqual(runtime.eventCoverageSnapshot.coveredRepositoryIDs, [firstID, secondID])

        let configPath = firstURL.appendingPathComponent(".git/config").path
        await runtime.routeSourceFileEvents(
            FileEventBatch(
                paths: [configPath],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            sourceID: sourceID
        )
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[firstID], 1)
        XCTAssertNil(runtime.statusRefreshSnapshot.statusRequestGenerations[secondID])
        XCTAssertGreaterThan(runtime.githubResolutionSnapshot.generations[firstID] ?? 0, 0)
        XCTAssertEqual(runtime.githubResolutionSnapshot.generations[secondID], secondGitHubGeneration)

        delegate.changes.removeAll()
        let gitDirectoryPath = firstURL.appendingPathComponent(".git", isDirectory: true).path
        await runtime.routeSourceFileEvents(
            FileEventBatch(
                paths: [gitDirectoryPath],
                sourceRescanPaths: [gitDirectoryPath],
                requiresFullRescan: false
            ),
            sourceID: sourceID
        )
        let rescannedSourceIDs = delegate.changes.compactMap { change -> UUID? in
            guard case .action(.rescanSource(let changedSourceID)) = change else { return nil }
            return changedSourceID
        }
        XCTAssertEqual(rescannedSourceIDs, [sourceID])
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[firstID], 2)
        XCTAssertEqual(runtime.githubResolutionSnapshot.generations[secondID], secondGitHubGeneration)

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }
    func testOverlappingWatchRootsShareStreamsAndKeepSourceRoutingIndependent() async throws {
        let directory = try makeTestDirectory()
        let nestedRoot = directory.appendingPathComponent("nested", isDirectory: true)
        let disjointRoot = URL(fileURLWithPath: directory.path + "-disjoint", isDirectory: true)
        let outerSourceID = UUID()
        let nestedSourceID = UUID()
        let disjointSourceID = UUID()
        var state = PersistedState()
        state.watchRoots = [
            WatchRoot(
                id: outerSourceID,
                displayName: "Workspace",
                bookmarkData: Data(),
                lastResolvedPath: directory.path,
                resourceID: nil,
                exclusions: ["nested"]
            ),
            WatchRoot(
                id: nestedSourceID,
                displayName: "Nested",
                bookmarkData: Data(),
                lastResolvedPath: nestedRoot.path,
                resourceID: nil,
                exclusions: []
            ),
            WatchRoot(
                id: disjointSourceID,
                displayName: "Disjoint",
                bookmarkData: Data(),
                lastResolvedPath: disjointRoot.path,
                resourceID: nil,
                exclusions: []
            )
        ]
        let nestedRepositoryURL = nestedRoot.appendingPathComponent("repository", isDirectory: true)
        let nestedSource = RepositorySource.watchRoot(
            id: nestedSourceID,
            name: "Nested",
            path: nestedRoot.path
        )
        let nestedRepository = RepoDescriptor(
            id: UUID(),
            source: nestedSource,
            url: nestedRepositoryURL,
            canonicalURL: nestedRepositoryURL,
            resourceID: nil,
            relativePath: "repository",
            availability: .available
        )
        let delegate = RuntimeTestDelegate(state: state, repositories: [nestedRepository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        runtime.updateEventCoverage()
        try await waitUntil(description: "overlapping source streams ready") {
            runtime.eventCoverageSnapshot.sourceEventStreamCount == 2
        }
        delegate.changes.removeAll()

        XCTAssertEqual(
            runtime.eventCoverageSnapshot.sourceWatcherIDs,
            [outerSourceID, nestedSourceID, disjointSourceID]
        )
        XCTAssertEqual(runtime.eventCoverageSnapshot.sourceEventStreamCount, 2)
        XCTAssertTrue(runtime.eventCoverageSnapshot.repositoryWatcherIDs.isEmpty)
        XCTAssertEqual(runtime.eventCoverageSnapshot.coveredRepositoryIDs, [nestedRepository.id])

        let changedPath = nestedRepositoryURL.appendingPathComponent("changed.txt").path
        await runtime.routeSourceFileEvents(
            FileEventBatch(
                paths: [changedPath],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            sourceID: outerSourceID
        )
        XCTAssertTrue(delegate.changes.isEmpty)

        await runtime.routeSourceFileEvents(
            FileEventBatch(
                paths: [changedPath],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            sourceID: nestedSourceID
        )
        XCTAssertEqual(
            runtime.statusRefreshSnapshot.statusRequestGenerations[nestedRepository.id],
            1
        )

        delegate.changes.removeAll()
        for sourceID in [outerSourceID, nestedSourceID, disjointSourceID] {
            await runtime.routeSourceFileEvents(
                FileEventBatch(
                    paths: [],
                    sourceRescanPaths: [],
                    requiresFullRescan: false,
                    hasUnrepresentedChanges: true
                ),
                sourceID: sourceID
            )
        }
        let droppedRescans = Set(delegate.changes.compactMap { change -> UUID? in
            guard case .action(.rescanSource(let sourceID)) = change else { return nil }
            return sourceID
        })
        XCTAssertEqual(droppedRescans, [outerSourceID, nestedSourceID, disjointSourceID])

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
        XCTAssertTrue(runtime.eventCoverageSnapshot.sourceWatcherIDs.isEmpty)
        XCTAssertEqual(runtime.eventCoverageSnapshot.sourceEventStreamCount, 0)
    }

    func testSourceFileEventRoutesOnlyAffectedOverlappingRepositories() async throws {
        let directory = try makeTestDirectory()
        let sourceID = UUID()
        var state = PersistedState()
        state.watchRoots = [
            WatchRoot(
                id: sourceID,
                displayName: "Workspace",
                bookmarkData: Data(),
                lastResolvedPath: directory.path,
                resourceID: nil,
                exclusions: []
            )
        ]
        let source = RepositorySource.watchRoot(
            id: sourceID,
            name: "Workspace",
            path: directory.path
        )
        func makeRepository(at path: URL) -> RepoDescriptor {
            RepoDescriptor(
                id: UUID(),
                source: source,
                url: path,
                canonicalURL: path,
                resourceID: nil,
                relativePath: path.path.replacingOccurrences(of: directory.path + "/", with: ""),
                availability: .available
            )
        }
        let outer = makeRepository(at: directory.appendingPathComponent("repo", isDirectory: true))
        let nested = makeRepository(at: outer.canonicalURL.appendingPathComponent("nested", isDirectory: true))
        let boundary = makeRepository(at: directory.appendingPathComponent("repo-sibling", isDirectory: true))
        let unrelated = (0..<64).map { index in
            makeRepository(at: directory.appendingPathComponent("unrelated-\(index)", isDirectory: true))
        }
        let delegate = RuntimeTestDelegate(
            state: state,
            repositories: [outer, nested, boundary] + unrelated
        )
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        runtime.updateEventCoverage()

        await runtime.routeSourceFileEvents(
            FileEventBatch(
                paths: [nested.canonicalURL.appendingPathComponent("changed.txt").path],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            sourceID: sourceID
        )
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[outer.id], 1)
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[nested.id], 1)
        XCTAssertNil(runtime.statusRefreshSnapshot.statusRequestGenerations[boundary.id])
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations.count, 2)

        await runtime.routeSourceFileEvents(
            FileEventBatch(
                paths: [boundary.canonicalURL.appendingPathComponent("changed.txt").path],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            sourceID: sourceID
        )
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[outer.id], 1)
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[nested.id], 1)
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[boundary.id], 1)
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations.count, 3)

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }

    func testSourceFileEventRoutingPreservesExclusionAndBoundarySemantics() async throws {
        let directory = try makeTestDirectory()
        let sourceID = UUID()
        var state = PersistedState()
        let excludedFolder = directory.appendingPathComponent("Excluded", isDirectory: true)
        let siblingFolder = directory.appendingPathComponent("Excluded-sibling", isDirectory: true)
        state.watchRoots = [
            WatchRoot(
                id: sourceID,
                displayName: "Workspace",
                bookmarkData: Data(),
                lastResolvedPath: directory.path,
                resourceID: nil,
                exclusions: [
                    RepositoryPathPolicy.isCaseSensitiveVolume(at: directory) ? "Excluded" : "excluded"
                ]
            )
        ]
        let source = RepositorySource.watchRoot(
            id: sourceID,
            name: "Workspace",
            path: directory.path
        )
        let excludedRepository = RepoDescriptor(
            id: UUID(),
            source: source,
            url: excludedFolder,
            canonicalURL: excludedFolder,
            resourceID: nil,
            relativePath: "Excluded/Repo",
            availability: .available
        )
        let siblingRepository = RepoDescriptor(
            id: UUID(),
            source: source,
            url: siblingFolder,
            canonicalURL: siblingFolder,
            resourceID: nil,
            relativePath: "Excluded-sibling/Repo",
            availability: .available
        )
        let delegate = RuntimeTestDelegate(
            state: state,
            repositories: [excludedRepository, siblingRepository]
        )
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        runtime.updateEventCoverage()

        let excludedEventPath = excludedFolder.appendingPathComponent("changed.txt").path
        await runtime.routeSourceFileEvents(
            FileEventBatch(
                paths: [excludedEventPath],
                sourceRescanPaths: [excludedEventPath],
                requiresFullRescan: false
            ),
            sourceID: sourceID
        )
        XCTAssertTrue(runtime.statusRefreshSnapshot.statusRequestGenerations.isEmpty)
        XCTAssertTrue(delegate.changes.isEmpty)

        await runtime.routeSourceFileEvents(
            FileEventBatch(
                paths: [siblingFolder.appendingPathComponent("changed.txt").path],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            sourceID: sourceID
        )
        XCTAssertNil(runtime.statusRefreshSnapshot.statusRequestGenerations[excludedRepository.id])
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[siblingRepository.id], 1)
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations.count, 1)

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }

    func testStandaloneRepositoryRetainsIndependentCoverage() async {
        let repository = makeRuntimeRepository(path: "standalone-coverage-repository")
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        runtime.updateEventCoverage()

        XCTAssertTrue(runtime.eventCoverageSnapshot.sourceWatcherIDs.isEmpty)
        XCTAssertEqual(runtime.eventCoverageSnapshot.repositoryWatcherIDs, [repository.id])
        XCTAssertEqual(runtime.eventCoverageSnapshot.coveredRepositoryIDs, [repository.id])

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }
}
