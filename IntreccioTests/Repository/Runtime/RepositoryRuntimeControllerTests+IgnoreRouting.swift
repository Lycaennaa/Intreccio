import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension RepositoryRuntimeControllerTests {
    func testIgnoredRepositoryFileEventsDoNotScheduleStatusRefresh() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("ignored/\n", to: ".gitignore")
        let repositoryID = UUID()
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: fixture.url,
            canonicalURL: fixture.url,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate

        await runtime.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [fixture.url.appendingPathComponent("ignored/file.txt").path],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            repositoryID: repositoryID
        )
        XCTAssertNil(runtime.statusRefreshSnapshot.statusRequestGenerations[repositoryID])

        await runtime.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [fixture.url.appendingPathComponent("visible.txt").path],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            repositoryID: repositoryID
        )
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[repositoryID], 1)

        await runtime.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [fixture.url.appendingPathComponent("ignored/file.txt").path],
                sourceRescanPaths: [],
                requiresFullRescan: true
            ),
            repositoryID: repositoryID
        )
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[repositoryID], 2)

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }

    func testUpstreamRefreshMetadataDoesNotRequeueStatusButRelevantGitFilesDo() async throws {
        let fixture = try GitFixture(testCase: self)
        let repositoryID = UUID()
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: fixture.url,
            canonicalURL: fixture.url,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        let packPath = fixture.url.appendingPathComponent(".git/objects/pack/pack-test.pack").path

        await runtime.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [
                    fixture.url.appendingPathComponent(".git", isDirectory: true).path,
                    packPath,
                    fixture.url.appendingPathComponent(".git/refs/remotes/origin/main").path,
                    fixture.url.appendingPathComponent(".git/logs/refs/remotes/origin/main").path
                ],
                sourceRescanPaths: [packPath],
                requiresFullRescan: false
            ),
            repositoryID: repositoryID
        )
        XCTAssertNil(runtime.statusRefreshSnapshot.statusRequestGenerations[repositoryID])

        await runtime.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [fixture.url.appendingPathComponent(".gitignore").path],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            repositoryID: repositoryID
        )
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[repositoryID], 1)

        await runtime.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [
                    fixture.url.appendingPathComponent(".git/index").path,
                    fixture.url.appendingPathComponent(".git/refs/heads/main").path
                ],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            repositoryID: repositoryID
        )
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[repositoryID], 2)

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }

    func testSourceEventAppliesIgnoreRulesPerOverlappingRepository() async throws {
        let fixture = try GitFixture(testCase: self)
        let nestedURL = fixture.url.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try runGit(at: nestedURL, arguments: ["init", "-b", "main"])
        try fixture.write("nested/shared.txt\n", to: ".gitignore")

        let sourceID = UUID()
        var state = PersistedState()
        state.watchRoots = [WatchRoot(
            id: sourceID,
            displayName: "Workspace",
            bookmarkData: Data(),
            lastResolvedPath: fixture.url.path,
            resourceID: nil,
            exclusions: []
        )]
        let source = RepositorySource.watchRoot(
            id: sourceID,
            name: "Workspace",
            path: fixture.url.path
        )
        let outerID = UUID()
        let nestedID = UUID()
        let outer = RepoDescriptor(
            id: outerID,
            source: source,
            url: fixture.url,
            canonicalURL: fixture.url,
            resourceID: nil,
            relativePath: ".",
            availability: .available
        )
        let nested = RepoDescriptor(
            id: nestedID,
            source: source,
            url: nestedURL,
            canonicalURL: nestedURL,
            resourceID: nil,
            relativePath: "nested",
            availability: .available
        )
        let delegate = RuntimeTestDelegate(state: state, repositories: [outer, nested])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        runtime.updateEventCoverage()

        await runtime.routeSourceFileEvents(
            FileEventBatch(
                paths: [nestedURL.appendingPathComponent("shared.txt").path],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            sourceID: sourceID
        )

        XCTAssertNil(runtime.statusRefreshSnapshot.statusRequestGenerations[outerID])
        XCTAssertEqual(runtime.statusRefreshSnapshot.statusRequestGenerations[nestedID], 1)
        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }
}
