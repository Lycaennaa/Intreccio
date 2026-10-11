@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testOMPScriptChecksQuotedRepositoryAndIdentity() throws {
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
            scriptsDirectory: scriptsDirectory
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let quotedPath = repository.path.replacingOccurrences(of: "'", with: "'\\''")

        XCTAssertEqual(scriptURL.lastPathComponent, "a6d34c09-2a39-40fb-9e5b-50d69a04ca7a.command")
        XCTAssertTrue(script.contains("cd -- '\(quotedPath)' || exit"))
        let identityGuard = "if [ \"$(/usr/bin/stat -f '%d:%i' .)\" != '\(expectedFileSystemID)' ]; then"
        XCTAssertTrue(script.contains(identityGuard))
        XCTAssertTrue(script.hasSuffix("exec omp\n"))
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testOMPRefusesAReplacedRepositoryPath() throws {
        let root = try makeTestDirectory()
        let repository = root.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let expectedFileSystemID = try XCTUnwrap(ResourceIdentity.readFileSystemID(from: repository))
        let scriptURL = try OMPLauncher.writeScript(
            in: repository,
            expectedFileSystemID: expectedFileSystemID,
            repositoryID: UUID(),
            scriptsDirectory: root.appendingPathComponent("scripts", isDirectory: true)
        )
        let binaryDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let markerURL = root.appendingPathComponent("omp-ran")
        let fakeOMP = binaryDirectory.appendingPathComponent("omp")
        let quotedMarker = "'\(markerURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        try "#!/bin/sh\n: > \(quotedMarker)\n".write(to: fakeOMP, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeOMP.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(binaryDirectory.path):\(environment["PATH"] ?? "")"

        func runScript() throws -> (status: Int32, standardError: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", scriptURL.path]
            process.currentDirectoryURL = root
            process.environment = environment
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
        let scriptURL = try OMPLauncher.writeScript(
            in: repository,
            expectedFileSystemID: fileSystemID,
            repositoryID: repositoryID,
            scriptsDirectory: directory.appendingPathComponent("scripts", isDirectory: true)
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let command = try XCTUnwrap(
            OMPLauncher.ternArguments(in: repository, expectedFileSystemID: fileSystemID).last
        )

        XCTAssertTrue(command.contains("stat -f '%d:%i' ."))
        XCTAssertTrue(command.contains("'123:456'"))
        XCTAssertTrue(script.contains(command))
    }

    func testTernArgumentsEnterQuotedRepositoryDirectoryBeforeRunningOMP() {
        let repository = URL(fileURLWithPath: "/work/Repo's source", isDirectory: true)
        let command = [
            "cd -- '/work/Repo'\\''s source' || exit",
            "if [ \"$(/usr/bin/stat -f '%d:%i' .)\" != '123:456' ]; then",
            "  printf '%s\\n' 'Repository changed before OMP launch.' >&2",
            "  exit 1",
            "fi",
            "exec omp"
        ].joined(separator: "\n")

        XCTAssertEqual(
            OMPLauncher.ternArguments(in: repository, expectedFileSystemID: "123:456"),
            ["-e", "/bin/zsh", "-l", "-c", command]
        )
    }

    func testAIOMPMenuOffersTerminalAppAndTern() async throws {
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
        let aiToolSubmenu = try XCTUnwrap(menu.items.first(where: { $0.title == "Open in AI Tool" })?.submenu)
        let ompMenu = try XCTUnwrap(aiToolSubmenu.items.first(where: { $0.title == "OMP" }))
        let ompItems = try XCTUnwrap(ompMenu.submenu).items
        XCTAssertEqual(ompItems.map(\.title), TerminalChoice.allCases.map(\.menuTitle))
        for (item, terminal) in zip(ompItems, TerminalChoice.allCases) {
            let target = try XCTUnwrap(item.representedObject as? RepoSidebarAIController.OpenTarget)
            XCTAssertEqual(target.destination, .omp(terminal))
            XCTAssertEqual(target.repositoryIDs, [repositoryID])
            XCTAssertTrue(item.target is RepoSidebarAIController)
            XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(item.action)), "openSelectedRepositories:")
        }
        XCTAssertNotNil(aiToolSubmenu.items.first(where: { $0.title == "T3 Code" }))
    }

    func testTerminalLaunchErrorsWaitForFailedTermination() {
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

        _ = controller.cancelOperationsForTermination()
        controller.presentOpenError(
            applicationName: "OMP in Apple Terminal",
            path: "/repo",
            description: "Terminal could not open the command.",
            context: context
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
