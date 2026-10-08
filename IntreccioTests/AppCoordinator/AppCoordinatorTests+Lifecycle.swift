import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testTaskCompletionDrainWaitsForCancellationCleanup() async {
        let probe = TaskCleanupProbe()
        let task = Task {
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                let cleanup = Task.detached {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                await cleanup.value
                await probe.markFinished()
            }
        }
        while !(await probe.started) { await Task.yield() }
        task.cancel()

        await TaskCompletionDrain.waitForCompletion([task])

        let finished = await probe.finished
        XCTAssertTrue(finished)
    }

    func testShutdownClosesTaskSpawningUIStateSetters() async throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        coordinator.setSearchText("before")
        coordinator.setWindowState(frame: "before", sidebarWidth: 240, changesListWidth: 480)
        let saved = await coordinator.shutdown()
        let stateAfterShutdown = coordinator.state

        coordinator.start()
        coordinator.setMode(.history)
        coordinator.selectRepository(UUID())
        coordinator.setSearchText("after")
        coordinator.setWindowState(frame: "after", sidebarWidth: 480, changesListWidth: 640)
        await coordinator.addWatchRoot(directory)
        await coordinator.addStandaloneRepository(directory)

        XCTAssertTrue(saved)
        // First-launch seeding may or may not have landed depending on whether
        // startup finished before these assertions; normalize it away. What
        // matters here is that the post-shutdown setters left no trace.
        var actualFinal = coordinator.state
        actualFinal.uiState.savedOpenApplicationURLs = []
        actualFinal.uiState.seededDefaultFolderApplications = false
        var expectedFinal = stateAfterShutdown
        expectedFinal.uiState.savedOpenApplicationURLs = []
        expectedFinal.uiState.seededDefaultFolderApplications = false
        XCTAssertEqual(actualFinal, expectedFinal)
        XCTAssertEqual(coordinator.selectedDiffState, .idle)
        XCTAssertEqual(coordinator.selectedHistoryState, SelectedHistoryState())
        XCTAssertEqual(coordinator.selectedCommitState, .idle)
    }

    func testShutdownBeforeStartupCompletesPreservesSavedState() async throws {
        let directory = try makeTestDirectory()
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)
        let stateFile = directory.appendingPathComponent("state.json")
        var expectedState = PersistedState()
        expectedState.uiState.searchText = "saved"
        expectedState.uiState.excludedOpenApplicationURLs = [applicationURL]
        try await StateStore(fileURL: stateFile).save(expectedState)

        let coordinator = makeCoordinator(stateFile: stateFile)
        coordinator.start()
        // Seeding runs inside startup; wait for it so shutdown cannot cancel it.
        try await waitUntil(description: "coordinator startup") { coordinator.hasLoadedState }
        let saved = await coordinator.shutdown()
        XCTAssertTrue(saved)

        let loadedState = await StateStore(fileURL: stateFile).load()
        var expectedAfterSeed = expectedState
        expectedAfterSeed.uiState.savedOpenApplicationURLs = PersistedOpenApplicationList.normalizedSavedApplicationURLs([
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")
        ])
        expectedAfterSeed.uiState.seededDefaultFolderApplications = true
        XCTAssertEqual(loadedState.state, expectedAfterSeed)
    }
    func testShutdownBeforeStateAcceptancePreservesSavedState() async throws {
        let directory = try makeTestDirectory()
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)
        let stateFile = directory.appendingPathComponent("state.json")
        var expectedState = PersistedState()
        expectedState.uiState.searchText = "saved-before-acceptance"
        expectedState.uiState.excludedOpenApplicationURLs = [applicationURL]
        try await StateStore(fileURL: stateFile).save(expectedState)

        let coordinator = makeCoordinator(stateFile: stateFile)
        coordinator.start()
        XCTAssertFalse(coordinator.catalog.hasAcceptedLoadedState)

        let saved = await coordinator.shutdown()
        XCTAssertTrue(saved)

        let loadedState = await StateStore(fileURL: stateFile).load()
        XCTAssertEqual(loadedState.state.uiState.searchText, expectedState.uiState.searchText)
        XCTAssertEqual(
            loadedState.state.uiState.excludedOpenApplicationURLs,
            expectedState.uiState.excludedOpenApplicationURLs
        )
    }

    func testSeedDefaultFolderApplicationsRunsOnceEver() async throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))

        coordinator.seedDefaultFolderApplicationsIfNeeded()
        let names = Set(coordinator.state.uiState.savedOpenApplicationURLs.map {
            LaunchServicesApplicationService.shared.applicationName(for: $0)
        })
        XCTAssertTrue(names.contains("Finder"))
        XCTAssertTrue(names.contains("Terminal"))
        XCTAssertTrue(coordinator.state.uiState.seededDefaultFolderApplications)

        let flushed = await coordinator.flushState()
        XCTAssertTrue(flushed)
        let persisted = await StateStore(fileURL: directory.appendingPathComponent("state.json")).load()
        XCTAssertTrue(persisted.state.uiState.seededDefaultFolderApplications)
        let persistedNames = Set(persisted.state.uiState.savedOpenApplicationURLs.map {
            LaunchServicesApplicationService.shared.applicationName(for: $0)
        })
        XCTAssertTrue(persistedNames.contains("Finder"))
        XCTAssertTrue(persistedNames.contains("Terminal"))

        // Flag set: removals stay removed; nothing is ever re-added.
        coordinator.state.uiState.savedOpenApplicationURLs = []
        coordinator.seedDefaultFolderApplicationsIfNeeded()
        XCTAssertTrue(coordinator.state.uiState.savedOpenApplicationURLs.isEmpty)
    }

    func testSeedSkipsAlreadyHiddenSystemApplications() throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        coordinator.state.uiState.excludedOpenApplicationURLs = [terminalURL]

        coordinator.seedDefaultFolderApplicationsIfNeeded()

        let names = Set(coordinator.state.uiState.savedOpenApplicationURLs.map {
            LaunchServicesApplicationService.shared.applicationName(for: $0)
        })
        XCTAssertTrue(names.contains("Finder"))
        XCTAssertFalse(names.contains("Terminal"))
        XCTAssertTrue(coordinator.state.uiState.seededDefaultFolderApplications)
        XCTAssertTrue(coordinator.state.uiState.excludedOpenApplicationURLs.contains(terminalURL))
    }

    func testRestoreExcludedSeedReaddsItToSavedList() throws {
        let directory = try makeTestDirectory()
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        coordinator.state.uiState.seededDefaultFolderApplications = true
        coordinator.state.uiState.excludedOpenApplicationURLs = [terminalURL]

        coordinator.restoreExcludedOpenApplications([terminalURL])

        XCTAssertTrue(coordinator.state.uiState.excludedOpenApplicationURLs.isEmpty)
        let names = Set(coordinator.state.uiState.savedOpenApplicationURLs.map {
            LaunchServicesApplicationService.shared.applicationName(for: $0)
        })
        XCTAssertTrue(names.contains("Terminal"))
    }

    func testSuccessfulUIStateRetryClearsPriorSaveError() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        coordinator.setSearchText("blocked")
        try await waitUntil(description: "UI state save failure") { coordinator.errorMessage != nil }

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        coordinator.setSearchText("saved")
        try await waitUntil(description: "successful UI state retry") { coordinator.errorMessage == nil }

        let persisted = await StateStore(fileURL: stateFile).load()
        XCTAssertEqual(persisted.state.uiState.searchText, "saved")
    }

    func testFailedShutdownCanBeRetriedWithoutLosingState() async throws {
        let directory = try makeTestDirectory()
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        coordinator.start()
        try await waitUntil(description: "coordinator startup") { coordinator.hasLoadedState }

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let failed = await coordinator.shutdown()
        XCTAssertFalse(failed)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        coordinator.setSearchText("retry")
        let retried = await coordinator.flushState()
        XCTAssertTrue(retried)
        let persisted = await StateStore(fileURL: stateFile).load()
        XCTAssertEqual(persisted.state.uiState.searchText, "retry")
    }

    func testRememberedOpenApplicationIsDeduplicatedAndPersisted() async throws {
        let directory = try makeTestDirectory()
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)

        coordinator.rememberOpenApplication(applicationURL)
        coordinator.rememberOpenApplication(applicationURL)
        coordinator.rememberOpenApplication(directory.appendingPathComponent("NotAnApplication"))

        let expected = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(coordinator.state.uiState.savedOpenApplicationURLs, [expected])
        let saved = await coordinator.flushState()
        XCTAssertTrue(saved)
        let loaded = await StateStore(fileURL: stateFile).load()
        XCTAssertEqual(loaded.state.uiState.savedOpenApplicationURLs, [expected])
    }

    func testRememberedOpenApplicationSaveSurvivesFailedSourceOperation() async throws {
        let directory = try makeTestDirectory()
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        coordinator.rememberOpenApplication(applicationURL)

        await coordinator.addStandaloneRepository(directory.appendingPathComponent("NotARepository"))
        try await waitUntil(description: "failed repository operation") { coordinator.errorMessage != nil }
        try await Task.sleep(for: .milliseconds(100))

        let expected = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        let loaded = await StateStore(fileURL: stateFile).load()
        XCTAssertEqual(loaded.state.uiState.savedOpenApplicationURLs, [expected])
    }

    func testRememberedOpenApplicationAppearsInRepositoryMenu() async throws {
        let directory = try makeTestDirectory()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repositoryURL)
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repositoryURL)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)

        coordinator.rememberOpenApplication(applicationURL)
        let sidebarController = RepoSidebarViewController(coordinator: coordinator)
        let menu = NSMenu()
        sidebarController.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: menu, repositoryID: repositoryID)
        )

        let openWithItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Open in Regular App" }))
        let openWithMenu = try XCTUnwrap(openWithItem.submenu)
        XCTAssertTrue(openWithMenu.items.contains { $0.title == "Editor" })
        for title in ["Choose Application…", "Remove Selected…", "Remove All from List", "Remove from List"] {
            XCTAssertTrue(openWithMenu.items.contains { $0.title == title })
        }
        let chooseItem = try XCTUnwrap(
            openWithMenu.items.first(where: { $0.title == "Choose Application…" })
        )
        let chooseTarget = try XCTUnwrap(
            chooseItem.representedObject as? RepoSidebarApplicationController.OpenDirectoryTarget
        )
        guard case .defaultApplication = chooseTarget.application else {
            XCTFail("Expected default application target for application selection.")
            return
        }
        let editorItem = try XCTUnwrap(openWithMenu.items.first(where: { $0.title == "Editor" }))
        let editorTarget = try XCTUnwrap(
            editorItem.representedObject as? RepoSidebarApplicationController.OpenDirectoryTarget
        )
        guard case .explicit(let application) = editorTarget.application else {
            XCTFail("Expected explicit application target for remembered application.")
            return
        }
        XCTAssertEqual(application.url, applicationURL.resolvingSymlinksInPath().standardizedFileURL)
        let removeAllItem = try XCTUnwrap(
            openWithMenu.items.first(where: { $0.title == "Remove All from List" })
        )
        let removalTarget = try XCTUnwrap(
            removeAllItem.representedObject as? OpenApplicationMenuRenderer.ApplicationTarget
        )
        XCTAssertTrue(removalTarget.applicationURLs.contains {
            PersistedOpenApplicationList.stableIdentity(for: $0) == PersistedOpenApplicationList.stableIdentity(for: applicationURL)
        })
        XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(removeAllItem.action)), "removeOpenApplications:")
    }

    func testOpenApplicationCanBeRemovedAndReaddedFromRepositoryMenu() async throws {
        let directory = try makeTestDirectory()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repositoryURL)
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        await coordinator.addStandaloneRepository(repositoryURL)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.rememberOpenApplication(applicationURL)

        let sidebarController = RepoSidebarViewController(coordinator: coordinator)
        let menu = NSMenu()
        sidebarController.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: menu, repositoryID: repositoryID)
        )
        let openWithMenu = try XCTUnwrap(menu.items.first(where: { $0.title == "Open in Regular App" })?.submenu)
        let removeMenu = try XCTUnwrap(
            openWithMenu.items.first(where: { $0.title == "Remove from List" })?.submenu
        )
        let removeEditorItem = try XCTUnwrap(removeMenu.items.first(where: { $0.title == "Editor" }))

        try FileManager.default.removeItem(at: applicationURL)
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(removeEditorItem.action),
            to: removeEditorItem.target,
            from: removeEditorItem
        ))
        XCTAssertTrue(coordinator.state.uiState.excludedOpenApplicationURLs.contains {
            PersistedOpenApplicationList.stableIdentity(for: $0) == PersistedOpenApplicationList.stableIdentity(for: applicationURL)
        })
        XCTAssertFalse(coordinator.state.uiState.savedOpenApplicationURLs.contains {
            PersistedOpenApplicationList.stableIdentity(for: $0) == PersistedOpenApplicationList.stableIdentity(for: applicationURL)
        })
        let flushed = await coordinator.flushState()
        XCTAssertTrue(flushed)
        let persisted = await StateStore(fileURL: stateFile).load()
        XCTAssertEqual(
            persisted.state.uiState.excludedOpenApplicationURLs.compactMap(PersistedOpenApplicationList.stableIdentity(for:)),
            [try XCTUnwrap(PersistedOpenApplicationList.stableIdentity(for: applicationURL))]
        )
        try makeApplicationBundle(at: applicationURL)

        let removedMenu = NSMenu()
        sidebarController.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: removedMenu, repositoryID: repositoryID)
        )
        let removedOpenWithMenu = try XCTUnwrap(removedMenu.items.first(where: { $0.title == "Open in Regular App" })?.submenu)
        XCTAssertFalse(removedOpenWithMenu.items.contains { $0.title == "Editor" })

        coordinator.rememberOpenApplication(applicationURL)
        let restoredMenu = NSMenu()
        sidebarController.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: restoredMenu, repositoryID: repositoryID)
        )
        let restoredOpenWithMenu = try XCTUnwrap(restoredMenu.items.first(where: { $0.title == "Open in Regular App" })?.submenu)
        XCTAssertTrue(restoredOpenWithMenu.items.contains { $0.title == "Editor" })
        XCTAssertTrue(coordinator.state.uiState.excludedOpenApplicationURLs.isEmpty)
    }
    func testSelectedOpenApplicationRemovalPreservesOtherRememberedState() throws {
        let directory = try makeTestDirectory()
        let selectedURL = directory.appendingPathComponent("Selected.app", isDirectory: true)
        let untouchedURL = directory.appendingPathComponent("Untouched.app", isDirectory: true)
        try makeApplicationBundle(at: selectedURL)
        try makeApplicationBundle(at: untouchedURL)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        coordinator.rememberOpenApplication(selectedURL)
        coordinator.rememberOpenApplication(untouchedURL)
        try FileManager.default.removeItem(at: untouchedURL)

        coordinator.removeOpenApplications([selectedURL])

        let savedPaths = Set(coordinator.state.uiState.savedOpenApplicationURLs.map(\.path))
        XCTAssertFalse(savedPaths.contains(selectedURL.path))
        XCTAssertTrue(savedPaths.contains(untouchedURL.path))
    }

    func testRemovingManyApplicationsRetainsNewestBoundedExclusions() throws {
        let directory = try makeTestDirectory()
        let applications = (0...PersistedOpenApplicationList.maxExcludedApplications).map {
            directory.appendingPathComponent("App\($0).app")
        }
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))

        coordinator.removeOpenApplications(applications)

        let excludedPaths = coordinator.state.uiState.excludedOpenApplicationURLs.map(\.path)
        XCTAssertEqual(excludedPaths.count, PersistedOpenApplicationList.maxExcludedApplications)
        XCTAssertFalse(excludedPaths.contains(applications[0].path))
        XCTAssertTrue(excludedPaths.contains(applications[PersistedOpenApplicationList.maxExcludedApplications].path))
    }

    func testOpenApplicationsCanBeRemovedTogetherFromRepositoryMenu() async throws {
        let directory = try makeTestDirectory()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repositoryURL)
        let editorURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        let viewerURL = directory.appendingPathComponent("Viewer.app", isDirectory: true)
        try makeApplicationBundle(at: editorURL)
        try makeApplicationBundle(at: viewerURL)
        let stateFile = directory.appendingPathComponent("state.json")
        let coordinator = makeCoordinator(stateFile: stateFile)
        await coordinator.addStandaloneRepository(repositoryURL)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.rememberOpenApplication(editorURL)
        coordinator.rememberOpenApplication(viewerURL)
        let rememberedPaths = Set(coordinator.state.uiState.savedOpenApplicationURLs.map(\.path))

        let sidebarController = RepoSidebarViewController(coordinator: coordinator)
        let menu = NSMenu()
        sidebarController.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: menu, repositoryID: repositoryID)
        )
        let openWithMenu = try XCTUnwrap(menu.items.first(where: { $0.title == "Open in Regular App" })?.submenu)
        let removeAllItem = try XCTUnwrap(openWithMenu.items.first(where: { $0.title == "Remove All from List" }))
        let removeSelectedItem = try XCTUnwrap(openWithMenu.items.first(where: { $0.title == "Remove Selected…" }))
        XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(removeSelectedItem.action)), "removeSelectedOpenApplications:")

        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(removeAllItem.action),
            to: removeAllItem.target,
            from: removeAllItem
        ))
        XCTAssertTrue(Set(coordinator.state.uiState.excludedOpenApplicationURLs.map(\.path)).isSuperset(of: rememberedPaths))
        XCTAssertTrue(coordinator.state.uiState.savedOpenApplicationURLs.isEmpty)

        let flushed = await coordinator.flushState()
        XCTAssertTrue(flushed)
        let persisted = await StateStore(fileURL: stateFile).load()
        XCTAssertTrue(Set(persisted.state.uiState.excludedOpenApplicationURLs.map(\.path)).isSuperset(of: rememberedPaths))
        XCTAssertTrue(persisted.state.uiState.savedOpenApplicationURLs.isEmpty)
    }

    func testRepositoryMenuOffersGitHubForConfiguredExternalRemote() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["remote", "add", "origin", "git@github.com:octo/repo.git"])
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))

        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        try await waitUntil(description: "github repository URL") {
            coordinator.githubURLs[repositoryID] != nil
        }

        let sidebarController = RepoSidebarViewController(coordinator: coordinator)
        let menu = NSMenu()
        sidebarController.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: menu, repositoryID: repositoryID)
        )
         let githubItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Open on GitHub" }))
         XCTAssertTrue(githubItem.target === sidebarController.githubMenuController)
         XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(githubItem.action)), "openRepositoryOnGitHub:")

        XCTAssertNotNil(menu.items.first(where: { $0.title == "Open on GitHub" }))
    }

}
