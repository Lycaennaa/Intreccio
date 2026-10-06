import Foundation
import XCTest
@testable import Intreccio

extension StateStoreTests {
    func testDegenerateWindowFrameIsDroppedOnDecode() throws {
        XCTAssertNil(PersistedUIState.sanitizedWindowFrame("{{1080, 1530}, {0, 52}}"))
        let valid = "{{120, 140}, {900, 620}}"
        XCTAssertEqual(PersistedUIState.sanitizedWindowFrame(valid), valid)
        XCTAssertNil(PersistedUIState.sanitizedWindowFrame(nil))
    }

    func testRememberedApplicationStateNormalizesEntriesBeyondInvalidValues() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        var state = PersistedState()
        let invalidURLs = (0..<32).map { directory.appendingPathComponent("Folder\($0)") }
        let validURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: validURL)
        state.uiState.savedOpenApplicationURLs = invalidURLs + [validURL, validURL]
        try JSONEncoder().encode(state).write(to: fileURL)

        let loaded = await StateStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.state.uiState.savedOpenApplicationURLs, [validURL])
        XCTAssertNil(loaded.recoveryMessage)
    }

    func testExcludedApplicationStateKeepsMissingApplicationsAndAllEntries() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        var state = PersistedState()
        let excludedURLs = (0..<33).map { directory.appendingPathComponent("Hidden\($0).app") }
        state.uiState.excludedOpenApplicationURLs = excludedURLs
        try JSONEncoder().encode(state).write(to: fileURL)

        let loaded = await StateStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.state.uiState.excludedOpenApplicationURLs, excludedURLs)
        XCTAssertNil(loaded.recoveryMessage)
    }

    func testOpenApplicationDomainNormalizesSavedAndExcludedURLs() throws {
        let directory = try makeTestDirectory()
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)
        let aliasURL = directory.appendingPathComponent("Editor Alias.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: applicationURL)
        let invalidApplicationURL = directory.appendingPathComponent("Invalid.app", isDirectory: true)
        try makeApplicationBundle(at: invalidApplicationURL, executableIsDirectory: true)
        let missingURL = directory.appendingPathComponent("Missing.APP")

        XCTAssertEqual(
            PersistedOpenApplicationList.normalizedSavedApplicationURLs([
                aliasURL,
                applicationURL,
                invalidApplicationURL,
                URL(string: "https://example.com/Editor.app")!,
            ]),
            [applicationURL]
        )
        XCTAssertEqual(
            PersistedOpenApplicationList.normalizedExcludedApplicationURLs([
                missingURL,
                missingURL,
                directory.appendingPathComponent("NotAnApplication"),
                URL(string: "https://example.com/Missing.app")!,
            ]),
            [missingURL]
        )
        XCTAssertEqual(PersistedOpenApplicationList.stableIdentity(for: aliasURL), applicationURL.path)
    }

    func testSavedApplicationStateRejectsExecutableDirectoriesBeforeApplyingCap() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        var state = PersistedState()
        let invalidURLs = (0..<PersistedOpenApplicationList.maxSavedApplications).map {
            directory.appendingPathComponent("Invalid\($0).app", isDirectory: true)
        }
        for invalidURL in invalidURLs {
            try makeApplicationBundle(at: invalidURL, executableIsDirectory: true)
        }
        let validURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: validURL)
        state.uiState.savedOpenApplicationURLs = invalidURLs + [validURL]
        try JSONEncoder().encode(state).write(to: fileURL)

        let loaded = await StateStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.state.uiState.savedOpenApplicationURLs, [validURL])
        XCTAssertNil(loaded.recoveryMessage)
    }
}