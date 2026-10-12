@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testOMPScriptChecksQuotedRepositoryAndIdentity() throws {
        let expectedOMPExecutableURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Tern", isDirectory: true)
            .appendingPathComponent("omp", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("omp")
        XCTAssertEqual(OMPLauncher.defaultOMPExecutableURL, expectedOMPExecutableURL)
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo's source", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let expectedFileSystemID = try XCTUnwrap(ResourceIdentity.readFileSystemID(from: repository))
        let scriptsDirectory = directory.appendingPathComponent("scripts", isDirectory: true)
        let repositoryID = try XCTUnwrap(UUID(uuidString: "A6D34C09-2A39-40FB-9E5B-50D69A04CA7A"))

        let scriptURL = try OMPLauncher.writeScript(
            in: repository,
            expectedFileSystemID: expectedFileSystemID,
            repositoryID: repositoryID,
            scriptsDirectory: scriptsDirectory,
            ompExecutableURL: OMPLauncher.defaultOMPExecutableURL
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let quotedPath = repository.path.replacingOccurrences(of: "'", with: "'\\''")
        let quotedOMPExecutablePath = expectedOMPExecutableURL.path
            .replacingOccurrences(of: "'", with: "'\\''")

        XCTAssertEqual(scriptURL.lastPathComponent, "a6d34c09-2a39-40fb-9e5b-50d69a04ca7a.command")
        XCTAssertTrue(script.contains("cd -- '\(quotedPath)' || exit"))
        let identityGuard = "if [ \"$(/usr/bin/stat -f '%d:%i' .)\" != '\(expectedFileSystemID)' ]; then"
        XCTAssertTrue(script.contains(identityGuard))
        XCTAssertTrue(script.hasSuffix("exec '\(quotedOMPExecutablePath)'\n"))
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testOMPRefusesAReplacedRepositoryPath() throws {
        let root = try makeTestDirectory()
        let repository = root.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let expectedFileSystemID = try XCTUnwrap(ResourceIdentity.readFileSystemID(from: repository))
        let binaryDirectory = root.appendingPathComponent("bin with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let fakeOMP = binaryDirectory.appendingPathComponent("omp's stub")
        let scriptURL = try OMPLauncher.writeScript(
            in: repository,
            expectedFileSystemID: expectedFileSystemID,
            repositoryID: UUID(),
            scriptsDirectory: root.appendingPathComponent("scripts", isDirectory: true),
            ompExecutableURL: fakeOMP
        )
        let markerURL = root.appendingPathComponent("omp-ran")
        let quotedMarker = "'\(markerURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        try "#!/bin/sh\n: > \(quotedMarker)\n".write(to: fakeOMP, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeOMP.path)

        func runScript() throws -> (status: Int32, standardError: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", scriptURL.path]
            process.currentDirectoryURL = root
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, try XCTUnwrap(String(data: data, encoding: .utf8)))
        }

        let original = try runScript()
        XCTAssertEqual(original.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        try FileManager.default.removeItem(at: markerURL)

        let displacedRepository = root.appendingPathComponent("Repo-original", isDirectory: true)
        try FileManager.default.moveItem(at: repository, to: displacedRepository)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        XCTAssertNotEqual(ResourceIdentity.readFileSystemID(from: repository), expectedFileSystemID)

        let replacement = try runScript()
        XCTAssertNotEqual(replacement.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(replacement.standardError.contains("Repository changed before OMP launch."))
    }

    func testOMPShellCommandIsSharedByTernAndTerminalScript() throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo's source", isDirectory: true)
        let fileSystemID = "123:456"
        let repositoryID = UUID()
        let ompExecutableURL = OMPLauncher.defaultOMPExecutableURL
        let scriptURL = try OMPLauncher.writeScript(
            in: repository,
            expectedFileSystemID: fileSystemID,
            repositoryID: repositoryID,
            scriptsDirectory: directory.appendingPathComponent("scripts", isDirectory: true),
            ompExecutableURL: ompExecutableURL
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let command = try XCTUnwrap(
            OMPLauncher.ternArguments(
                in: repository,
                expectedFileSystemID: fileSystemID,
                ompExecutableURL: ompExecutableURL
            ).last
        )

        XCTAssertTrue(command.contains("stat -f '%d:%i' ."))
        XCTAssertTrue(command.contains("'123:456'"))
        XCTAssertTrue(script.contains(command))
    }

    func testTernArgumentsEnterQuotedRepositoryDirectoryBeforeRunningOMP() {
        let repository = URL(fileURLWithPath: "/work/Repo's source", isDirectory: true)
        let ompExecutableURL = OMPLauncher.defaultOMPExecutableURL
        let quotedOMPExecutablePath = ompExecutableURL.path
            .replacingOccurrences(of: "'", with: "'\\''")
        let command = [
            "cd -- '/work/Repo'\\''s source' || exit",
            "if [ \"$(/usr/bin/stat -f '%d:%i' .)\" != '123:456' ]; then",
            "  printf '%s\\n' 'Repository changed before OMP launch.' >&2",
            "  exit 1",
            "fi",
            "exec '\(quotedOMPExecutablePath)'"
        ].joined(separator: "\n")

        XCTAssertEqual(
            OMPLauncher.ternArguments(
                in: repository,
                expectedFileSystemID: "123:456",
                ompExecutableURL: ompExecutableURL
            ),
            ["-e", "/bin/zsh", "-l", "-c", command]
        )
        XCTAssertEqual(
            OMPLauncher.ternArguments(
                in: repository,
                expectedFileSystemID: "123:456",
                windowMode: .appendToWindow,
                ompExecutableURL: ompExecutableURL
            ),
            ["new", "tab", "--cwd", repository.path, "--", "/bin/zsh", "-l", "-c", command]
        )
        XCTAssertEqual(
            OMPLauncher.ternArguments(
                in: repository,
                expectedFileSystemID: "123:456",
                windowMode: .splitView,
                ompExecutableURL: ompExecutableURL
            ),
            [
                "split",
                "@focused",
                "right",
                "--cwd",
                repository.path,
                "--",
                "/bin/zsh",
                "-l",
                "-c",
                command
            ]
        )
    }

    func testAIOMPMenuOffersTerminalAppAndTernLaunchModes() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addWatchRoot(directory)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        let controller = RepoSidebarViewController(coordinator: coordinator)
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller

        let menu = NSMenu()
        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: menu, repositoryID: repositoryID, presentingWindow: window)
        )
        try checkAIOMPMenuStructure(in: menu, repositoryID: repositoryID)
    }

    private func checkAIOMPMenuStructure(in menu: NSMenu, repositoryID: UUID) throws {
        let aiToolSubmenu = try XCTUnwrap(
            menu.items.first(where: { $0.title == "Open in AI Tool" })?.submenu
        )
        let ompMenu = try XCTUnwrap(aiToolSubmenu.items.first(where: { $0.title == "OMP" }))
        let ompItems = try XCTUnwrap(ompMenu.submenu).items
        XCTAssertEqual(
            ompItems.map(\.title),
            [TerminalChoice.appleTerminal.menuTitle, TerminalChoice.tern.menuTitle]
        )

        let appleTerminalItem = try XCTUnwrap(
            ompItems.first(where: { $0.title == TerminalChoice.appleTerminal.menuTitle })
        )
        let appleTerminalTarget = try XCTUnwrap(
            appleTerminalItem.representedObject as? RepoSidebarAIController.OpenTarget
        )
        XCTAssertEqual(appleTerminalTarget.destination, .omp(.appleTerminal))
        XCTAssertEqual(appleTerminalTarget.repositoryIDs, [repositoryID])
        XCTAssertTrue(appleTerminalItem.target is RepoSidebarAIController)
        XCTAssertEqual(
            NSStringFromSelector(try XCTUnwrap(appleTerminalItem.action)),
            "openSelectedRepositories:"
        )

        let ternItem = try XCTUnwrap(ompItems.first(where: { $0.title == TerminalChoice.tern.menuTitle }))
        let ternItems = try XCTUnwrap(ternItem.submenu).items
        XCTAssertEqual(ternItems.map(\.title), OMPLauncher.TernLaunchMode.allCases.map(\.menuTitle))
        for (item, mode) in zip(ternItems, OMPLauncher.TernLaunchMode.allCases) {
            let target = try XCTUnwrap(item.representedObject as? RepoSidebarAIController.OpenTarget)
            XCTAssertEqual(target.destination, .omp(.tern(mode)))
            XCTAssertEqual(target.repositoryIDs, [repositoryID])
            XCTAssertTrue(item.target is RepoSidebarAIController)
            XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(item.action)), "openSelectedRepositories:")
        }
        XCTAssertNotNil(aiToolSubmenu.items.first(where: { $0.title == "T3 Code" }))
    }

    func testAsyncOMPLaunchErrorsWaitForFailedTermination() throws {
        let coordinator = makeCoordinator(stateFile: URL(fileURLWithPath: "/unused"))
        let controller = RepoSidebarAIController(
            coordinator: coordinator,
            directoryProvider: EmptyRepositoryDirectoryProvider()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.sheets.first { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        let menu = NSMenu()
        let context = makeRepositoryMenuContext(for: menu, repositoryID: UUID(), presentingWindow: window)
        controller.addMenu(to: menu, context: context)
        let aiToolSubmenu = try XCTUnwrap(
            menu.items.first(where: { $0.title == "Open in AI Tool" })?.submenu
        )
        let ompItem = try XCTUnwrap(aiToolSubmenu.items.first(where: { $0.title == "OMP" }))
        let terminalItem = try XCTUnwrap(
            ompItem.submenu?.items.first(where: { $0.title == TerminalChoice.appleTerminal.menuTitle })
        )
        let target = try XCTUnwrap(terminalItem.representedObject as? RepoSidebarAIController.OpenTarget)

        _ = controller.cancelOperationsForTermination()
        controller.reportOpenErrorIfCurrent(
            applicationName: "OMP in Apple Terminal",
            path: "/repo",
            description: "Terminal could not open the command.",
            context: target.context,
            generation: target.generation
        )
        XCTAssertTrue(window.sheets.isEmpty)

        controller.resumeOperationsAfterFailedTermination()
        XCTAssertEqual(window.sheets.count, 1)
    }
}

@MainActor
private final class EmptyRepositoryDirectoryProvider: RepoSidebarRepositoryDirectoryProviding {
    func validatedRepositoryDirectory(for repositoryID: UUID) -> RepoSidebarValidatedRepositoryDirectory? {
        nil
    }

    func directoryPath(for repositoryID: UUID, parentDirectory: Bool) -> String {
        ""
    }
}
