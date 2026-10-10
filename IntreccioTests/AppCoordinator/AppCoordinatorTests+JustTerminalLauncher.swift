@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
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
        XCTAssertFalse(script.contains("/usr/bin/osascript"))
        XCTAssertFalse(script.contains("trap 'rm -f"))

        let closingURL = try TerminalLauncher.writeScript(
            command: "cd -- '/new' && just --justfile '/new/Justfile' 'build'",
            repositoryURL: repository,
            repositoryID: repositoryID,
            recipeName: "build",
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

        let attributes = try FileManager.default.attributesOfItem(atPath: closingURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
