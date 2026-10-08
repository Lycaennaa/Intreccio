import AppKit
@testable import Intreccio
import XCTest

extension AppShellTests {
    @MainActor
    func testFileOpenActionIncludesConflictPath() throws {
        let directory = try makeTestDirectory()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        let conflictURL = repositoryURL.appendingPathComponent("conflict.txt")
        try "<<<<<<< ours\n".write(to: conflictURL, atomically: true, encoding: .utf8)

        let repositoryID = UUID()
        let resourceID = try XCTUnwrap(ResourceIdentity.read(from: repositoryURL))
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: resourceID,
            relativePath: nil,
            availability: .available
        )
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID
        let controller = ChangesViewController(coordinator: coordinator)

        let conflict = FileChange(
            path: "conflict.txt",
            originalPath: nil,
            indexState: .unmerged,
            worktreeState: .unmerged,
            kind: .unmerged,
            submoduleState: nil
        )
        let contextPaths = ChangesViewController.contextMenuChanges(
            clickedChanges: [conflict],
            selectedChanges: [conflict],
            clickedRowIsSelected: true
        ).map(\.path)
        let target = try XCTUnwrap(controller.makeFileOpenAction(paths: contextPaths))

        XCTAssertEqual(target.paths, ["conflict.txt"])
        guard case .defaultApplication = target.application else {
            XCTFail("Expected default application target.")
            return
        }
    }
    @MainActor
    func testFileOpenActionCapturesValidatedExplicitApplication() throws {
        let directory = try makeTestDirectory()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try "content".write(
            to: repositoryURL.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)

        let repositoryID = UUID()
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: try XCTUnwrap(ResourceIdentity.read(from: repositoryURL)),
            relativePath: nil,
            availability: .available
        )
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID
        let controller = ChangesViewController(coordinator: coordinator)

        let target = try XCTUnwrap(
            controller.makeFileOpenAction(paths: ["file.txt"], applicationURL: applicationURL)
        )
        guard case .explicit(let application) = target.application else {
            XCTFail("Expected explicit application target.")
            return
        }

        XCTAssertEqual(application.url, applicationURL.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(
            application.resourceID,
            try XCTUnwrap(ResourceIdentity.read(from: application.referenceURL))
        )
    }
    @MainActor
    func testFileOpenMenuUsesOpenWithAndSupportsMultipleFiles() throws {
        let directory = try makeTestDirectory()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        for name in ["one.txt", "two.txt"] {
            try "content".write(
                to: repositoryURL.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        let repositoryID = UUID()
        let resourceID = try XCTUnwrap(ResourceIdentity.read(from: repositoryURL))
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: resourceID,
            relativePath: nil,
            availability: .available
        )
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID
        let controller = ChangesViewController(coordinator: coordinator)
        let action = try XCTUnwrap(controller.makeFileOpenAction(paths: ["one.txt", "two.txt"]))
        let menu = NSMenu()

        controller.addOpenApplicationMenu(to: menu, fileOpenAction: action)

        let openWith = try XCTUnwrap(menu.items.first(where: { $0.title == "Open With" }))
        let submenu = try XCTUnwrap(openWith.submenu)
        XCTAssertTrue(submenu.items.contains { $0.title == "Choose Application…" })
        XCTAssertTrue(submenu.items.contains { $0.title == "Remove Selected…" })
        XCTAssertTrue(submenu.items.contains { $0.title == "Remove All from List" })
        XCTAssertTrue(submenu.items.contains { $0.title == "Remove from List" })
        XCTAssertFalse(submenu.items.contains { $0.title == "Open in Default App" })
        XCTAssertFalse(submenu.items.contains { $0.title == "Open in Preferred App" })
    }

    @MainActor
    func testMultiFileOpenActionsPreserveSelectionForMultipleApplications() throws {
        let directory = try makeTestDirectory()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        let paths = ["one.txt", "two.txt"]
        for path in paths {
            try "content".write(
                to: repositoryURL.appendingPathComponent(path),
                atomically: true,
                encoding: .utf8
            )
        }
        let firstApplicationURL = directory.appendingPathComponent("FirstEditor.app", isDirectory: true)
        let secondApplicationURL = directory.appendingPathComponent("SecondEditor.app", isDirectory: true)
        try makeApplicationBundle(at: firstApplicationURL)
        try makeApplicationBundle(at: secondApplicationURL)

        let repositoryID = UUID()
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: try XCTUnwrap(ResourceIdentity.read(from: repositoryURL)),
            relativePath: nil,
            availability: .available
        )
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID
        let controller = ChangesViewController(coordinator: coordinator)

        let defaultAction = try XCTUnwrap(controller.makeFileOpenAction(paths: paths))
        let firstAction = try XCTUnwrap(
            controller.makeFileOpenAction(paths: paths, applicationURL: firstApplicationURL)
        )
        let secondAction = try XCTUnwrap(
            controller.makeFileOpenAction(paths: paths, applicationURL: secondApplicationURL)
        )

        XCTAssertEqual(firstAction.paths, paths)
        XCTAssertEqual(secondAction.paths, paths)
        XCTAssertEqual(firstAction.fileResourceIDs, defaultAction.fileResourceIDs)
        XCTAssertEqual(secondAction.fileResourceIDs, defaultAction.fileResourceIDs)
        XCTAssertEqual(firstAction.fileReferenceURLs, defaultAction.fileReferenceURLs)
        XCTAssertEqual(secondAction.fileReferenceURLs, defaultAction.fileReferenceURLs)
        guard case .explicit(let firstApplication) = firstAction.application,
              case .explicit(let secondApplication) = secondAction.application else {
            XCTFail("Expected explicit application targets.")
            return
        }
        XCTAssertNotEqual(firstApplication.url, secondApplication.url)
        XCTAssertEqual(
            firstApplication.resourceID,
            try XCTUnwrap(ResourceIdentity.read(from: firstApplication.referenceURL))
        )
        XCTAssertEqual(
            secondApplication.resourceID,
            try XCTUnwrap(ResourceIdentity.read(from: secondApplication.referenceURL))
        )
    }

    @MainActor
    func testMultiApplicationOpenMenuKeepsValidatedTargetsForSelection() throws {
        let directory = try makeTestDirectory()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try "content".write(
            to: repositoryURL.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        let firstApplicationURL = directory.appendingPathComponent("FirstEditor.app", isDirectory: true)
        let secondApplicationURL = directory.appendingPathComponent("SecondEditor.app", isDirectory: true)
        try makeApplicationBundle(at: firstApplicationURL)
        try makeApplicationBundle(at: secondApplicationURL)

        let repositoryID = UUID()
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: try XCTUnwrap(ResourceIdentity.read(from: repositoryURL)),
            relativePath: nil,
            availability: .available
        )
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID
        coordinator.state.uiState.savedOpenApplicationURLs = [firstApplicationURL, secondApplicationURL]
        let controller = ChangesViewController(coordinator: coordinator)
        let sourceAction = try XCTUnwrap(controller.makeFileOpenAction(paths: ["file.txt"]))
        let menu = NSMenu()

        controller.addOpenApplicationMenu(to: menu, fileOpenAction: sourceAction)

        let submenu = try XCTUnwrap(menu.items.first(where: { $0.title == "Open With" })?.submenu)
        let explicitTargets = submenu.items.compactMap {
            $0.representedObject as? ChangesApplicationActionsController.FileOpenAction
        }.filter {
            if case .explicit = $0.application { return true }
            return false
        }
        let firstNormalizedURL = firstApplicationURL.resolvingSymlinksInPath().standardizedFileURL
        let secondNormalizedURL = secondApplicationURL.resolvingSymlinksInPath().standardizedFileURL
        let savedTargets = explicitTargets.filter {
            guard case .explicit(let application) = $0.application else { return false }
            return application.url == firstNormalizedURL || application.url == secondNormalizedURL
        }
        XCTAssertEqual(savedTargets.count, 2)
        XCTAssertEqual(
            Set(savedTargets.compactMap { target -> URL? in
                guard case .explicit(let application) = target.application else { return nil }
                return application.url
            }),
            Set([firstNormalizedURL, secondNormalizedURL])
        )
        XCTAssertTrue(savedTargets.allSatisfy {
            $0.paths == sourceAction.paths
                && $0.fileSelection.fileURLs == sourceAction.fileSelection.fileURLs
                && $0.fileResourceIDs == sourceAction.fileResourceIDs
                && $0.fileReferenceURLs == sourceAction.fileReferenceURLs
        })
    }

    @MainActor
    func testMultiFileApplicationLookupReusesFirstLaunchServicesQuery() {
        let firstURL = URL(fileURLWithPath: "one.txt")
        let secondURL = URL(fileURLWithPath: "two.txt")
        var queriedURLs = [URL]()
        let service = LaunchServicesApplicationService(applicationURLsForOpening: { url in
            queriedURLs.append(url)
            return []
        })

        _ = service.validatedApplications(
            for: [firstURL, secondURL, firstURL],
            applicationList: PersistedOpenApplicationList()
        )

        XCTAssertEqual(queriedURLs, [firstURL, secondURL])
    }

    @MainActor
    func testMultiFileOpenMenuExcludesRememberedIncompatibleApplication() throws {
        let directory = try makeTestDirectory()
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)
        let urls = [
            directory.appendingPathComponent("one.txt"),
            directory.appendingPathComponent("two.txt")
        ]

        let applications = LaunchServicesApplicationService.shared.applications(
            for: urls,
            applicationList: PersistedOpenApplicationList(
                savedApplicationURLs: [applicationURL],
                excludedApplicationURLs: []
            )
        )

        XCTAssertFalse(applications.contains(applicationURL))
    }
    @MainActor
    func testSingleFileMenuExcludesDefaultFolderApplications() throws {
        let directory = try makeTestDirectory()
        let fileURL = directory.appendingPathComponent("one.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        let applications = LaunchServicesApplicationService.shared.applications(
            for: [fileURL],
            applicationList: PersistedOpenApplicationList(
                savedApplicationURLs: PersistedOpenApplicationList.defaultFolderApplicationURLs,
                excludedApplicationURLs: []
            )
        )

        let names = Set(applications.map { LaunchServicesApplicationService.shared.applicationName(for: $0) })
        XCTAssertFalse(names.contains("Finder"))
        XCTAssertFalse(names.contains("Terminal"))
    }

    @MainActor
    func testFileOpenMenuUsesRememberedApplicationForRemovalControls() throws {
        let directory = try makeTestDirectory()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        let fileURL = repositoryURL.appendingPathComponent("file.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)
        let applicationURL = directory.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplicationBundle(at: applicationURL)

        let repositoryID = UUID()
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: repositoryURL,
            canonicalURL: repositoryURL,
            resourceID: try XCTUnwrap(ResourceIdentity.read(from: repositoryURL)),
            relativePath: nil,
            availability: .available
        )
        let coordinator = AppCoordinator(
            repositoryCatalogFixture: RepositoryCatalogFixture(repositories: [repository])
        )
        coordinator.state.uiState.selectedRepoID = repositoryID
        coordinator.rememberOpenApplication(applicationURL)
        let controller = ChangesViewController(coordinator: coordinator)
        let action = try XCTUnwrap(controller.makeFileOpenAction(paths: ["file.txt"]))
        let menu = NSMenu()

        controller.addOpenApplicationMenu(to: menu, fileOpenAction: action)

        let submenu = try XCTUnwrap(menu.items.first(where: { $0.title == "Open With" })?.submenu)
        let removeMenu = try XCTUnwrap(submenu.items.first(where: { $0.title == "Remove from List" })?.submenu)
        XCTAssertTrue(removeMenu.items.contains { $0.title == "Editor" })
        let removeAllItem = try XCTUnwrap(
            submenu.items.first(where: { $0.title == "Remove All from List" })
        )
        let removalTarget = try XCTUnwrap(
            removeAllItem.representedObject as? OpenApplicationMenuRenderer.ApplicationTarget
        )
        XCTAssertTrue(removalTarget.applicationURLs.contains {
            PersistedOpenApplicationList.stableIdentity(for: $0) == PersistedOpenApplicationList.stableIdentity(for: applicationURL)
        })
        XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(removeAllItem.action)), "removeOpenApplications:")
        let openItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Open" }))
        XCTAssertEqual(
            NSStringFromSelector(try XCTUnwrap(openItem.action)),
            "openChangeWithDefaultApplication:"
        )
    }
}
