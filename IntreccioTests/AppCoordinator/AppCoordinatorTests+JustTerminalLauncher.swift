@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testJustRecipeScriptIsPersistentAndTerminalSpecific() throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repository", isDirectory: true)
        let scriptsDirectory = directory.appendingPathComponent("scripts", isDirectory: true)
        let repositoryID = UUID()
        let command = "cd -- '/new' && just --justfile '/new/Justfile' 'build'"

        let firstURL = try TerminalLauncher.writeScript(
            command: command,
            repositoryURL: repository,
            repositoryID: repositoryID,
            recipeName: "build",
            terminal: .appleTerminal,
            runMode: .normal,
            scriptsDirectory: scriptsDirectory
        )
        let secondURL = try TerminalLauncher.writeScript(
            command: command,
            repositoryURL: repository,
            repositoryID: repositoryID,
            recipeName: "build",
            terminal: .appleTerminal,
            runMode: .normal,
            scriptsDirectory: scriptsDirectory
        )

        XCTAssertEqual(firstURL, secondURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        let script = try String(contentsOf: secondURL, encoding: .utf8)
        XCTAssertTrue(script.contains(command))
        XCTAssertTrue(script.contains("exec /bin/zsh -l"))
        XCTAssertFalse(script.contains("/usr/bin/osascript"))
        XCTAssertFalse(script.contains("trap 'rm -f"))

        let closingURL = try TerminalLauncher.writeScript(
            command: command,
            repositoryURL: repository,
            repositoryID: repositoryID,
            recipeName: "build",
            terminal: .appleTerminal,
            runMode: .closeTerminalWhenFinished,
            scriptsDirectory: scriptsDirectory
        )
        XCTAssertNotEqual(secondURL, closingURL)
        let closingScript = try String(contentsOf: closingURL, encoding: .utf8)
        XCTAssertTrue(closingScript.contains("recipe_exit_code=$?"))
        XCTAssertTrue(closingScript.contains("recipe_exit_code=127"))
        XCTAssertTrue(closingScript.contains("/usr/bin/osascript - \"$(/usr/bin/tty)\""))
        XCTAssertTrue(closingScript.contains("close terminalTab saving no"))
        XCTAssertTrue(closingScript.contains("exit \"$recipe_exit_code\""))
        let missingJustStatus = try XCTUnwrap(closingScript.range(of: "recipe_exit_code=127"))
        let closeCommand = try XCTUnwrap(closingScript.range(of: "/usr/bin/osascript"))
        let finalExit = try XCTUnwrap(closingScript.range(of: "exit \"$recipe_exit_code\""))
        XCTAssertLessThan(missingJustStatus.lowerBound, closeCommand.lowerBound)
        XCTAssertLessThan(closeCommand.lowerBound, finalExit.lowerBound)

        let ternURL = try TerminalLauncher.writeScript(
            command: command,
            repositoryURL: repository,
            repositoryID: repositoryID,
            recipeName: "build",
            terminal: .tern,
            runMode: .closeTerminalWhenFinished,
            scriptsDirectory: scriptsDirectory
        )
        XCTAssertNotEqual(closingURL, ternURL)
        let ternScript = try String(contentsOf: ternURL, encoding: .utf8)
        XCTAssertFalse(ternScript.contains("/usr/bin/osascript"))
        XCTAssertEqual(
            TerminalLauncher.ternArguments(for: ternURL, runMode: .normal),
            ["-e", "/bin/zsh", "-l", "-c", "\"$1\"; exec /bin/zsh -l", "intreccio-just", ternURL.path]
        )
        XCTAssertEqual(
            TerminalLauncher.ternArguments(for: ternURL, runMode: .closeTerminalWhenFinished),
            ["-e", "/bin/zsh", "-l", "-c", "\"$1\"", "intreccio-just", ternURL.path]
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: ternURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
