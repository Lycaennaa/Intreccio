import Foundation
@testable import Intreccio
import XCTest

@MainActor
extension GitServiceIntegrationTests {
    func testStageSelectedAndAllPreserveUnrelatedState() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("a0\n", to: "a.txt")
        try fixture.write("b0\n", to: "b.txt")
        try fixture.write("c0\n", to: "c.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.write("a1\n", to: "a.txt")
        try fixture.write("b1\n", to: "b.txt")
        try fixture.write("c1\n", to: "c.txt")
        try fixture.git("add", "--", "c.txt")
        let service = GitService()

        try await service.stage(repository: fixture.url, paths: ["a.txt"])

        var status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.changes.first { $0.path == "a.txt" }?.hasStagedChange == true)
        XCTAssertTrue(status.changes.first { $0.path == "b.txt" }?.hasUnstagedChange == true)
        XCTAssertTrue(status.changes.first { $0.path == "c.txt" }?.hasStagedChange == true)

        try await service.stage(repository: fixture.url, paths: status.changes.map(\.path))
        status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.changes.allSatisfy(\.hasStagedChange))
    }

    func testGitIgnoreTargetsListAncestorsAndEscapeLiteralPaths() throws {
        XCTAssertEqual(
            GitIgnoreWriter.ancestorFolders(for: "src/generated/output.txt"),
            ["src/generated", "src"]
        )
        XCTAssertTrue(GitIgnoreWriter.contains("src/generated/output.txt", inFolder: "src"))
        XCTAssertFalse(GitIgnoreWriter.contains("src2/output.txt", inFolder: "src"))
        XCTAssertEqual(
            try GitIgnoreWriter.pattern(
                selectedPath: "src/a [x]*?.txt",
                targetPath: "src/a [x]*?.txt",
                isDirectory: false
            ),
            "/src/a\\ \\[x]\\*\\?.txt"
        )
        XCTAssertThrowsError(try GitIgnoreWriter.pattern(
            selectedPath: "src/generated/output.txt",
            targetPath: "other",
            isDirectory: true
        ))
        XCTAssertEqual(GitIgnoreWriter.ancestorFolders(for: "vendor/exampleexternalrepo/"), ["vendor"])
        XCTAssertEqual(GitIgnoreWriter.directoryTarget(for: "exampleexternalrepo/"), "exampleexternalrepo")
        XCTAssertEqual(
            try GitIgnoreWriter.pattern(
                selectedPath: "exampleexternalrepo/",
                targetPath: "exampleexternalrepo",
                isDirectory: true
            ),
            "/exampleexternalrepo/"
        )
        XCTAssertThrowsError(try GitIgnoreWriter.pattern(
            selectedPath: "exampleexternalrepo/",
            targetPath: "exampleexternalrepo/",
            isDirectory: false
        ))

    }

    func testAddToGitIgnoreAppendsRootRulesAndRefreshesGitVisibility() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("existing rule", to: ".gitignore")
        let firstPath = "src/generated/a [x]*?.txt"
        let secondPath = "src/generated/second.txt"
        try fixture.write("first\n", to: firstPath)
        let service = GitService()

        try await service.addToGitIgnore(
            repository: fixture.url,
            selectedPath: firstPath,
            targetPath: firstPath,
            isDirectory: false
        )

        XCTAssertEqual(
            try fixture.read(".gitignore"),
            "existing rule\n/src/generated/a\\ \\[x]\\*\\?.txt\n"
        )
        var status = try await service.status(repository: fixture.url)
        XCTAssertFalse(status.changes.contains { $0.path == firstPath })

        try fixture.write("second\n", to: secondPath)
        try await service.addToGitIgnore(
            repository: fixture.url,
            selectedPath: secondPath,
            targetPath: "src/generated",
            isDirectory: true
        )

        XCTAssertEqual(
            try fixture.read(".gitignore"),
            "existing rule\n/src/generated/a\\ \\[x]\\*\\?.txt\n/src/generated/\n"
        )
        status = try await service.status(repository: fixture.url)
        XCTAssertFalse(status.changes.contains { $0.path == secondPath })
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
        XCTAssertFalse(rootNames.contains { $0.hasPrefix(".gitignore.Intreccio.") })
    }

    func testAddToGitIgnoreHandlesUntrackedNestedRepositoryAsDirectory() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("nested\n", to: "exampleexternalrepo/nested.txt")
        try fixture.git("-C", "exampleexternalrepo", "init", "-b", "main")
        let service = GitService()

        var status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.changes.contains { $0.path == "exampleexternalrepo/" })

        try await service.addToGitIgnore(
            repository: fixture.url,
            selectedPath: "exampleexternalrepo/",
            targetPath: "exampleexternalrepo",
            isDirectory: true
        )

        XCTAssertEqual(try fixture.read(".gitignore"), "/exampleexternalrepo/\n")
        XCTAssertEqual(try fixture.read("exampleexternalrepo/nested.txt"), "nested\n")
        status = try await service.status(repository: fixture.url)
        XCTAssertFalse(status.changes.contains { $0.path == "exampleexternalrepo/" })
    }

    func testAddToGitIgnoreCreatesFileWithoutTemporaryArtifacts() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("new\n", to: "new.txt")

        try await GitService().addToGitIgnore(
            repository: fixture.url,
            selectedPath: "new.txt",
            targetPath: "new.txt",
            isDirectory: false
        )

        XCTAssertEqual(try fixture.read(".gitignore"), "/new.txt\n")
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
        XCTAssertFalse(rootNames.contains { $0.hasPrefix(".gitignore.Intreccio.") })
    }

    func testAddToGitIgnoreUntracksModifiedFileAndPreservesWorktree() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.write("modified\n", to: "tracked.txt")

        try await GitService().addToGitIgnore(
            repository: fixture.url,
            selectedPath: "tracked.txt",
            targetPath: "tracked.txt",
            isDirectory: false
        )

        XCTAssertEqual(try fixture.read("tracked.txt"), "modified\n")
        XCTAssertEqual(try fixture.git("ls-files", "--", "tracked.txt").standardOutputText, "")
        XCTAssertEqual(try fixture.read(".gitignore"), "/tracked.txt\n")
        let status = try await GitService().status(repository: fixture.url)
        XCTAssertTrue(status.changes.contains { $0.path == "tracked.txt" && $0.hasStagedChange })
    }

    func testAddToGitIgnoreFolderUntracksUnchangedFilesInFolder() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "generated/changed.txt")
        try fixture.write("keep\n", to: "generated/unchanged.txt")
        try fixture.git("add", "--", "generated")
        try fixture.git("commit", "-m", "base")
        try fixture.write("modified\n", to: "generated/changed.txt")

        try await GitService().addToGitIgnore(
            repository: fixture.url,
            selectedPath: "generated/changed.txt",
            targetPath: "generated",
            isDirectory: true
        )

        XCTAssertEqual(try fixture.git("ls-files", "--", "generated").standardOutputText, "")
        XCTAssertEqual(try fixture.read("generated/changed.txt"), "modified\n")
        XCTAssertEqual(try fixture.read("generated/unchanged.txt"), "keep\n")
        XCTAssertEqual(try fixture.read(".gitignore"), "/generated/\n")
    }

    func testAddToGitIgnoreTreatsTrackedFilenameAsLiteralPathspec() async throws {
        let fixture = try GitFixture(testCase: self)
        let selectedPath = ":(glob)*.txt"
        try fixture.write("selected\n", to: selectedPath)
        try fixture.write("keep\n", to: "keep.txt")
        try fixture.git("--literal-pathspecs", "add", "--", selectedPath, "keep.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.write("modified\n", to: selectedPath)

        try await GitService().addToGitIgnore(
            repository: fixture.url,
            selectedPath: selectedPath,
            targetPath: selectedPath,
            isDirectory: false
        )

        XCTAssertEqual(try fixture.git("ls-files", "--", "keep.txt").standardOutputText, "keep.txt\n")
        XCTAssertEqual(
            try fixture.git("--literal-pathspecs", "ls-files", "--", selectedPath).standardOutputText,
            ""
        )
    }

    func testGitIgnoreRollbackPreservesConcurrentReplacement() throws {
        let fixture = try GitFixture(testCase: self)
        let receipt = try GitIgnoreWriter.append(pattern: "/new.txt", repository: fixture.url)
        try fixture.write("replacement\n", to: "replacement.tmp")
        _ = try FileManager.default.replaceItemAt(
            fixture.url.appendingPathComponent(".gitignore"),
            withItemAt: fixture.url.appendingPathComponent("replacement.tmp")
        )

        XCTAssertThrowsError(try GitIgnoreWriter.rollback(receipt, repository: fixture.url))
        XCTAssertEqual(try fixture.read(".gitignore"), "replacement\n")
    }

    func testGitIgnoreRollbackPreservesConcurrentInPlaceEdit() throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("# base\n", to: ".gitignore")
        let receipt = try GitIgnoreWriter.append(pattern: "/new.txt", repository: fixture.url)
        let handle = try FileHandle(forWritingTo: fixture.url.appendingPathComponent(".gitignore"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("external\n".utf8))
        try handle.close()

        XCTAssertThrowsError(try GitIgnoreWriter.rollback(receipt, repository: fixture.url))
        XCTAssertEqual(try fixture.read(".gitignore"), "# base\n/new.txt\nexternal\n")
    }

    func testAddToGitIgnoreRollsBackRuleWhenUntrackingFails() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "tracked.txt")
        try fixture.write("# keep\n", to: ".gitignore")
        try fixture.git("add", "--", "tracked.txt", ".gitignore")
        try fixture.git("commit", "-m", "base")
        try fixture.write("modified\n", to: "tracked.txt")
        try fixture.write("locked", to: ".git/index.lock")

        await XCTAssertThrowsErrorAsync(
            {
                try await GitService().addToGitIgnore(
                    repository: fixture.url,
                    selectedPath: "tracked.txt",
                    targetPath: "tracked.txt",
                    isDirectory: false
                )
            },
            assertError: { (error: GitRunnerError) in
                guard case .nonZeroExit(let result) = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
                XCTAssertNotEqual(result.exitCode, 0)
            }
        )

        XCTAssertEqual(try fixture.read(".gitignore"), "# keep\n")
        XCTAssertEqual(try fixture.read("tracked.txt"), "modified\n")
        XCTAssertEqual(try fixture.git("ls-files", "--", "tracked.txt").standardOutputText, "tracked.txt\n")
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
        XCTAssertFalse(rootNames.contains { $0.hasPrefix(".gitignore.Intreccio.") })
    }

    func testAddToGitIgnoreRejectsSymlinkWithoutChangingItsTarget() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("keep\n", to: "outside.txt")
        try fixture.write("untracked\n", to: "new.txt")
        try FileManager.default.createSymbolicLink(
            at: fixture.url.appendingPathComponent(".gitignore"),
            withDestinationURL: fixture.url.appendingPathComponent("outside.txt")
        )
        let service = GitService()

        do {
            try await service.addToGitIgnore(
                repository: fixture.url,
                selectedPath: "new.txt",
                targetPath: "new.txt",
                isDirectory: false
            )
            XCTFail("Expected symlink rejection")
        } catch let error as GitIgnoreWriterError {
            XCTAssertTrue(error.description.contains(".gitignore"))
        }
        XCTAssertEqual(try fixture.read("outside.txt"), "keep\n")
    }

}
