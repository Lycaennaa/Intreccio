import Foundation
@testable import Intreccio
import XCTest

extension StateStoreTests {
    func testFailedAtomicWritePreservesPriorValidState() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: fileURL)
        var original = PersistedState()
        original.uiState.searchText = "original"
        try await store.save(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        var replacement = original
        replacement.uiState.searchText = "replacement"

        do {
            try await store.save(replacement)
            XCTFail("Expected a write failure")
        } catch {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let loaded = await store.load()
            XCTAssertEqual(loaded.state, original)
        }
    }

    func testQuarantineFailureBlocksLaterWritesAndPreservesEvidence() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        try Data("corrupt".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let store = StateStore(fileURL: fileURL)

        let loaded = await store.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        XCTAssertNotNil(loaded.recoveryMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        do {
            try await store.save(PersistedState())
            XCTFail("Expected writes to remain blocked")
        } catch StateStoreError.writeBlocked {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("corrupt".utf8))
    }

    func testFailedCatalogWriteRollsBackUIFile() async throws {
        let directory = try makeTestDirectory()
        let catalogDirectory = directory.appendingPathComponent("catalog", isDirectory: true)
        let uiDirectory = directory.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: uiDirectory, withIntermediateDirectories: true)
        let fileURL = catalogDirectory.appendingPathComponent("state.json")
        let uiFileURL = uiDirectory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: fileURL, uiFileURL: uiFileURL)
        var original = PersistedState()
        original.uiState.searchText = "original"
        try await store.save(original)
        let originalCatalog = try Data(contentsOf: fileURL)
        let originalUI = try Data(contentsOf: uiFileURL)
        var replacement = original
        replacement.uiState.searchText = "replacement"
        let validatedCatalogData = try await store.validateCatalog(replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: catalogDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: catalogDirectory.path) }

        do {
            try await store.save(replacement, validatedCatalogData: validatedCatalogData)
            XCTFail("Expected a catalog write failure")
        } catch {
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), originalCatalog)
        XCTAssertEqual(try Data(contentsOf: uiFileURL), originalUI)
    }
}
