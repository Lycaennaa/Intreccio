import Darwin
import AppKit
import Foundation
import XCTest
@testable import Intreccio

extension AppCoordinatorTests {
    func testJustfileServiceUsesJustSummary() throws {
        try requireJust()
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try """
        build:
            echo build

        release:
            echo release
        """.write(
            to: repository.appendingPathComponent("justfile"),
            atomically: true,
            encoding: .utf8
        )

        guard case .definition(let definition) = JustfileService.discovery(in: repository) else {
            return XCTFail("Expected Just to return its recipe summary")
        }
        XCTAssertEqual(Set(definition.recipes.map(\.name)), Set(["build", "release"]))
    }

    func testJustfileServiceDistinguishesMissingJustAndJustfile() throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        XCTAssertEqual(
            JustfileService.discovery(in: repository, justExecutableURL: nil),
            .noJustfile(justInstalled: false)
        )
        try "build:\n    echo build\n".write(
            to: repository.appendingPathComponent("justfile"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            JustfileService.discovery(in: repository, justExecutableURL: nil),
            .justNotInstalled
        )
    }

    func testJustfileServiceBuildsTerminalCommand() {
        let repository = URL(fileURLWithPath: "/tmp/Repo's Name", isDirectory: true)
        let justfile = repository.appendingPathComponent("Justfile")

        XCTAssertEqual(
            JustfileService.command(for: "build-release", in: repository, justfileURL: justfile),
            "cd -- '/tmp/Repo'\\''s Name' && just --justfile '/tmp/Repo'\\''s Name/Justfile' 'build-release'"
        )
    }

    func testJustRecipeScriptIsPersistentAndUpdatedInPlace() throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repository", isDirectory: true)
        let scriptsDirectory = directory.appendingPathComponent("scripts", isDirectory: true)
        let repositoryID = UUID()

        let firstURL = try TerminalLauncher.writeScript(
            command: "cd -- '/old' && just --justfile '/old/justfile' 'build'",
            repositoryURL: repository,
            repositoryID: repositoryID,
            recipeName: "build",
            scriptsDirectory: scriptsDirectory
        )
        let secondURL = try TerminalLauncher.writeScript(
            command: "cd -- '/new' && just --justfile '/new/Justfile' 'build'",
            repositoryURL: repository,
            repositoryID: repositoryID,
            recipeName: "build",
            scriptsDirectory: scriptsDirectory
        )

        XCTAssertEqual(firstURL, secondURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        let script = try String(contentsOf: secondURL, encoding: .utf8)
        XCTAssertTrue(script.contains("cd -- '/new' && just --justfile '/new/Justfile' 'build'"))
        XCTAssertFalse(script.contains("trap 'rm -f"))
        let attributes = try FileManager.default.attributesOfItem(atPath: secondURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testRepositoryMenuOffersJustRecipesFromJustfile() async throws {
        try requireJust()
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        try """
        build:
            echo build

        build-release:
            echo release
        """.write(
            to: repository.appendingPathComponent("justfile"),
            atomically: true,
            encoding: .utf8
        )

        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        let controller = RepoSidebarViewController(coordinator: coordinator)
        let menu = NSMenu()

        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: menu, repositoryID: repositoryID)
        )
        let justItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Just" }))
        let justMenu = try XCTUnwrap(justItem.submenu)
        XCTAssertEqual(justMenu.items.map(\.title), ["Loading recipes…"])
        await controller.menuController.waitForJustMenuDiscovery()

        XCTAssertEqual(justMenu.items.map(\.title), ["build", "build-release"])
        for item in justMenu.items {
            XCTAssertTrue(item.target is RepoSidebarJustMenuController)
            XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(item.action)), "runRecipe:")
            let target = try XCTUnwrap(
                item.representedObject as? RepoSidebarJustMenuController.RecipeTarget
            )
            XCTAssertEqual(target.repositoryID, repositoryID)
            XCTAssertEqual(target.recipeName, item.title)
        }
    }
    func testRepositoryMenuOffersCreateAndInfoWithoutJustfile() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)

        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        let controller = RepoSidebarViewController(coordinator: coordinator)
        let menu = NSMenu()

        controller.menuController.populateRepositoryMenu(
            makeRepositoryMenuContext(for: menu, repositoryID: repositoryID)
        )
        await controller.menuController.waitForJustMenuDiscovery()

        let justItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Just" }))
        let justMenu = try XCTUnwrap(justItem.submenu)
        XCTAssertTrue(
            justMenu.items.map(\.title) == ["Create", "What Is This?"]
                || justMenu.items.map(\.title) == ["Create", "just is not installed", "What Is This?"]
        )
        if justMenu.items.count == 3 {
            XCTAssertFalse(justMenu.items[1].isEnabled)
        }
        XCTAssertTrue(justMenu.items.filter { $0.action != nil }.allSatisfy { $0.target is RepoSidebarJustMenuController })
    }

    func testRepositoryMenuShowsMissingJustAndNoJustfileStates() async throws {
        let directory = try makeTestDirectory()
        let repositoryURL = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repositoryURL)

        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repositoryURL)
        let repository = try XCTUnwrap(coordinator.repositories.first)
        let implementation = RepoSidebarJustMenuSingleImplementation(
            coordinator: coordinator,
            applicationController: RepoSidebarApplicationController(coordinator: coordinator)
        )
        let menu = NSMenu()
        let context = makeRepositoryMenuContext(for: menu, repositoryID: repository.id)
        implementation.updateMenuContext(context)

        let noJustfileMenu = implementation.makeRepositoryJustMenu(
            for: repository,
            context: context,
            discovery: .noJustfile(justInstalled: false)
        )
        XCTAssertEqual(noJustfileMenu.items.map(\.title), ["Create", "just is not installed", "What Is This?"])

        try "build:\n    echo build\n".write(
            to: repositoryURL.appendingPathComponent("justfile"),
            atomically: true,
            encoding: .utf8
        )
        let justfileMenu = implementation.makeRepositoryJustMenu(
            for: repository,
            context: context,
            discovery: .justNotInstalled
        )
        XCTAssertEqual(justfileMenu.items.map(\.title), ["just is not installed", "What Is This?"])
        XCTAssertFalse(justfileMenu.items[0].isEnabled)
    }

    func testJustfileServiceCreatesExampleWithoutOverwriting() throws {
        try requireJust()
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        let fileURL = try JustfileService.createExample(in: repository)
        XCTAssertEqual(fileURL.lastPathComponent, "justfile")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("hello:"))
        XCTAssertTrue(contents.contains("@echo \"Hello from just\""))
        guard case .definition(let definition) = JustfileService.discovery(in: repository) else {
            return XCTFail("Expected the example justfile to load")
        }
        XCTAssertEqual(Set(definition.recipes.map(\.name)), Set(["hello", "build"]))
        for recipe in definition.recipes {
            let commands = try justDryRunOutput(for: recipe.name, justfileURL: fileURL)
            try assertShellSyntax(commands, recipeName: recipe.name)
        }


        XCTAssertThrowsError(try JustfileService.createExample(in: repository)) { error in
            guard case .alreadyExists(let existingURL) = error as? JustfileService.CreationError else {
                return XCTFail("Expected an already-exists error")
            }
            XCTAssertEqual(existingURL, fileURL)
        }
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), contents)
    }

    func testInvalidDiscoveryDetectsInPlaceEditWithRestoredSizeAndMTime() throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let fileURL = repository.appendingPathComponent("justfile")
        let originalContents = "invalid recipe syntax"
        try originalContents.write(to: fileURL, atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("just")
        try "#!/bin/sh\nexit 1\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let invalidDiscovery = JustfileService.discovery(in: repository, justExecutableURL: executable)
        guard case .invalidJustfile = invalidDiscovery else {
            return XCTFail("Expected the malformed justfile to be rejected")
        }
        XCTAssertTrue(JustfileService.isCurrent(invalidDiscovery, in: repository))
        var originalStatus = stat()
        let originalStatResult = fileURL.path.withCString { stat($0, &originalStatus) }
        XCTAssertEqual(originalStatResult, 0)

        let repairedContents = "build:\n    :\n"
        let sameSizeContents = repairedContents + String(
            repeating: " ",
            count: originalContents.utf8.count - repairedContents.utf8.count
        )
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: Data(sameSizeContents.utf8))
        try fileHandle.close()
        var timestamps = [originalStatus.st_atimespec, originalStatus.st_mtimespec]
        let timestampResult = fileURL.path.withCString { path in
            timestamps.withUnsafeMutableBufferPointer {
                utimensat(AT_FDCWD, path, $0.baseAddress, 0)
            }
        }
        XCTAssertEqual(timestampResult, 0)

        var repairedStatus = stat()
        let repairedStatResult = fileURL.path.withCString { stat($0, &repairedStatus) }
        XCTAssertEqual(repairedStatResult, 0)
        XCTAssertEqual(repairedStatus.st_size, originalStatus.st_size)
        XCTAssertEqual(repairedStatus.st_mtimespec.tv_sec, originalStatus.st_mtimespec.tv_sec)
        XCTAssertEqual(repairedStatus.st_mtimespec.tv_nsec, originalStatus.st_mtimespec.tv_nsec)
        XCTAssertEqual(repairedStatus.st_ino, originalStatus.st_ino)
        XCTAssertTrue(
            repairedStatus.st_ctimespec.tv_sec != originalStatus.st_ctimespec.tv_sec
                || repairedStatus.st_ctimespec.tv_nsec != originalStatus.st_ctimespec.tv_nsec
        )
        XCTAssertFalse(JustfileService.isCurrent(invalidDiscovery, in: repository))
    }



    func testJustfileServiceRejectsNamedPipeWithoutBlocking() throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let fileURL = repository.appendingPathComponent("justfile")
        let createResult = fileURL.path.withCString { mkfifo($0, mode_t(0o644)) }
        XCTAssertEqual(createResult, 0)

        let start = Date()
        let discovery = JustfileService.discovery(
            in: repository,
            justExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        XCTAssertEqual(discovery, .unsupportedJustfile)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }


    func testUnreadableJustfileIsNotReportedAsChurn() throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let fileURL = repository.appendingPathComponent("justfile")
        try "invalid recipe".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        guard !FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw XCTSkip("Current test user can read mode-000 files")
        }

        let discovery = JustfileService.discovery(
            in: repository,
            justExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        guard case .unreadableJustfile = discovery else {
            return XCTFail("Expected an explicit unreadable-file state")
        }
        XCTAssertTrue(JustfileService.isCurrent(discovery, in: repository))
    }
    func testJustfileServiceRejectsOversizedJustfileBeforeHashing() throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let fileURL = repository.appendingPathComponent("justfile")
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o644))
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, off_t(16 * 1024 * 1024 + 1)), 0)

        let discovery = JustfileService.discovery(
            in: repository,
            justExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        XCTAssertEqual(discovery, .justfileTooLarge)
    }
    func testJustfileServiceBoundsUnresponsiveProcessAndChildren() throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try "hello:".write(to: repository.appendingPathComponent("justfile"), atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("just")
        let childPIDURL = repository.appendingPathComponent("child.pid")
        let script = """
        #!/bin/sh
        if [ "$1" = "child" ]; then
            exec /bin/sleep 60
        fi
        trap '' TERM
        "$0" child &
        echo "$!" > "\(childPIDURL.path)"
        while :; do sleep 1; done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let start = Date()
        let discovery = JustfileService.discovery(in: repository, justExecutableURL: executable)
        guard case .invalidJustfile = discovery else {
            return XCTFail("Expected an unresponsive executable to be rejected")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 4.5)
        XCTAssertLessThan(elapsed, 8)
        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(childPIDText))
        let childProcessStatus = kill(childPID, 0)
        let childProcessError = errno
        XCTAssertEqual(childProcessStatus, -1)
        XCTAssertEqual(childProcessError, ESRCH)
    }

    func testJustfileServiceCleansChildAfterSuccessfulSummary() throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try "build:".write(to: repository.appendingPathComponent("justfile"), atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("just")
        let childPIDURL = repository.appendingPathComponent("child.pid")
        let script = """
        #!/bin/sh
        /bin/sleep 60 >/dev/null 2>&1 &
        echo "$!" > "\(childPIDURL.path)"
        /bin/ps -o pid=,ppid=,pgid=,sid= -p "$$,$!" > "\(repository.appendingPathComponent("processes.txt").path)"
        printf 'build\\n'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        guard case .definition(let definition) = JustfileService.discovery(
            in: repository,
            justExecutableURL: executable
        ) else { return XCTFail("Expected a valid recipe summary") }
        XCTAssertEqual(definition.recipes.map(\.name), ["build"])

        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(childPIDText))
        let processMetadata = try String(
            contentsOf: repository.appendingPathComponent("processes.txt"),
            encoding: .utf8
        )
        let processGroups = processMetadata
            .split(whereSeparator: \.isNewline)
            .compactMap { row -> String? in
                let columns = row.split(whereSeparator: \.isWhitespace)
                return columns.count > 2 ? String(columns[2]) : nil
            }
        XCTAssertEqual(processGroups.count, 2)
        XCTAssertEqual(Set(processGroups).count, 1)
        let childProcessStatus = kill(childPID, 0)
        let childProcessError = errno
        XCTAssertEqual(childProcessStatus, -1, "Unexpected live process group state: \(processMetadata)")
        XCTAssertEqual(childProcessError, ESRCH)
    }
    private func requireJust() throws {
        guard JustfileService.justExecutableURL() != nil else {
            throw XCTSkip("The optional `just` executable is not installed.")
        }
    }

    private func justDryRunOutput(for recipeName: String, justfileURL: URL) throws -> String {
        let output = Pipe()
        let process = Process()
        process.executableURL = try XCTUnwrap(JustfileService.justExecutableURL())
        process.arguments = ["--dry-run", "--justfile", justfileURL.path, recipeName]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let outputText = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "IntreccioTests.Justfile",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "just --dry-run failed for \(recipeName): \(outputText)"]
            )
        }
        return outputText
    }

    private func assertShellSyntax(_ commands: String, recipeName: String) throws {
        let diagnostics = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", commands]
        process.standardError = diagnostics
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let diagnosticText = String(
                decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "IntreccioTests.Justfile",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Shell syntax check failed for \(recipeName): \(diagnosticText)"]
            )
        }
    }

    func testJustWebsiteURLIsHTTPS() {
        XCTAssertEqual(
            RepoSidebarJustMenuController.justWebsiteURLString,
            "https://github.com/casey/just"
        )
        XCTAssertEqual(URL(string: RepoSidebarJustMenuController.justWebsiteURLString)?.scheme, "https")
    }
    func testMultiRepositoryMenuUnifiesCommonJustRecipes() async throws {
        try requireJust()
        let directory = try makeTestDirectory()
        let first = directory.appendingPathComponent("First", isDirectory: true)
        let second = directory.appendingPathComponent("Second", isDirectory: true)
        try initializeRepository(at: first)
        try initializeRepository(at: second)
        try """
        build:
            echo first

        only-first:
            echo first-only
        """.write(
            to: first.appendingPathComponent("justfile"),
            atomically: true,
            encoding: .utf8
        )
        try """
        build:
            echo second

        only-second:
            echo second-only
        """.write(
            to: second.appendingPathComponent("justfile"),
            atomically: true,
            encoding: .utf8
        )

        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(first)
        await coordinator.addStandaloneRepository(second)
        let repositoryIDs = coordinator.repositories.map(\.id)
        let controller = RepoSidebarViewController(coordinator: coordinator)
        let menu = NSMenu()
        let context = RepoSidebarMenuContext(
            menu: menu,
            node: RepoSidebarViewController.Node(title: "First", kind: .repository(repositoryIDs[0])),
            repositoryIDs: repositoryIDs,
            presentingWindow: nil
        )

        controller.menuController.populateMenu(with: context)
        let justItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Just" }))
        let justMenu = try XCTUnwrap(justItem.submenu)
        XCTAssertEqual(justMenu.items.map(\.title), ["Loading recipes…"])
        await controller.menuController.waitForJustMenuDiscovery()

        XCTAssertEqual(justMenu.items.map(\.title), ["build"])
        let recipeItem = try XCTUnwrap(justMenu.items.first)
        XCTAssertEqual(NSStringFromSelector(try XCTUnwrap(recipeItem.action)), "runSelectedRecipe:")
        let target = try XCTUnwrap(
            recipeItem.representedObject as? RepoSidebarJustMenuController.SelectedRecipeTarget
        )
        XCTAssertEqual(target.recipeName, "build")
        XCTAssertEqual(target.repositoryIDs, repositoryIDs)
    }

}