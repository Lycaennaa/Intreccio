import Foundation
@testable import Intreccio
import XCTest

final class GitHubCLITests: XCTestCase {
    func testListsAuthenticatedRepositoriesAndSortsNames() async throws {
        let privateRepository = try XCTUnwrap(
            String(
                data: try JSONSerialization.data(withJSONObject: [
                    "nameWithOwner": "octo/private",
                    "description": "Private work",
                    "isPrivate": true,
                    "url": "https://github.com/octo/private"
                ], options: [.sortedKeys]),
                encoding: .utf8
            )
        )
        let publicRepository = try XCTUnwrap(
            String(
                data: try JSONSerialization.data(withJSONObject: [
                    "nameWithOwner": "octo/public",
                    "description": NSNull(),
                    "isPrivate": false,
                    "url": "https://github.com/octo/public"
                ], options: [.sortedKeys]),
                encoding: .utf8
            )
        )
        let encodedPublicRepository = try XCTUnwrap(
            String(data: try JSONEncoder().encode(publicRepository), encoding: .utf8)
        )
        let output = [privateRepository, encodedPublicRepository].joined(separator: "\n") + "\n"
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult()),
            .result(recordedGitResult(output: output))
        ])

        let repositories = try await GitHubCLI(executableURL: nil, runner: runner).repositories()

        XCTAssertEqual(repositories.map(\.nameWithOwner), ["octo/private", "octo/public"])
        XCTAssertTrue(repositories[0].isPrivate)
        XCTAssertEqual(repositories[0].cloneURL, URL(string: "https://github.com/octo/private.git"))
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.map(\.arguments), [
            ["auth", "status", "--hostname", "github.com"],
            [
                "api",
                "--paginate",
                "--jq",
                ".[] | {nameWithOwner: .full_name, description: .description, "
                    + "isPrivate: .private, url: .html_url} | @json",
                "user/repos"
            ]
        ])
    }

    func testUnauthenticatedCLIDoesNotRequestRepositoryList() async {
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(error: "not logged in", exitCode: 1))
        ])

        do {
            _ = try await GitHubCLI(executableURL: nil, runner: runner).repositories()
            XCTFail("Expected an unauthenticated result")
        } catch {
            XCTAssertEqual(error as? GitHubCLIError, .notAuthenticated)
        }

        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 1)
    }

    func testMissingCLIExplainsTerminalLogin() async {
        do {
            _ = try await GitHubCLI(executableURL: nil).repositories()
            XCTFail("Expected a missing CLI result")
        } catch {
            XCTAssertEqual(
                error as? GitHubCLIError,
                .notInstalled
            )
        }
    }

    func testGitCredentialHelperIsScopedToChildProcessEnvironment() {
        let executable = URL(fileURLWithPath: "/Tools with spaces/gh")
        let environment = GitHubCLIExecutable.gitCredentialEnvironment(
            executableURL: executable,
            inheritedEnvironment: ["PATH": "/usr/bin", "GIT_CONFIG_COUNT": "2"]
        )

        XCTAssertEqual(environment["GIT_CONFIG_COUNT"], "3")
        XCTAssertEqual(environment["GIT_CONFIG_KEY_2"], "credential.helper")
        XCTAssertEqual(environment["GIT_CONFIG_VALUE_2"], "!'/Tools with spaces/gh' auth git-credential")
        XCTAssertEqual(environment["PATH"], "/Tools with spaces:/usr/bin")
    }

    func testRepositoryPickerBoundsCloneBatches() {
        XCTAssertFalse(GitHubRepositorySelectionPolicy.canClone(count: 0))
        XCTAssertTrue(GitHubRepositorySelectionPolicy.canClone(count: 1))
        XCTAssertTrue(GitHubRepositorySelectionPolicy.canClone(
            count: GitHubRepositorySelectionPolicy.maximumSelectionCount
        ))
        XCTAssertFalse(GitHubRepositorySelectionPolicy.canClone(
            count: GitHubRepositorySelectionPolicy.maximumSelectionCount + 1
        ))
    }
}
