import Foundation
import XCTest
@testable import Intreccio

final class GitHubRepositoryURLTests: XCTestCase {
    func testConvertsSupportedGitHubRemoteForms() {
        let expected = URL(string: "https://github.com/octo/repo")
        let remotes = [
            "git@github.com:octo/repo.git",
            "https://github.com/octo/repo.git",
            "ssh://git@github.com/octo/repo.git",
            "www.github.com:octo/repo.git",
        ]

        for remote in remotes {
            XCTAssertEqual(GitHubRepositoryURL.webURL(from: remote), expected, remote)
        }
    }

    func testRejectsNonGitHubAndUnsafeRemoteForms() {
        let remotes = [
            "git@gitlab.com:octo/repo.git",
            "https://github.example.com/octo/repo.git",
            "https://github.com/octo/repo.git?token=secret",
            "git@github.com:octo/repo.git/extra",
            "https://github.com/octo/../repo.git",
        ]

        for remote in remotes {
            XCTAssertNil(GitHubRepositoryURL.webURL(from: remote), remote)
        }
    }
}