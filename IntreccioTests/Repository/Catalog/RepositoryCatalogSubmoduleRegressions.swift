import Foundation
@testable import Intreccio
import XCTest

extension RepositoryCatalogRefactorTests {
    func testIncompleteWatchRootScanPreservesMissingSubmoduleSnapshot() {
        let sourceID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let source = WatchRoot(
            id: sourceID,
            displayName: "Workspace",
            bookmarkData: Data(),
            lastResolvedPath: "/workspace",
            resourceID: nil,
            exclusions: []
        )
        let snapshot = makeSubmoduleSnapshot(
            id: childID,
            sourceID: sourceID,
            parentID: parentID,
            path: "/workspace/vendor/child"
        )
        let scan = RepoScanResult(
            repositories: [],
            warnings: [],
            incompleteReason: "Scan stopped at repository limit.",
            visitedDirectoryCount: 50,
            duration: .zero
        )

        let result = RepositoryCatalogRebuilder.rebuild(
            state: PersistedState(watchRoots: [source], repoSnapshots: [snapshot]),
            sourceScans: [sourceID: scan],
            standaloneRepositories: [:]
        )

        XCTAssertEqual(result.repositories.first?.availability, .available)
    }
    func testWarningOnlyWatchRootScanPreservesMissingSubmoduleSnapshot() {
        let sourceID = UUID()
        let source = WatchRoot(
            id: sourceID,
            displayName: "Workspace",
            bookmarkData: Data(),
            lastResolvedPath: "/workspace",
            resourceID: nil,
            exclusions: []
        )
        let snapshot = makeSubmoduleSnapshot(
            id: UUID(),
            sourceID: sourceID,
            parentID: UUID(),
            path: "/workspace/vendor/child"
        )
        let scan = RepoScanResult(
            repositories: [],
            warnings: ["Could not inspect submodules in /workspace."],
            incompleteReason: nil,
            visitedDirectoryCount: 1,
            duration: .zero
        )

        let result = RepositoryCatalogRebuilder.rebuild(
            state: PersistedState(watchRoots: [source], repoSnapshots: [snapshot]),
            sourceScans: [sourceID: scan],
            standaloneRepositories: [:]
        )

        XCTAssertEqual(result.repositories.first?.availability, .available)
    }

    func testIncompleteStandaloneScanPreservesMissingSubmoduleSnapshot() {
        let sourceID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let source = StandaloneRepository(
            id: sourceID,
            displayName: "Parent",
            bookmarkData: Data(),
            lastResolvedPath: "/parent",
            resourceID: nil
        )
        let snapshot = makeSubmoduleSnapshot(
            id: childID,
            sourceID: sourceID,
            parentID: parentID,
            path: "/parent/vendor/child"
        )

        let result = RepositoryCatalogRebuilder.rebuild(
            state: PersistedState(standaloneRepos: [source], repoSnapshots: [snapshot]),
            sourceScans: [:],
            standaloneRepositories: [sourceID: StandaloneRepositoryLocation(
                url: URL(fileURLWithPath: "/parent", isDirectory: true),
                gitDirectoryInfo: nil,
                submoduleScanIncomplete: true
            )]
        )

        XCTAssertEqual(result.repositories.first?.availability, .available)
    }

    func testCompleteScanStillMarksMissingSubmoduleUnavailable() {
        let sourceID = UUID()
        let childID = UUID()
        let source = WatchRoot(
            id: sourceID,
            displayName: "Workspace",
            bookmarkData: Data(),
            lastResolvedPath: "/workspace",
            resourceID: nil,
            exclusions: []
        )
        let snapshot = makeSubmoduleSnapshot(
            id: childID,
            sourceID: sourceID,
            parentID: UUID(),
            path: "/workspace/vendor/child"
        )
        let scan = RepoScanResult(
            repositories: [],
            warnings: [],
            incompleteReason: nil,
            visitedDirectoryCount: 1,
            duration: .zero
        )

        let result = RepositoryCatalogRebuilder.rebuild(
            state: PersistedState(watchRoots: [source], repoSnapshots: [snapshot]),
            sourceScans: [sourceID: scan],
            standaloneRepositories: [:]
        )

        XCTAssertEqual(
            result.repositories.first?.availability,
            .unavailable(reason: "Initialized submodule was not found in the current scan.")
        )
    }
    func testIncompleteFirstRestoreInfersParentSubmodulesFromChildSnapshots() {
        let sourceID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let source = WatchRoot(
            id: sourceID,
            displayName: "Workspace",
            bookmarkData: Data(),
            lastResolvedPath: "/workspace",
            resourceID: nil,
            exclusions: []
        )
        let parentSnapshot = RepositorySnapshot(
            id: parentID,
            sourceID: sourceID,
            relativePath: "parent",
            canonicalPath: "/workspace/parent",
            resourceID: nil,
            availability: .available
        )
        let childSnapshot = makeSubmoduleSnapshot(
            id: childID,
            sourceID: sourceID,
            parentID: parentID,
            path: "/workspace/parent/vendor/child"
        )
        let incompleteScan = RepoScanResult(
            repositories: [],
            warnings: [],
            incompleteReason: "Scan stopped after visiting the directory limit.",
            visitedDirectoryCount: 1,
            duration: .zero
        )

        let result = RepositoryCatalogRebuilder.rebuild(
            state: PersistedState(watchRoots: [source], repoSnapshots: [parentSnapshot, childSnapshot]),
            sourceScans: [sourceID: incompleteScan],
            standaloneRepositories: [:]
        )

        let parent = result.repositories.first { $0.id == parentID }
        XCTAssertEqual(parent?.availability, .available)
        XCTAssertTrue(parent?.hasSubmodules == true)
        XCTAssertEqual(result.repositories.first { $0.id == childID }?.availability, .available)
    }
}

extension RepositoryCatalogScanConcurrencyTests {
    func testStandaloneRestoreAndAdditionEnforceCandidateBudget() async throws {
        let workspace = try makeTestDirectory()
        let childSource = workspace.appendingPathComponent("child-source", isDirectory: true)
        let parent = workspace.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: childSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try runGit(at: childSource, arguments: ["init", "-b", "main"])
        try runGit(at: childSource, arguments: ["config", "user.name", "Fixture"])
        try runGit(at: childSource, arguments: ["config", "user.email", "fixture@example.test"])
        try Data("child\n".utf8).write(to: childSource.appendingPathComponent("README.md"))
        try runGit(at: childSource, arguments: ["add", "README.md"])
        try runGit(at: childSource, arguments: ["commit", "-m", "Initial commit"])
        try runGit(at: parent, arguments: ["init", "-b", "main"])
        try runGit(at: parent, arguments: [
            "-c", "protocol.file.allow=always", "submodule", "add", "--",
            childSource.path, "vendor/child"
        ])

        let bookmarkStore = BookmarkStore()
        let bookmark: Data
        do {
            bookmark = try await bookmarkStore.create(for: parent)
        } catch {
            throw XCTSkip("Security-scoped bookmarks unavailable in this test host: \(error)")
        }
        let source = StandaloneRepository(
            id: UUID(),
            displayName: "Parent",
            bookmarkData: bookmark,
            lastResolvedPath: parent.path,
            resourceID: nil
        )
        let unrelatedRoots = makeWatchRoots(count: PersistedCatalogBudget.maxEntryCount - 2)
        let state = PersistedState(watchRoots: unrelatedRoots, standaloneRepos: [source])
        let (operations, _) = makeOperations(
            watchRootScan: { source in .scanFailure(source: source, message: "unused") },
            bookmarkStore: bookmarkStore
        )

        do {
            _ = try await operations.prepareRestoreSources(
                state: state,
                generation: nil,
                refreshUpstream: false
            )
            XCTFail("Standalone restore exceeded the candidate budget without failing")
        } catch let error as RepositoryCatalogScanError {
            XCTAssertEqual(error, .candidateBudgetExceeded(limit: 1))
        } catch {
            XCTFail("Unexpected standalone budget error: \(error)")
        }
        do {
            _ = try await operations.prepareAddStandaloneRepository(
                parent,
                state: PersistedState(watchRoots: unrelatedRoots)
            )
            XCTFail("Standalone addition exceeded the candidate budget without failing")
        } catch let error as RepositoryCatalogScanError {
            XCTAssertEqual(error, .candidateBudgetExceeded(limit: 1))
        } catch {
            XCTFail("Unexpected standalone addition budget error: \(error)")
        }
    }
    func testStandaloneRestorePreservesChildWhenEnumerationWarns() async throws {
        let workspace = try makeTestDirectory()
        let parent = workspace.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try runGit(at: parent, arguments: ["init", "-b", "main"])
        let gitModules = """
        [submodule "child"]
            path = ../outside
            url = https://example.invalid/child.git
        """
        try Data(gitModules.utf8).write(to: parent.appendingPathComponent(".gitmodules"))

        let bookmarkStore = BookmarkStore()
        let bookmark: Data
        do {
            bookmark = try await bookmarkStore.create(for: parent)
        } catch {
            throw XCTSkip("Security-scoped bookmarks unavailable in this test host: \(error)")
        }
        let source = StandaloneRepository(
            id: UUID(),
            displayName: "Parent",
            bookmarkData: bookmark,
            lastResolvedPath: parent.path,
            resourceID: nil
        )
        let parentID = UUID()
        let childID = UUID()
        let snapshots = [
            RepositorySnapshot(
                id: parentID,
                sourceID: source.id,
                relativePath: nil,
                canonicalPath: parent.path,
                resourceID: nil,
                availability: .available
            ),
            makeSubmoduleSnapshot(
                id: childID,
                sourceID: source.id,
                parentID: parentID,
                path: parent.appendingPathComponent("vendor/child").path
            )
        ]
        let (operations, _) = makeOperations(
            watchRootScan: { source in .scanFailure(source: source, message: "unused") },
            bookmarkStore: bookmarkStore
        )

        let transaction = try await operations.prepareRestoreSources(
            state: PersistedState(standaloneRepos: [source], repoSnapshots: snapshots),
            generation: nil,
            refreshUpstream: false
        )

        XCTAssertTrue(try XCTUnwrap(transaction.change.standaloneRepositories[source.id]).submoduleScanIncomplete)
        XCTAssertTrue(
            transaction.change.repositories.first(where: { $0.id == parentID })?.hasSubmodules == true
        )
        XCTAssertEqual(
            transaction.change.repositories.first(where: { $0.id == childID })?.availability,
            .available
        )
    }
}
extension RepoScannerIntegrationTests {
    func testSubmoduleInspectionFailureMarksScanIncomplete() async throws {
        let workspace = try makeTestDirectory()
        let parent = workspace.appendingPathComponent("parent", isDirectory: true)
        let vendor = parent.appendingPathComponent("vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try runGit(at: parent, arguments: ["init", "-b", "main"])
        let gitModules = """
        [submodule "child"]
            path = vendor/child
            url = https://example.invalid/child.git
        """
        try Data(gitModules.utf8).write(to: parent.appendingPathComponent(".gitmodules"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: vendor.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vendor.path) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: vendor.path)) == nil else {
            throw XCTSkip("Filesystem permissions are not enforced for this test host.")
        }

        let result = try await RepoScanner().scan(root: parent, exclusions: [])

        XCTAssertTrue(result.isIncomplete)
        XCTAssertTrue(result.warnings.contains { $0.contains("Could not inspect configured submodule path") })
    }
    func testNonRegularGitModulesPathMarksScanIncomplete() async throws {
        let workspace = try makeTestDirectory()
        let parent = workspace.appendingPathComponent("parent", isDirectory: true)
        let gitModules = parent.appendingPathComponent(".gitmodules")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try runGit(at: parent, arguments: ["init", "-b", "main"])
        try FileManager.default.createDirectory(at: gitModules, withIntermediateDirectories: true)

        let directoryResult = try await RepoScanner().scan(root: parent, exclusions: [])
        XCTAssertTrue(directoryResult.isIncomplete)
        XCTAssertTrue(directoryResult.warnings.contains { $0.contains(".gitmodules is not a regular file") })

        try FileManager.default.removeItem(at: gitModules)
        let target = workspace.appendingPathComponent("modules-data")
        try Data("[submodule \"child\"]\npath = child\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: gitModules, withDestinationURL: target)

        let symlinkResult = try await RepoScanner().scan(root: parent, exclusions: [])
        XCTAssertTrue(symlinkResult.isIncomplete)
        XCTAssertTrue(symlinkResult.warnings.contains { $0.contains(".gitmodules is not a regular file") })
    }
}


private func makeSubmoduleSnapshot(
    id: UUID,
    sourceID: UUID,
    parentID: UUID,
    path: String
) -> RepositorySnapshot {
    RepositorySnapshot(
        id: id,
        sourceID: sourceID,
        relativePath: path,
        canonicalPath: path,
        resourceID: nil,
        availability: .available,
        submoduleParentRepositoryID: parentID,
        submodulePath: "vendor/child"
    )
}
