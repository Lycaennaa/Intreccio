import Foundation
@testable import Intreccio
import XCTest

extension StateStoreTests {
    func testOverBudgetCatalogEntryCountLoadLeavesFileUntouchedAndBlocksWrites() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        var state = PersistedState()
        state.watchRoots = (0...PersistedCatalogBudget.maxEntryCount).map { index in
            WatchRoot(
                id: UUID(),
                displayName: "Root \(index)",
                bookmarkData: Data(),
                lastResolvedPath: "/root-\(index)",
                resourceID: nil,
                exclusions: []
            )
        }
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL)

        let store = StateStore(fileURL: fileURL)
        let loaded = await store.load()

        XCTAssertEqual(loaded.state, PersistedState())
        XCTAssertTrue(loaded.recoveryMessage?.contains("budget") == true)
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        do {
            try await store.save(PersistedState())
            XCTFail("Expected over-budget catalog writes to remain blocked")
        } catch StateStoreError.writeBlocked {
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
    }

    func testOverBudgetCatalogBytesLoadLeavesFileUntouchedAndBlocksWrites() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let data = Data(repeating: 0, count: PersistedCatalogBudget.maxEncodedBytes + 1)
        try data.write(to: fileURL)

        let store = StateStore(fileURL: fileURL)
        let loaded = await store.load()

        XCTAssertEqual(loaded.state, PersistedState())
        XCTAssertTrue(loaded.recoveryMessage?.contains("budget") == true)
        XCTAssertTrue(loaded.recoveryMessage?.contains("\(PersistedCatalogBudget.maxEncodedBytes)") == true)
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        do {
            try await store.save(PersistedState())
            XCTFail("Expected over-budget catalog writes to remain blocked")
        } catch StateStoreError.writeBlocked {
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
    }

    func testApplicationStateStopsDecodingAfterTheRetainedEntryCap() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let excludedURLs = (0..<PersistedOpenApplicationList.maxExcludedApplications).map {
            directory.appendingPathComponent("Hidden\($0).app")
        }
        let state = PersistedState()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(state)) as? [String: Any]
        )
        var uiState = try XCTUnwrap(object["uiState"] as? [String: Any])
        var encodedURLs: [Any] = excludedURLs.map(\.absoluteString)
        encodedURLs.append(42)
        uiState["excludedOpenApplicationURLs"] = encodedURLs
        object["uiState"] = uiState
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: fileURL)

        let loaded = await StateStore(fileURL: fileURL).load()

        XCTAssertNil(loaded.recoveryMessage)
        XCTAssertEqual(loaded.state.uiState.excludedOpenApplicationURLs, excludedURLs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }
    func testQuickOpenNormalizationValidatesBeforeDeduplicatingRepositoryIDs() {
        let repositoryID = UUID()
        let state = PersistedUIState(
            quickOpenFileAssignments: [
                PersistedQuickOpenFileAssignment(repositoryID: repositoryID, paths: ["../invalid"]),
                PersistedQuickOpenFileAssignment(repositoryID: repositoryID, paths: ["todo.txt"])
            ]
        )

        XCTAssertEqual(
            state.quickOpenFileAssignments,
            [PersistedQuickOpenFileAssignment(repositoryID: repositoryID, paths: ["todo.txt"])]
        )
    }

    func testQuickOpenNormalizationEnforcesTotalPathByteBudget() {
        let path = String(repeating: "a", count: PersistedUIState.maxQuickOpenFilePathBytes - 1)
        let assignments = (0..<PersistedUIState.maxQuickOpenFileAssignments).map { _ in
            PersistedQuickOpenFileAssignment(repositoryID: UUID(), paths: [path])
        }

        let normalized = PersistedUIState.normalizedQuickOpenFileAssignments(assignments)
        let byteCount = normalized
            .flatMap(\.paths)
            .reduce(0) { $0 + $1.utf8.count }

        XCTAssertLessThan(normalized.count, PersistedUIState.maxQuickOpenFileAssignments)
        XCTAssertLessThanOrEqual(byteCount, PersistedUIState.maxQuickOpenFileBytes)
    }

    func testQuickOpenDecoderBoundsAssignmentCount() throws {
        let assignments = (0...PersistedUIState.maxQuickOpenFileAssignments).map { index in
            [
                "repositoryID": UUID().uuidString,
                "paths": ["file-\(index).txt"]
            ] as [String: Any]
        }
        let object: [String: Any] = [
            "documentType": PersistedUIStateDocument.documentType,
            "schemaVersion": PersistedUIStateDocument.currentSchemaVersion,
            "uiState": ["quickOpenFileAssignments": assignments]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let document = try JSONDecoder().decode(PersistedUIStateDocument.self, from: data)

        XCTAssertEqual(
            document.uiState.quickOpenFileAssignments.count,
            PersistedUIState.maxQuickOpenFileAssignments
        )
    }

    func testOverBudgetUIBytesLoadLeavesFileUntouchedAndBlocksWrites() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let uiFileURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("ui")
            .appendingPathExtension("json")
        let data = Data(repeating: 0, count: PersistedUIStateBudget.maxEncodedBytes + 1)
        try data.write(to: uiFileURL)

        let store = StateStore(fileURL: fileURL)
        let loaded = await store.load()

        XCTAssertEqual(loaded.state, PersistedState())
        XCTAssertTrue(loaded.recoveryMessage?.contains("UI state persistence budget") == true)
        XCTAssertEqual(try Data(contentsOf: uiFileURL), data)
        do {
            try await store.saveUI(PersistedUIState())
            XCTFail("Expected over-budget UI writes to remain blocked")
        } catch StateStoreError.writeBlocked {
        }
        XCTAssertEqual(try Data(contentsOf: uiFileURL), data)
    }
}
