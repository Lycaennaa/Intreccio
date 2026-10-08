import Foundation
@testable import Intreccio
import XCTest

final class RepositoryPathPolicyTests: XCTestCase {
    func testRelativePathNormalizationAndExclusionContainmentParity() throws {
        let root = try makeTestDirectory()
        let relativePath = "external/not active/Repo"

        XCTAssertEqual(
            RepositoryPathPolicy.relativePath(
                from: root,
                to: root.appendingPathComponent(relativePath, isDirectory: true)
            ),
            relativePath
        )
        XCTAssertEqual(
            RepositoryPathPolicy.normalizedRelativePath("external/./not active/../not active"),
            "external/not active"
        )
        XCTAssertTrue(
            RepositoryPathPolicy.isExcluded(
                relativePath: relativePath,
                by: ["external/./not active/../not active"],
                root: root
            )
        )
        XCTAssertFalse(
            RepositoryPathPolicy.isWithin(
                relativePath: "external/not active-sibling/Repo",
                folder: "external/not active"
            )
        )
        XCTAssertTrue(
            RepositoryPathPolicy.isWithin(
                relativePath: "External/Not Active/Repo",
                folder: "external/not active",
                caseSensitive: false
            )
        )
        XCTAssertFalse(
            RepositoryPathPolicy.isWithin(
                relativePath: "External/Not Active/Repo",
                folder: "external/not active",
                caseSensitive: true
            )
        )
    }

    func testResolvedContainmentPreservesSymlinkAwareAndEventRoutingModes() throws {
        let root = try makeTestDirectory()
        let realRepository = root.appendingPathComponent("Real", isDirectory: true)
        let symlinkedRepository = root.appendingPathComponent("Alias", isDirectory: true)
        let changedFile = realRepository.appendingPathComponent("changed.txt")
        try FileManager.default.createDirectory(at: realRepository, withIntermediateDirectories: true)
        try Data().write(to: changedFile)
        try FileManager.default.createSymbolicLink(
            at: symlinkedRepository,
            withDestinationURL: realRepository
        )

        XCTAssertTrue(RepositoryPathPolicy.contains(realRepository, changedFile))
        XCTAssertFalse(RepositoryPathPolicy.contains(symlinkedRepository, changedFile))
        XCTAssertTrue(RepositoryPathPolicy.containsResolvingSymlinks(symlinkedRepository, changedFile))
        XCTAssertEqual(
            RepositoryPathPolicy.canonicalURL(symlinkedRepository),
            RepositoryPathPolicy.canonicalURL(realRepository)
        )
    }
}
