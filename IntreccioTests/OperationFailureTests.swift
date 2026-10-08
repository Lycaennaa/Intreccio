@testable import Intreccio
import XCTest

final class OperationFailureTests: XCTestCase {
    func testGitFailurePreservesExactDetailsAndProvidesActionableCopyText() {
        let stderr = "Author identity unknown\nRun git config user.email"
        let result = ProcessCommandResult(
            exitCode: 128,
            standardOutput: Data(),
            standardError: Data(stderr.utf8)
        )

        let failure = OperationFailure.git(
            ProcessRunnerError.nonZeroExit(result),
            title: "Could not commit changes"
        )

        XCTAssertEqual(failure.title, "Could not commit changes")
        XCTAssertTrue(failure.recoverySuggestion.contains("name and email"))
        XCTAssertTrue(failure.details.contains(stderr))
        XCTAssertTrue(failure.copyText.contains("Git exited with status 128"))
    }
}
