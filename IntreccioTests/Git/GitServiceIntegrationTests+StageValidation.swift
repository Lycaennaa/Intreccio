import Foundation
@testable import Intreccio
import XCTest

@MainActor
extension GitServiceIntegrationTests {
    func testStageRejectsConflictFromFreshStatus() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.git("checkout", "-b", "side")
        try fixture.write("side\n", to: "file.txt")
        try fixture.git("commit", "-am", "side")
        try fixture.git("checkout", "main")
        try fixture.write("main\n", to: "file.txt")
        try fixture.git("commit", "-am", "main")
        XCTAssertThrowsError(try fixture.git("merge", "side"))
        let service = GitService()

        do {
            try await service.stage(repository: fixture.url, paths: ["file.txt"])
            XCTFail("Expected conflict rejection")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .conflictedPaths(["file.txt"]))
        }
    }

    func testValidatedMutationPathsPreservesRenameSourcesAndRejectsStaleSelection() async throws {
        let service = GitService()
        var status = RepoStatus()
        status.changes = [FileChange(
            path: "new.txt",
            originalPath: "old.txt",
            indexState: .renamed,
            worktreeState: .renamed,
            kind: .renamed,
            submoduleState: nil
        )]

        let paths = try await service.validatedMutationPaths(
            requestedPaths: ["new.txt"],
            status: status,
            requireStaged: false,
            rejectConflicts: true
        )
        XCTAssertEqual(paths, ["new.txt", "old.txt"])

        do {
            _ = try await service.validatedMutationPaths(
                requestedPaths: ["missing.txt"],
                status: status,
                requireStaged: false,
                rejectConflicts: true
            )
            XCTFail("Expected stale selection rejection")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .staleMutationSelection(["missing.txt"]))
        }
    }

}
