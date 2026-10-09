import Foundation
@testable import Intreccio
import XCTest

extension GitRunnerTests {
    func testDiscardingExcessOutputLetsFinishAfterLaunchProcessComplete() async throws {
        let directory = try makeTestDirectory()
        let completed = directory.appendingPathComponent("completed")
        let alias = "!f() { head -c 128 /dev/zero | tr '\\000' x; "
            + "head -c 128 /dev/zero | tr '\\000' y >&2; "
            + "printf complete > \(completed.path); }; f"
        let request = ProcessExecutionRequest(
            repository: nil,
            arguments: ["-c", "alias.noisy=\(alias)", "noisy"],
            input: nil,
            environment: [:],
            acceptedExitCodes: [0],
            outputLimit: 16,
            priority: .normal,
            cancellationBehavior: .finishAfterLaunch,
            outputLimitBehavior: .discardExcess
        )

        let result = try await GitRunner().executeWithoutTimeout(request)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.count, 16)
        XCTAssertEqual(result.standardError.count, 16)
        XCTAssertEqual(try String(contentsOf: completed, encoding: .utf8), "complete")
    }
}
