import Foundation
import XCTest
@testable import Intreccio

extension GitServiceIntegrationTests {
    func testCommitUsesMultilineMessageAndFailurePreservesIndex() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        let head = try await service.commit(repository: fixture.url, message: "subject\n\nbody line")
        XCTAssertFalse(head.isEmpty)
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%s%n%b").standardOutputText, "subject\nbody line\n\n")

        try fixture.write("next\n", to: "file.txt")
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        try fixture.git("config", "user.name", "")
        try fixture.git("config", "user.email", "")
        do {
            _ = try await service.commit(repository: fixture.url, message: "must remain")
            XCTFail("Expected identity failure")
        } catch let GitRunnerError.nonZeroExit(result) {
            XCTAssertFalse(result.standardErrorText.isEmpty)
        }
        let status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.changes.first { $0.path == "file.txt" }?.hasStagedChange == true)
    }

    func testAmendReplacesOnlyHeadAndRejectsStaleTarget() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let originalHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("amended\n", to: "file.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])

        let amendedHead = try await service.amend(
            repository: fixture.url,
            message: "amended subject\n\namended body",
            expectedHeadObjectID: originalHead
        )

        XCTAssertNotEqual(amendedHead, originalHead)
        XCTAssertEqual(try fixture.git("rev-list", "--count", "HEAD").standardOutputText, "1\n")
        XCTAssertEqual(
            try fixture.git("reflog", "-1", "--format=%H").standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines),
            amendedHead
        )
        XCTAssertEqual(try fixture.git("show", "HEAD:file.txt").standardOutputText, "amended\n")
        XCTAssertEqual(
            try fixture.git("log", "-1", "--format=%s%n%b").standardOutputText,
            "amended subject\namended body\n\n"
        )

        do {
            _ = try await service.amend(
                repository: fixture.url,
                message: "must not replace current HEAD",
                expectedHeadObjectID: originalHead
            )
            XCTFail("Expected stale amend target rejection")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .staleAmendTarget(expected: originalHead, actual: amendedHead))
        }
        XCTAssertEqual(
            try fixture.git("rev-parse", "HEAD").standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines),
            amendedHead
        )
    }

    func testAmendLocksHeadRefAgainstHookInterposition() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let originalHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git("commit", "--allow-empty", "-m", "external")
        let externalHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git("reset", "--hard", originalHead)
        try fixture.write("amended\n", to: "file.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        let realGitDirectory = fixture.url.appendingPathComponent(".git").path
        let workTree = fixture.url.path
        try fixture.write(
            "#!/bin/sh\ngit --git-dir=\"\(realGitDirectory)\" update-ref refs/heads/main \(externalHead) \(originalHead) >/dev/null 2>&1\nprintf '%s' \"$?\" > \"\(workTree)/hook-update-status\"\nexit 0\n",
            to: ".git/hooks/pre-commit"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.url.appendingPathComponent(".git/hooks/pre-commit").path
        )

        do {
            _ = try await service.amend(
                repository: fixture.url,
                message: "must not replace external",
                expectedHeadObjectID: originalHead
            )
            XCTFail("Expected stale reference failure")
        } catch let GitRunnerError.nonZeroExit(result) {
            XCTAssertFalse(result.standardErrorText.isEmpty)
        }

        XCTAssertEqual(try fixture.read("hook-update-status"), "0")
        XCTAssertEqual(
            try fixture.git("rev-parse", "HEAD").standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines),
            externalHead
        )
        let status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.changes.first { $0.path == "file.txt" }?.hasStagedChange == true)
    }

    func testAmendPreservesHookIndexMutationsAndBranchContext() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let originalHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("amended\n", to: "file.txt")
        try fixture.write("external\n", to: "external.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        let realGitDirectory = fixture.url.appendingPathComponent(".git").path
        let workTree = fixture.url.path
        try fixture.write(
            "#!/bin/sh\nbranch=$(git symbolic-ref --short HEAD)\nprintf '%s' \"$branch\" > \"\(workTree)/hook-branch\"\nenv -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE git --git-dir=\"\(realGitDirectory)\" --work-tree=\"\(workTree)\" add -- external.txt >/dev/null 2>&1\nprintf '%s' \"$?\" > \"\(workTree)/hook-index-status\"\n",
            to: ".git/hooks/pre-commit"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.url.appendingPathComponent(".git/hooks/pre-commit").path
        )

        _ = try await service.amend(
            repository: fixture.url,
            message: "amended",
            expectedHeadObjectID: originalHead
        )

        XCTAssertEqual(try fixture.read("hook-branch"), "main")
        XCTAssertEqual(try fixture.read("hook-index-status"), "0")
        XCTAssertEqual(try fixture.git("show", "HEAD:external.txt").standardOutputText, "external\n")
        let status = try await service.status(repository: fixture.url)
        XCTAssertNil(status.changes.first { $0.path == "external.txt" })
    }

    func testAmendHonorsBranchAwareHookPolicy() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let originalHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("amended\n", to: "file.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        try fixture.write("protected\n", to: ".git/protected-main")
        try fixture.write(
            "#!/bin/sh\ncommon=$(git rev-parse --git-common-dir)\nif [ \"$(git symbolic-ref --short HEAD)\" = main ] && [ -f \"$common/protected-main\" ]; then\n  printf 'main is protected\\n' >&2\n  exit 1\nfi\n",
            to: ".git/hooks/pre-commit"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.url.appendingPathComponent(".git/hooks/pre-commit").path
        )

        do {
            _ = try await service.amend(
                repository: fixture.url,
                message: "must be blocked",
                expectedHeadObjectID: originalHead
            )
            XCTFail("Expected branch policy failure")
        } catch let GitRunnerError.nonZeroExit(result) {
            XCTAssertEqual(result.standardErrorText, "main is protected\n")
        }

        XCTAssertEqual(
            try fixture.git("rev-parse", "HEAD").standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines),
            originalHead
        )
        let status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.changes.first { $0.path == "file.txt" }?.hasStagedChange == true)
    }

    func testAmendPreservesConfiguredHookContextAndReferenceHook() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let originalHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("amended\n", to: "file.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        let canonicalRepository = fixture.url.resolvingSymlinksInPath()
        let hooksDirectory = canonicalRepository.appendingPathComponent(".custom-'hooks", isDirectory: true)
        let realGitDirectory = canonicalRepository.appendingPathComponent(".git").path
        let workTree = canonicalRepository.path
        try fixture.git("config", "core.hooksPath", hooksDirectory.path)
        try fixture.write(
            "#!/bin/sh\nconfigured=$(git config --path core.hooksPath)\ncommon=$(git rev-parse --path-format=absolute --git-common-dir)\nprintf '%s\\n%s\\n' \"$configured\" \"$common\" > \"\(workTree)/hook-context-values\"\nprintf ok > \"\(workTree)/hook-context\"\n",
            to: ".custom-'hooks/pre-commit"
        )
        try fixture.write(
            "#!/bin/sh\nconfigured=$(git config --path core.hooksPath)\nprintf '%s\\n' \"$configured\" > \"\(workTree)/reference-context-value\"\nprintf '%s\\n' \"$1\" >> \"\(workTree)/reference-states\"\ncat >/dev/null\n",
            to: ".custom-'hooks/reference-transaction"
        )
        try fixture.write("must survive\n", to: ".custom-'hooks/reference-input")
        try fixture.write("must also survive\n", to: ".custom-'hooks/.gdc-reference-input")
        try fixture.write("helper must survive\n", to: ".custom-'hooks/pre-commit.gdc-original")
        for hook in ["pre-commit", "reference-transaction"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: hooksDirectory.appendingPathComponent(hook).path
            )
        }

        _ = try await service.amend(
            repository: fixture.url,
            message: "amended",
            expectedHeadObjectID: originalHead
        )

        XCTAssertEqual(try fixture.read("hook-context"), "ok")
        let contextValues = try fixture.read("hook-context-values").split(separator: "\n").map(String.init)
        XCTAssertEqual(contextValues.count, 2)
        XCTAssertEqual(URL(fileURLWithPath: contextValues[0]).resolvingSymlinksInPath(), hooksDirectory)
        XCTAssertEqual(URL(fileURLWithPath: contextValues[1]).resolvingSymlinksInPath().path, realGitDirectory)
        let referenceContext = try fixture.read("reference-context-value")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: referenceContext).resolvingSymlinksInPath(), hooksDirectory)
        let referenceStates = try fixture.read("reference-states")
        XCTAssertTrue(referenceStates.contains("prepared\n"))
        XCTAssertTrue(referenceStates.contains("committed\n"))
        XCTAssertEqual(try fixture.read(".custom-'hooks/reference-input"), "must survive\n")
        XCTAssertEqual(try fixture.read(".custom-'hooks/.gdc-reference-input"), "must also survive\n")
        XCTAssertEqual(try fixture.read(".custom-'hooks/pre-commit.gdc-original"), "helper must survive\n")
    }

    func testAmendSupportsDisabledHooksPath() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let originalHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("amended\n", to: "file.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        try fixture.git("config", "core.hooksPath", "/dev/null")

        let amendedHead = try await service.amend(
            repository: fixture.url,
            message: "amended",
            expectedHeadObjectID: originalHead
        )

        XCTAssertNotEqual(amendedHead, originalHead)
        XCTAssertEqual(try fixture.git("show", "HEAD:file.txt").standardOutputText, "amended\n")
    }

    func testAmendPreventsConcurrentHeadBranchSwitch() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let originalHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git("branch", "other")
        try fixture.write("amended\n", to: "file.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        let realGitDirectory = fixture.url.appendingPathComponent(".git").path
        let workTree = fixture.url.path
        try fixture.write(
            "#!/bin/sh\nenv -u GIT_DIR -u GIT_WORK_TREE git --git-dir=\"\(realGitDirectory)\" --work-tree=\"\(workTree)\" symbolic-ref HEAD refs/heads/other >/dev/null 2>&1\nprintf '%s' \"$?\" > \"\(workTree)/hook-switch-status\"\n",
            to: ".git/hooks/pre-commit"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.url.appendingPathComponent(".git/hooks/pre-commit").path
        )

        do {
            _ = try await service.amend(
                repository: fixture.url,
                message: "amended",
                expectedHeadObjectID: originalHead
            )
            XCTFail("Expected switched HEAD rejection")
        } catch let GitRunnerError.nonZeroExit(result) {
            XCTAssertTrue(result.standardErrorText.contains("Amend target changed"))
        }

        XCTAssertEqual(try fixture.read("hook-switch-status"), "0")
        XCTAssertEqual(try fixture.git("symbolic-ref", "--short", "HEAD").standardOutputText, "other\n")
        XCTAssertEqual(
            try fixture.git("rev-parse", "main").standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines),
            originalHead
        )
        XCTAssertEqual(
            try fixture.git("rev-parse", "other").standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines),
            originalHead
        )
        let status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.changes.first { $0.path == "file.txt" }?.hasStagedChange == true)
    }

    func testAmendDoesNotDeleteAnotherProcessIndexLock() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        let originalHead = try fixture.git("rev-parse", "HEAD").standardOutputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("amended\n", to: "file.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        let indexLock = fixture.url.appendingPathComponent(".git/index.lock")
        try Data("other process".utf8).write(to: indexLock)

        await XCTAssertThrowsErrorAsync(
            {
                _ = try await service.amend(
                    repository: fixture.url,
                    message: "must wait",
                    expectedHeadObjectID: originalHead
                )
            },
            assertError: { (error: GitRunnerError) in
                guard case .nonZeroExit = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            }
        )

        XCTAssertEqual(try String(contentsOf: indexLock, encoding: .utf8), "other process")
    }

    func testCancelledMutationWaitingForSlotDoesNotChangeRepository() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("new\n", to: "new.txt")
        let limiter = GitProcessLimiter(maximumConcurrent: 1)
        try await limiter.acquire(priority: .normal)
        let service = GitService(runner: GitRunner(limiter: limiter))
        let repositoryURL = fixture.url
        let task = Task { try await service.stage(repository: repositoryURL, paths: ["new.txt"]) }
        await Task.yield()
        task.cancel()
        await XCTAssertThrowsErrorAsync(
            { try await task.value },
            assertError: { (_: CancellationError) in }
        )
        await limiter.release()

        let status = try await GitService().status(repository: fixture.url)
        XCTAssertTrue(status.changes.first { $0.path == "new.txt" }?.kind == .untracked)
    }

    func testFailingHookReportsExactErrorAndRetainsHookIndexMutation() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.write("changed\n", to: "file.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        try fixture.write(
            "#!/bin/sh\nprintf 'hook-created\\n' > hook.txt\ngit add -- hook.txt\nprintf 'exact hook failure\\n' >&2\nexit 1\n",
            to: ".git/hooks/pre-commit"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.url.appendingPathComponent(".git/hooks/pre-commit").path
        )

        do {
            _ = try await service.commit(repository: fixture.url, message: "blocked")
            XCTFail("Expected hook failure")
        } catch let GitRunnerError.nonZeroExit(result) {
            XCTAssertEqual(result.standardErrorText, "exact hook failure\n")
        }
        let status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.changes.first { $0.path == "file.txt" }?.hasStagedChange == true)
        XCTAssertTrue(status.changes.first { $0.path == "hook.txt" }?.hasStagedChange == true)
    }

    func testActiveCommitCancellationKillsHookGroupAndPreservesRepository() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "file.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.write("staged\n", to: "file.txt")
        let service = GitService()
        try await service.stage(repository: fixture.url, paths: ["file.txt"])
        try fixture.write(
            "#!/bin/sh\nprintf started > hook-started\ntrap '' TERM\n( trap '' TERM; sleep 0.2; printf before-kill > hook-before-kill; sleep 2; printf after-kill > hook-after-kill ) &\nwait\n",
            to: ".git/hooks/pre-commit"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.url.appendingPathComponent(".git/hooks/pre-commit").path
        )
        let repositoryURL = fixture.url
        let task = Task { try await service.commit(repository: repositoryURL, message: "cancel me") }
        let hookStartedURL = fixture.url.appendingPathComponent("hook-started")
        try await waitUntil(
            timeout: .seconds(5),
            pollInterval: .milliseconds(20),
            description: "pre-commit hook start",
            condition: { @Sendable () async -> Bool in
                FileManager.default.fileExists(atPath: hookStartedURL.path)
            }
        )
        let cancellationStart = ContinuousClock.now
        task.cancel()
        await XCTAssertThrowsErrorAsync(
            { _ = try await task.value },
            assertError: { (error: GitRunnerError) in
                guard case .cancelled = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            }
        )
        XCTAssertGreaterThanOrEqual(cancellationStart.duration(to: .now), .milliseconds(900))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("hook-before-kill").path))
        try await Task.sleep(for: .seconds(2))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("hook-after-kill").path))
        XCTAssertEqual(try fixture.read("file.txt"), "staged\n")
        let status = try await service.status(repository: fixture.url)
        XCTAssertTrue(status.changes.first { $0.path == "file.txt" }?.hasStagedChange == true)
    }
}
