import Foundation
@testable import Intreccio
import XCTest

final class GitServiceHistoryQueryTests: XCTestCase {
    private func selectedCommitFixture() -> Commit {
        Commit(
            objectID: String(repeating: "a", count: 40),
            parentIDs: [String(repeating: "b", count: 40)],
            authorName: "Alice",
            authorEmail: "alice@example.com",
            authoredAt: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "selected",
            body: ""
        )
    }

    private func patchFixture() -> Data {
        var patch = Data("""
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old
        +new
        """.utf8)
        patch.append(0x0A)
        return patch
    }

    func testHistoryTipsBatchesNormalHeadAndUpstreamRefsInBoundedQuery() async throws {
        let localObjectID = String(repeating: "a", count: 40)
        let upstreamObjectID = String(repeating: "b", count: 40)
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(
                output: "\(localObjectID)\0refs/remotes/origin/main\0\(upstreamObjectID)\n"
            ))
        ])

        let tips = try await GitService(runner: runner).historyTips(
            repository: URL(fileURLWithPath: "/repository")
        )

        XCTAssertEqual(tips, HistoryTips(localObjectID: localObjectID, upstreamObjectID: upstreamObjectID))
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].arguments, ["symbolic-ref", "--quiet", "HEAD"])
        XCTAssertEqual(
            invocations[1].arguments,
            [
                "for-each-ref",
                "--format=%(objectname)%00%(upstream)%00%(upstream:objectname)",
                "--count=1",
                "refs/heads/main"
            ]
        )
        XCTAssertEqual(invocations[0].acceptedExitCodes, [0, 1])
        XCTAssertEqual(invocations[1].acceptedExitCodes, [0])
        XCTAssertEqual(invocations[1].outputLimit, 2 * 1_024)
        XCTAssertEqual(invocations[0].outputLimit, 2 * 1_024)
    }

    func testHistoryTipsPreservesDetachedAndUnbornSemantics() async throws {
        let detachedHead = String(repeating: "c", count: 40)
        let detachedRunner = RecordingGitRunner(responses: [
            .result(recordedGitResult(exitCode: 1)),
            .result(recordedGitResult(output: "\(detachedHead)\n"))
        ])
        let detachedTips = try await GitService(runner: detachedRunner).historyTips(
            repository: URL(fileURLWithPath: "/detached")
        )

        XCTAssertEqual(detachedTips, HistoryTips(localObjectID: detachedHead, upstreamObjectID: nil))
        let detachedInvocations = await detachedRunner.invocations
        XCTAssertEqual(detachedInvocations.count, 2)
        XCTAssertEqual(
            detachedInvocations[1].arguments,
            ["rev-parse", "--verify", "--quiet", "HEAD"]
        )

        let unbornRunner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult())
        ])
        let unbornTips = try await GitService(runner: unbornRunner).historyTips(
            repository: URL(fileURLWithPath: "/unborn")
        )

        XCTAssertEqual(unbornTips, HistoryTips(localObjectID: nil, upstreamObjectID: nil))
        let unbornInvocations = await unbornRunner.invocations
        XCTAssertEqual(unbornInvocations.count, 2)
    }

    func testHistoryTipsTreatsUnsupportedAndMissingUpstreamAsAbsent() async throws {
        let localObjectID = String(repeating: "d", count: 40)
        let upstreamObjectID = String(repeating: "e", count: 40)
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(
                output: "\(localObjectID)\0refs/heads/other\0\(upstreamObjectID)\n"
            ))
        ])

        let unsupportedTips = try await GitService(runner: runner).historyTips(
            repository: URL(fileURLWithPath: "/unsupported-upstream")
        )
        XCTAssertEqual(unsupportedTips, HistoryTips(localObjectID: localObjectID, upstreamObjectID: nil))

        let missingRunner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "refs/heads/main\n")),
            .result(recordedGitResult(output: "\(localObjectID)\0\0\n"))
        ])
        let missingTips = try await GitService(runner: missingRunner).historyTips(
            repository: URL(fileURLWithPath: "/missing-upstream")
        )
        XCTAssertEqual(missingTips, HistoryTips(localObjectID: localObjectID, upstreamObjectID: nil))
    }

    func testHistoryTipsPropagatesRefQueryFailure() async throws {
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(error: "fatal", exitCode: 128))
        ])

        do {
            _ = try await GitService(runner: runner).historyTips(
                repository: URL(fileURLWithPath: "/failed")
            )
            XCTFail("Expected symbolic HEAD query failure")
        } catch let GitRunnerError.nonZeroExit(result) {
            XCTAssertEqual(result.exitCode, 128)
            XCTAssertEqual(result.standardErrorText, "fatal")
        }
    }
    func testHistoryPageSurfacesPartialLengthFramedMetadata() async throws {
        let objectID = String(repeating: "a", count: 40)
        let object = Data(([
            "tree 0123456789012345678901234567890123456789",
            "author Alice <alice@example.com> 1700000000 +0000",
            "committer Alice <alice@example.com> 1700000000 +0000",
            "",
            "subject",
            "",
            "body that is cut"
        ].joined(separator: "\n")).utf8)
        let header = Data("\(objectID) commit \(object.count)\n".utf8)
        let partialOutput = header + Data(object.prefix(object.count - 4))
        let partialResult = ProcessCommandResult(
            exitCode: 0,
            standardOutput: partialOutput,
            standardError: Data()
        )
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "\(objectID)\0")),
            .failure(.outputLimitExceeded(
                stream: .standardOutput,
                limit: partialOutput.count,
                result: partialResult
            ))
        ])

        let page = try await GitService(runner: runner).historyPage(
            repository: URL(fileURLWithPath: "/repository"),
            scope: .mixed,
            tips: HistoryTips(localObjectID: objectID, upstreamObjectID: nil)
        )

        XCTAssertEqual(page.commits.count, 1)
        XCTAssertNil(page.omittedCommitCount)
        guard case .truncated = page.completeness else {
            return XCTFail("Expected explicit partial metadata state")
        }
        guard case .truncated = page.commits[0].bodyMetadata.completeness else {
            return XCTFail("Expected explicit partial body state")
        }
    }
    func testShowLoadsPatchWhenCommitMetadataIsUnavailable() async throws {
        let selectedCommit = selectedCommitFixture()
        let patch = patchFixture()
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "not-a-frame\n")),
            .result(recordedGitResult(output: "M\0file.txt\0")),
            .result(recordedGitResult(output: String(decoding: patch, as: UTF8.self)))
        ])

        let details = try await GitService(runner: runner).show(
            repository: URL(fileURLWithPath: "/repository"),
            commit: selectedCommit
        )

        XCTAssertEqual(details.commit, selectedCommit)
        XCTAssertEqual(details.rawPatch.bytes, patch)
        XCTAssertEqual(details.diff.files.map(\.path), ["file.txt"])
        XCTAssertEqual(details.metadata.changedFiles.files.map(\.path), ["file.txt"])
        XCTAssertEqual(details.metadata.changedFiles.completeness, .unavailable)
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 3)
        XCTAssertEqual(invocations[0].arguments, ["cat-file", "--batch"])
        XCTAssertEqual(invocations[1].arguments.first, "diff")
        XCTAssertEqual(invocations[2].arguments.first, "show")
    }
    func testShowLoadsPatchWhenMetadataCommandFails() async throws {
        let selectedCommit = selectedCommitFixture()
        let patch = patchFixture()
        let runner = RecordingGitRunner(responses: [
            .failure(.nonZeroExit(recordedGitResult(error: "metadata unavailable", exitCode: 128))),
            .result(recordedGitResult(output: "M\0file.txt\0")),
            .result(recordedGitResult(output: String(decoding: patch, as: UTF8.self)))
        ])

        let details = try await GitService(runner: runner).show(
            repository: URL(fileURLWithPath: "/repository"),
            commit: selectedCommit
        )

        XCTAssertEqual(details.commit.objectID, selectedCommit.objectID)
        XCTAssertEqual(details.rawPatch.bytes, patch)
        XCTAssertEqual(details.diff.files.map(\.path), ["file.txt"])
        XCTAssertEqual(details.metadata.completeness, .unavailable)
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 3)
    }

    func testShowLoadsPatchWhenChangedFileSummaryFails() async throws {
        let selectedCommit = selectedCommitFixture()
        let patch = patchFixture()
        let metadata = historyBatchRecord(objectID: selectedCommit.objectID, parentID: selectedCommit.parentIDs.first, subject: selectedCommit.subject)
        let runner = RecordingGitRunner(responses: [
            .result(.init(exitCode: 0, standardOutput: metadata, standardError: Data())),
            .failure(.nonZeroExit(recordedGitResult(error: "summary unavailable", exitCode: 128))),
            .result(recordedGitResult(output: String(decoding: patch, as: UTF8.self)))
        ])

        let details = try await GitService(runner: runner).show(
            repository: URL(fileURLWithPath: "/repository"),
            commit: selectedCommit
        )

        XCTAssertEqual(details.commit.objectID, selectedCommit.objectID)
        XCTAssertEqual(details.rawPatch.bytes, patch)
        XCTAssertEqual(details.diff.files.map(\.path), ["file.txt"])
        XCTAssertEqual(details.metadata.changedFiles.completeness, .unavailable)
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 3)
    }

    func testShowNormalizesCancelledPatch() async {
        let selectedCommit = selectedCommitFixture()
        let metadata = historyBatchRecord(objectID: selectedCommit.objectID, parentID: selectedCommit.parentIDs.first, subject: selectedCommit.subject)
        let runner = RecordingGitRunner(responses: [
            .result(.init(exitCode: 0, standardOutput: metadata, standardError: Data())),
            .result(recordedGitResult(output: "M\0file.txt\0")),
            .failure(.cancelled(recordedGitResult(exitCode: -1)))
        ])

        do {
            _ = try await GitService(runner: runner).show(
                repository: URL(fileURLWithPath: "/repository"),
                commit: selectedCommit
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testShowNormalizesCancelledRootComparisonLookup() async {
        let rootCommit = Commit(
            objectID: String(repeating: "a", count: 40),
            parentIDs: [],
            authorName: "Alice",
            authorEmail: "alice@example.com",
            authoredAt: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "root",
            body: ""
        )
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "not-a-frame\n")),
            .failure(.cancelled(recordedGitResult(exitCode: -1)))
        ])

        do {
            _ = try await GitService(runner: runner).show(
                repository: URL(fileURLWithPath: "/repository"),
                commit: rootCommit
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testHistoryPageKeepsValidCommitAfterMissingObject() async throws {
        let missingID = String(repeating: "c", count: 40)
        let validID = String(repeating: "d", count: 40)
        let object = Data(([
            "tree 0123456789012345678901234567890123456789",
            "author Alice <alice@example.com> 1700000000 +0000",
            "committer Alice <alice@example.com> 1700000000 +0000",
            "",
            "subject"
        ].joined(separator: "\n")).utf8)
        let validFrame = Data("\(validID) commit \(object.count)\n".utf8) + object + Data([0x0A])
        let runner = RecordingGitRunner(responses: [
            .result(recordedGitResult(output: "\(missingID)\0\(validID)\0")),
            .result(ProcessCommandResult(
                exitCode: 0,
                standardOutput: Data("\(missingID) missing\n".utf8) + validFrame,
                standardError: Data()
            ))
        ])

        let page = try await GitService(runner: runner).historyPage(
            repository: URL(fileURLWithPath: "/repository"),
            scope: .mixed,
            tips: HistoryTips(localObjectID: validID, upstreamObjectID: nil)
        )

        XCTAssertEqual(page.commits.map(\.objectID), [validID])
        XCTAssertEqual(page.unavailableCommitCount, 1)
        XCTAssertEqual(page.completeness, .unavailable)
    }
}
