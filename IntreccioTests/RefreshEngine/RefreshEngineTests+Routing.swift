import Foundation
@testable import Intreccio
import XCTest

extension RefreshEngineTests {
    @MainActor
    func testSourceEventGroupRouterPartitionsOverlappingSourcesOnce() {
        let outerRoot = URL(fileURLWithPath: "/work/Source", isDirectory: true)
        let nestedRoot = outerRoot.appendingPathComponent("Nested", isDirectory: true)
        let outerSourceID = UUID()
        let nestedSourceID = UUID()
        let outerIndex = SourceRepositoryPathIndex(
            sourceURL: outerRoot,
            exclusions: ["Nested"]
        ) { _ in true }
        let nestedIndex = SourceRepositoryPathIndex(
            sourceURL: nestedRoot
        ) { _ in true }
        let events = [
            FileSystemEvent(
                path: outerRoot.appendingPathComponent("outside/changed.txt").path,
                requiresFullRescan: false
            ),
            FileSystemEvent(
                path: nestedRoot.appendingPathComponent("repository/changed.txt").path,
                requiresFullRescan: false
            ),
            FileSystemEvent(
                path: nestedRoot.appendingPathComponent(".git", isDirectory: true).path,
                requiresFullRescan: false,
                requiresSourceRescan: true
            ),
            FileSystemEvent(
                path: outerRoot.appendingPathComponent("Nested-sibling/changed.txt").path,
                requiresFullRescan: false
            )
        ]
        let router = SourceRepositoryFileEventGroupRouter(sourceIndexes: [
            outerSourceID: outerIndex,
            nestedSourceID: nestedIndex
        ])

        let partition = router.partition(events)
        let outerEvents = partition.slicesBySourceID[outerSourceID]?.events ?? []
        let nestedEvents = partition.slicesBySourceID[nestedSourceID]?.events ?? []
        func pathKey(_ event: SourceRepositoryFileEvent) -> String {
            event.eventPath.pathComponents.joined(separator: "\u{0}")
        }

        XCTAssertEqual(partition.normalizedPathCount, events.count)
        XCTAssertEqual(
            Set(outerEvents.map(pathKey)),
            Set([
                outerRoot.appendingPathComponent("outside/changed.txt").path,
                outerRoot.appendingPathComponent("Nested-sibling/changed.txt").path
            ].map { URL(fileURLWithPath: $0).pathComponents.joined(separator: "\u{0}") })
        )
        XCTAssertEqual(
            Set(nestedEvents.map(pathKey)),
            Set([
                nestedRoot.appendingPathComponent("repository/changed.txt").path,
                nestedRoot.appendingPathComponent(".git", isDirectory: true).path
            ].map { URL(fileURLWithPath: $0).pathComponents.joined(separator: "\u{0}") })
        )
        XCTAssertTrue(nestedEvents.contains(where: \.eventPath.isSourceRescan))
        XCTAssertFalse(outerEvents.contains(where: \.eventPath.isSourceRescan))
        let droppedPartition = router.partition([
            FileSystemEvent(
                path: outerRoot.path,
                requiresFullRescan: true,
                hasUnrepresentedChanges: true
            )
        ])
        XCTAssertTrue(droppedPartition.slicesBySourceID.values.allSatisfy {
            $0.rawBatch.requiresFullRescan && $0.rawBatch.hasUnrepresentedChanges
        })
    }

    @MainActor
    func testSourceEventGroupRouterMatchesIndependentPartitionsAndRepositoryRouting() {
        let outerRoot = URL(fileURLWithPath: "/work/Source", isDirectory: true)
        let nestedRoot = outerRoot.appendingPathComponent("Nested", isDirectory: true)
        let nestedRepositoryURL = nestedRoot.appendingPathComponent("Repository", isDirectory: true)
        let outerSourceID = UUID()
        let nestedSourceID = UUID()
        let source = RepositorySource.watchRoot(
            id: nestedSourceID,
            name: "Nested",
            path: nestedRoot.path
        )
        let repository = RepoDescriptor(
            id: UUID(),
            source: source,
            url: nestedRepositoryURL,
            canonicalURL: nestedRepositoryURL,
            resourceID: nil,
            relativePath: "Repository",
            availability: .available
        )
        let outerIndex = SourceRepositoryPathIndex(
            sourceURL: outerRoot,
            exclusions: ["excluded", "nested"],
            repositories: [RepositoryFileEventTarget(repository)]
        ) { _ in false }
        let nestedIndex = SourceRepositoryPathIndex(
            sourceURL: nestedRoot,
            repositories: [RepositoryFileEventTarget(repository)]
        ) { _ in false }
        let events = [
            FileSystemEvent(
                path: "/WORK/SOURCE/NESTED/REPOSITORY/changed.txt",
                requiresFullRescan: false,
                requiresSourceRescan: true
            ),
            FileSystemEvent(
                path: "/work/source/EXCLUDED/changed.txt",
                requiresFullRescan: false
            ),
            FileSystemEvent(
                path: "/work/source/nested-sibling/changed.txt",
                requiresFullRescan: false
            )
        ]
        let batch = FileEventBatch(
            paths: Set(events.map(\.path)),
            sourceRescanPaths: [events[0].path],
            requiresFullRescan: false
        )
        let router = SourceRepositoryFileEventGroupRouter(sourceIndexes: [
            outerSourceID: outerIndex,
            nestedSourceID: nestedIndex
        ])
        let partition = router.partition(events)

        func sortByPath(_ events: [SourceRepositoryFileEvent]) -> [SourceRepositoryFileEvent] {
            events.sorted { $0.eventPath.path < $1.eventPath.path }
        }
        XCTAssertEqual(
            sortByPath(partition.slicesBySourceID[outerSourceID]?.events ?? []),
            sortByPath(outerIndex.partition(batch))
        )
        XCTAssertEqual(
            sortByPath(partition.slicesBySourceID[nestedSourceID]?.events ?? []),
            sortByPath(nestedIndex.partition(batch))
        )
        XCTAssertTrue(partition.slicesBySourceID[nestedSourceID]?.events.contains { $0.repositories.map(\.id) == [repository.id] } == true)
        XCTAssertFalse(partition.slicesBySourceID[outerSourceID]?.events.contains { $0.eventPath.path == events[0].path } == true)
        XCTAssertTrue(partition.slicesBySourceID[outerSourceID]?.events.contains { $0.eventPath.path == events[2].path } == true)
        XCTAssertEqual(partition.normalizedPathCount, events.count)
    }

    @MainActor
    func testSourceEventGroupRouterKeepsHighVolumeUnrelatedPathsOutOfNestedSlice() {
        let outerRoot = URL(fileURLWithPath: "/work/Source", isDirectory: true)
        let nestedRoot = outerRoot.appendingPathComponent("Nested", isDirectory: true)
        let outerSourceID = UUID()
        let nestedSourceID = UUID()
        let outerIndex = SourceRepositoryPathIndex(sourceURL: outerRoot) { _ in true }
        let nestedIndex = SourceRepositoryPathIndex(sourceURL: nestedRoot) { _ in true }
        let nestedPath = nestedRoot.appendingPathComponent("repository/changed.txt").path
        let unrelatedEvents = (0..<(FileEventDebouncer.maximumPaths + 100)).map { index in
            FileSystemEvent(
                path: outerRoot.appendingPathComponent("unrelated-\(index)/changed.txt").path,
                requiresFullRescan: false
            )
        }
        let partition = SourceRepositoryFileEventGroupRouter(sourceIndexes: [
            outerSourceID: outerIndex,
            nestedSourceID: nestedIndex
        ]).partition(
            unrelatedEvents + [FileSystemEvent(path: nestedPath, requiresFullRescan: false)]
        )

        let outerSlice = partition.slicesBySourceID[outerSourceID]
        let nestedSlice = partition.slicesBySourceID[nestedSourceID]
        XCTAssertEqual(outerSlice?.rawBatch.paths.count, FileEventDebouncer.maximumPaths + 101)
        XCTAssertEqual(nestedSlice?.rawBatch.paths, Set([nestedPath]))
        XCTAssertEqual(nestedSlice?.events.map(\.eventPath.path), [nestedPath])
        XCTAssertFalse(nestedSlice?.rawBatch.requiresFullRescan == true)
        XCTAssertFalse(nestedSlice?.rawBatch.hasUnrepresentedChanges == true)
    }

    @MainActor
    func testStandaloneRepositoryRoutingUsesCachedCaseInsensitiveVolumeSemantics() async {
        let repositoryID = UUID()
        let repositoryURL = URL(fileURLWithPath: "/work/Repository", isDirectory: true)
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        var metadataReads = 0
        let controller = RepositoryFileEventCoverageController(
            caseSensitivityProvider: { _ in
                metadataReads += 1
                return false
            }
        )
        controller.update(context: RepositoryRuntimeContext(
            state: PersistedState(),
            repositories: [repository],
            isShuttingDown: false
        ))
        let configPath = "/WORK/REPOSITORY/.GIT/CONFIG"
        let batch = FileEventBatch(
            paths: [configPath],
            sourceRescanPaths: [],
            requiresFullRescan: false
        )
        let expected: Set<RepositoryFileEventCoverageEvent> = [
            .invalidateGitHubURL(repositoryID),
            .refreshStatus(repositoryID)
        ]
        let firstEvents = await controller.routeRepositoryFileEvents(batch, repositoryID: repositoryID)
        let secondEvents = await controller.routeRepositoryFileEvents(batch, repositoryID: repositoryID)
        XCTAssertEqual(Set(firstEvents), expected)
        XCTAssertEqual(Set(secondEvents), expected)
        XCTAssertEqual(metadataReads, 1)
        controller.finishShutdown()
    }
}
