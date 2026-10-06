import Foundation
import XCTest
@testable import Intreccio

extension RefreshEngineTests {
    func testCoverageMergesDescendantsWithoutPrefixCollisions() {
        let root = URL(fileURLWithPath: "/work/Repo")
        let nested = URL(fileURLWithPath: "/work/Repo/Nested")
        let siblingPrefix = URL(fileURLWithPath: "/work/Repository")

        let coverage = FileSystemEventMonitor.normalizedCoverage([nested, siblingPrefix, root])

        XCTAssertEqual(coverage.map(\.path), ["/work/Repo", "/work/Repository"])
    }

    func testCoveragePlanningHandlesHighSourceCountWithoutPairwiseWork() {
        let sourceCount = 1_024
        let sources = (0..<sourceCount).flatMap { index -> [WatchRoot] in
            let outerPath = "/work/source-\(index)"
            return [
                WatchRoot(
                    id: UUID(),
                    displayName: "Outer \(index)",
                    bookmarkData: Data(),
                    lastResolvedPath: outerPath,
                    resourceID: nil,
                    exclusions: []
                ),
                WatchRoot(
                    id: UUID(),
                    displayName: "Nested \(index)",
                    bookmarkData: Data(),
                    lastResolvedPath: outerPath + "/nested",
                    resourceID: nil,
                    exclusions: []
                ),
            ]
        }
        let indexes = RepositoryFileEventCoveragePlanner.makeSourceIndexes(
            sources,
            repositories: [],
            caseSensitivityProvider: { _ in true }
        )
        let plans = RepositoryFileEventCoveragePlanner.makeSourceEventGroupPlans(
            sources,
            indexes: indexes
        )

        XCTAssertEqual(plans.count, sourceCount)
        XCTAssertTrue(plans.allSatisfy { $0.sources.count == 2 })
        XCTAssertEqual(
            plans.flatMap { $0.sources.map(\.id) },
            sources.map(\.id)
        )
        let coverage = FileSystemEventMonitor.normalizedCoverage(
            (0..<sourceCount).map {
                URL(fileURLWithPath: "/work/coverage-\($0)", isDirectory: true)
            }
        )
        XCTAssertEqual(coverage.count, sourceCount)
    }

    func testSourcePathIndexCachesVolumeMetadataAndNormalizesExclusions() {
        let sourceURL = URL(fileURLWithPath: "/work/Source", isDirectory: true)
        var metadataReads = 0
        let index = SourceRepositoryPathIndex(
            sourceURL: sourceURL,
            exclusions: ["Excluded/./Folder"]
        ) { _ in
            metadataReads += 1
            return false
        }

        XCTAssertEqual(metadataReads, 1)
        XCTAssertFalse(index.caseSensitiveVolume)
        XCTAssertEqual(
            index.partitionedEventCount(FileEventBatch(
                paths: ["/WORK/SOURCE/EXCLUDED/folder/file"],
                sourceRescanPaths: [],
                requiresFullRescan: false
            )),
            0
        )
        XCTAssertEqual(
            index.partitionedEventCount(FileEventBatch(
                paths: ["/work/source/other/file"],
                sourceRescanPaths: [],
                requiresFullRescan: false
            )),
            1
        )
        XCTAssertEqual(metadataReads, 1)
    }

    func testSourcePathIndexPreservesCaseSensitiveExclusionBoundaries() {
        let index = SourceRepositoryPathIndex(
            sourceURL: URL(fileURLWithPath: "/work/Source", isDirectory: true),
            exclusions: ["Excluded"]
        ) { _ in true }

        let batch = FileEventBatch(
            paths: [
                "/work/Source/Excluded/file",
                "/work/Source/excluded/file",
                "/work/Source/Excluded-sibling/file",
                "/work/source/Excluded/file",
            ],
            sourceRescanPaths: [],
            requiresFullRescan: false
        )

        XCTAssertEqual(index.partitionedEventCount(batch), 2)
    }
}

