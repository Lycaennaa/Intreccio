import Foundation
import XCTest
@testable import Intreccio

extension StateStoreTests {
    func testStateWithoutPinnedRepositoriesLoadsWithEmptyPinnedSection() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let data = Data("""
        {
          "repoSnapshots" : [],
          "schemaVersion" : 1,
          "standaloneRepos" : [],
          "uiState" : {
            "expandedSourceIDs" : [],
            "mode" : "changes",
            "searchText" : "",
            "sidebarWidth" : 240
          },
          "watchRoots" : []
        }
        """.utf8)
        try data.write(to: fileURL)

        let loaded = await StateStore(fileURL: fileURL).load()

        XCTAssertNil(loaded.recoveryMessage)
        XCTAssertTrue(loaded.state.uiState.pinnedRepositoryIDs.isEmpty)
        XCTAssertNil(loaded.state.uiState.changesListWidth)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(loaded.state.uiState.savedOpenApplicationURLs.isEmpty)
    }

    func testSettingsFieldsDecodeWithDefaultsAndClamps() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let data = Data("""
        {
          "repoSnapshots" : [],
          "schemaVersion" : 1,
          "standaloneRepos" : [],
          "uiState" : {
            "diffFontSize" : 999,
            "fileWatchDebounceMilliseconds" : -5,
            "showWhitespaceInDiff" : true,
            "defaultOpenApplicationURL" : "/missing/Missing.app"
          },
          "watchRoots" : []
        }
        """.utf8)
        try data.write(to: fileURL)

        let loaded = await StateStore(fileURL: fileURL).load()

        XCTAssertNil(loaded.recoveryMessage)
        XCTAssertEqual(loaded.state.uiState.diffFontSize, 24)
        XCTAssertEqual(loaded.state.uiState.fileWatchDebounceMilliseconds, 50)
        XCTAssertTrue(loaded.state.uiState.showWhitespaceInDiff)
        XCTAssertNil(loaded.state.uiState.defaultOpenApplicationURL)
    }

    func testCorruptStateIsQuarantinedAndEvidenceIsNotOverwritten() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        try Data("not json".utf8).write(to: fileURL)
        let store = StateStore(fileURL: fileURL)

        let loaded = await store.load()

        XCTAssertEqual(loaded.state, PersistedState())
        XCTAssertNotNil(loaded.recoveryMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("state.corrupt-") && $0.hasSuffix(".json") })
    }

    func testNewerSchemaIsLeftUntouchedAndBlocksDowngradeWrites() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        var newerState = PersistedState()
        newerState.schemaVersion = PersistedState.currentSchemaVersion + 1
        let data = try JSONEncoder().encode(newerState)
        try data.write(to: fileURL)
        let store = StateStore(fileURL: fileURL)

        let loaded = await store.load()

        XCTAssertNotNil(loaded.recoveryMessage)
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        do {
            try await store.save(PersistedState())
            XCTFail("Expected downgrade write protection")
        } catch StateStoreError.writeBlocked {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
    }

    func testNewerSchemaWithIncompatibleFieldsIsLeftUntouched() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let data = Data("""
        {
          "schemaVersion" : \(PersistedState.currentSchemaVersion + 1),
          "watchRoots" : { "futureFormat" : true }
        }
        """.utf8)
        try data.write(to: fileURL)
        let store = StateStore(fileURL: fileURL)

        let loaded = await store.load()

        XCTAssertNotNil(loaded.recoveryMessage)
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        do {
            try await store.save(PersistedState())
            XCTFail("Expected downgrade write protection")
        } catch StateStoreError.writeBlocked {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
    }

    func testMalformedSchemaIsQuarantinedWithRecoveryDiagnostics() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let data = Data("""
        {
          "schemaVersion" : "not-an-integer",
          "watchRoots" : [],
          "standaloneRepos" : [],
          "repoSnapshots" : []
        }
        """.utf8)
        try data.write(to: fileURL)

        let loaded = await StateStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.state, PersistedState())
        XCTAssertTrue(loaded.recoveryMessage?.contains("Saved state was corrupt") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testNewerCatalogSchemaWithIncompatibleFieldsIsLeftUntouched() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let data = Data("""
        {
          "documentType" : "catalog",
          "schemaVersion" : \(PersistedState.currentSchemaVersion + 1),
          "watchRoots" : { "futureFormat" : true }
        }
        """.utf8)
        try data.write(to: fileURL)

        let store = StateStore(fileURL: fileURL)
        let loaded = await store.load()

        XCTAssertNotNil(loaded.recoveryMessage)
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        do {
            try await store.save(PersistedState())
            XCTFail("Expected downgrade write protection")
        } catch StateStoreError.writeBlocked {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLegacyStateUIIsMigratedWithoutRewritingCatalog() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        var state = PersistedState()
        state.watchRoots = [WatchRoot(
            id: UUID(),
            displayName: "Projects",
            bookmarkData: Data([4, 5, 6]),
            lastResolvedPath: "/Projects",
            resourceID: nil,
            exclusions: []
        )]
        state.uiState.searchText = "legacy"
        let legacyData = try JSONEncoder().encode(state)
        try legacyData.write(to: fileURL)
        let store = StateStore(fileURL: fileURL)

        let initial = await store.load()
        XCTAssertEqual(initial.state, state)
        state.uiState.searchText = "migrated"
        try await store.saveUI(state.uiState)

        XCTAssertEqual(try Data(contentsOf: fileURL), legacyData)
        let loaded = await store.load()
        XCTAssertEqual(loaded.state.watchRoots, state.watchRoots)
        XCTAssertEqual(loaded.state.uiState.searchText, "migrated")
    }
}