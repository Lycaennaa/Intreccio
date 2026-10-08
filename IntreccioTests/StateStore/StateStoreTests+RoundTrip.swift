import Foundation
@testable import Intreccio
import XCTest

extension StateStoreTests {
    func testRoundTripPersistsVersionedSourcesSnapshotsAndUIState() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: fileURL)
        let sourceID = UUID()
        let repositoryID = UUID()
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)
        let state = PersistedState(
            watchRoots: [WatchRoot(
                id: sourceID,
                displayName: "Projects",
                bookmarkData: Data([1, 2, 3]),
                lastResolvedPath: "/Projects",
                resourceID: "root-id",
                exclusions: ["Archived/Repo"]
            )],
            standaloneRepos: [],
            repoSnapshots: [RepositorySnapshot(
                id: repositoryID,
                sourceID: sourceID,
                relativePath: "Repo",
                canonicalPath: "/Projects/Repo",
                resourceID: "repo-id",
                availability: .available
            )],
            uiState: PersistedUIState(
                selectedRepoID: repositoryID,
                searchText: "repo",
                changesListWidth: 512,
                 savedOpenApplicationURLs: [applicationURL],
                 excludedOpenApplicationURLs: [applicationURL],
                 quickOpenFileAssignments: [PersistedQuickOpenFileAssignment(
                     repositoryID: repositoryID,
                     paths: ["todo.txt", "docs/notes.txt"]
                 )]
            )
        )

        try await store.save(state)
        let loaded = await store.load()

        XCTAssertEqual(loaded.state, state)
        XCTAssertNil(loaded.recoveryMessage)
    }

    func testUISaveLeavesCatalogDocumentUntouched() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: fileURL)
        var state = PersistedState()
        state.watchRoots = [WatchRoot(
            id: UUID(),
            displayName: "Projects",
            bookmarkData: Data([1, 2, 3]),
            lastResolvedPath: "/Projects",
            resourceID: nil,
            exclusions: []
        )]
        state.uiState.searchText = "before"

        try await store.save(state)
        let catalogData = try Data(contentsOf: fileURL)
        state.uiState.searchText = "after"
        try await store.saveUI(state.uiState)

        XCTAssertEqual(try Data(contentsOf: fileURL), catalogData)
        let loaded = await store.load()
        XCTAssertEqual(loaded.state.watchRoots, state.watchRoots)
        XCTAssertEqual(loaded.state.uiState, state.uiState)
    }
}

#if DEBUG
extension StateStoreTests {
    func testValidatedCatalogDataIsReusedOnlyForMatchingCatalog() async throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let store = StateStore(fileURL: fileURL)
        var state = PersistedState()
        state.watchRoots = [WatchRoot(
            id: UUID(),
            displayName: "Original",
            bookmarkData: Data(),
            lastResolvedPath: "/original",
            resourceID: nil,
            exclusions: []
        )]

        let validatedCatalogData = try await store.validateCatalog(state)
        let countAfterValidation = await store.catalogEncodingCountForTesting
        XCTAssertEqual(countAfterValidation, 1)

        var changedUIState = state
        changedUIState.uiState.searchText = "changed UI"
        try await store.save(changedUIState, validatedCatalogData: validatedCatalogData)
        let countAfterReuse = await store.catalogEncodingCountForTesting
        XCTAssertEqual(countAfterReuse, countAfterValidation)

        var changedState = state
        changedState.watchRoots[0].displayName = "Changed"
        try await store.save(changedState, validatedCatalogData: validatedCatalogData)
        let countAfterChangedCatalog = await store.catalogEncodingCountForTesting
        XCTAssertEqual(countAfterChangedCatalog, countAfterReuse + 1)

        let loaded = await store.load()
        XCTAssertEqual(loaded.state, changedState)
    }
}
#endif
