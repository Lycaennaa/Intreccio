import Foundation
import XCTest
@testable import Intreccio

final class DiffPresentationModelTests: XCTestCase {
    func testInvalidGitPathPreservesBytesAndEscapedDisplay() {
        let path = GitPath(bytes: Data([0x66, 0xFF, 0x2E, 0x74, 0x78, 0x74]))

        XCTAssertTrue(path.isLossy)
        XCTAssertFalse(path.isAddressable)
        XCTAssertEqual(path.displayString, "f\\xFF.txt")
        XCTAssertEqual(path.bytes, Data([0x66, 0xFF, 0x2E, 0x74, 0x78, 0x74]))
    }

    func testContentIdentityUsesRawGitPathKeys() {
        let repositoryID = UUID()
        let firstPath = GitPath(bytes: Data([0x62, 0x61, 0x64, 0xFF, 0x2E, 0x74, 0x78, 0x74]))
        let secondPath = GitPath(bytes: Data([0x62, 0x61, 0x64, 0xFE, 0x2E, 0x74, 0x78, 0x74]))

        let first = DiffContentIdentity.changes(
            repositoryID: repositoryID,
            kind: .unstaged,
            paths: [firstPath],
            fileID: nil
        )
        let second = DiffContentIdentity.changes(
            repositoryID: repositoryID,
            kind: .unstaged,
            paths: [secondPath],
            fileID: nil
        )

        XCTAssertNotEqual(first, second)
    }
    func testGitAddressabilityRejectsLossyRenameSource() {
        let change = FileChange(
            gitPath: GitPath("new.txt"),
            originalGitPath: GitPath(bytes: Data([0x6F, 0x6C, 0x64, 0xFF, 0x2E, 0x74, 0x78, 0x74])),
            indexState: .renamed,
            worktreeState: .unmodified,
            kind: .renamed,
            submoduleState: nil
        )

        XCTAssertTrue(change.isPathLossy)
        XCTAssertFalse(change.isGitAddressable)
    }
    func testPhase0BudgetsRemainExplicit() {
        XCTAssertEqual(DiffLimits.render.maximumBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(DiffLimits.render.maximumLines, 20_000)
        XCTAssertEqual(HistoryMetadataLimits.default.maximumBodyBytes, 256 * 1_024)
        XCTAssertEqual(HistoryMetadataLimits.default.maximumBodyLines, 4_096)
        XCTAssertEqual(HistoryMetadataLimits.default.maximumTransportBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(HistoryMetadataLimits.default.maximumSummaryFiles, 4_096)
        XCTAssertEqual(HistoryMetadataLimits.default.maximumSummaryBytes, 512 * 1_024)
    }



    func testPresentationModelPreservesOrderStatsAndSnapshotScope() throws {
        let first = DiffFile(
            path: "first.swift",
            originalPath: nil,
            change: .added,
            content: .text([DiffHunk(
                oldRange: DiffRange(start: 0, count: 0),
                newRange: DiffRange(start: 1, count: 1),
                heading: nil,
                lines: [DiffLine(
                    kind: .addition,
                    text: "let first = true",
                    oldLineNumber: nil,
                    newLineNumber: 1,
                    hasTrailingNewline: true,
                    tokens: []
                )]
            )])
        )
        let second = DiffFile(
            path: "second.swift",
            originalPath: nil,
            change: .modified,
            content: .binary(byteCount: 3)
        )
        let raw = Data("native patch".utf8)
        let diff = GitDiff(
            files: [first, second],
            fallback: nil,
            sourceByteCount: raw.count,
            sourceLineCount: 1,
            rawPatch: .git(GitRawOutput(bytes: raw))
        )
        let snapshot = DiffSnapshotID(repositoryID: UUID(), revision: UUID())
        let model = DiffPresentationModel(diff: diff, snapshotID: snapshot)

        XCTAssertEqual(model.files.map(\.displayPath), ["first.swift", "second.swift"])
        XCTAssertEqual(model.files[0].header.stats, DiffPresentationLineStats(additions: 1, deletions: 0))
        XCTAssertEqual(model.stats, .unavailable)
        XCTAssertEqual(model.rawPatch.exactGitBytes, raw)
        XCTAssertEqual(model.files(for: .allFiles).count, 2)
        XCTAssertEqual(model.files(for: .focused(model.files[1].id)).count, 1)
        XCTAssertTrue(model.files(for: .focused(model.files[1].id)).allSatisfy { $0.id == model.files[1].id })

        let refreshed = DiffPresentationModel(
            diff: diff,
            snapshotID: DiffSnapshotID(repositoryID: snapshot.repositoryID, revision: UUID())
        )
        XCTAssertNil(refreshed.file(with: model.files[0].id))
        XCTAssertEqual(model.files[0].id, DiffFileID(snapshotID: snapshot, ordinal: 0))
    }

    func testFallbackAndSyntheticOutputNeverClaimExactGitBytes() {
        let summary = DiffFileSummary(path: "large.txt", originalPath: nil, change: .modified)
        let fallback = GitDiff(
            files: [],
            fallback: DiffFallback(reason: .byteLimit(10), files: [summary]),
            sourceByteCount: 11,
            sourceLineCount: 1,
            rawPatch: .mixed(GitRawOutput(
                bytes: Data("partial".utf8),
                completeness: .truncated(limit: 10)
            ))
        )
        let model = DiffPresentationModel(diff: fallback, repositoryID: UUID())

        XCTAssertEqual(model.state, .aggregateFallback(.byteLimit(10)))
        XCTAssertEqual(model.stats, .unavailable)
        XCTAssertNil(model.rawPatch.exactGitBytes)
        XCTAssertEqual(model.files.first?.state, .aggregateFallback(.byteLimit(10)))
    }

    func testLengthAwareCommitBatchToleratesNULAndFramingText() throws {
        let object = Data(([
            "tree 0123456789012345678901234567890123456789",
            "author Alice <alice@example.com> 1700000000 +0000",
            "committer Alice <alice@example.com> 1700000000 +0000",
            "",
            "subject\0GDC-END",
            "",
            "body\0tail",
        ].joined(separator: "\n")).utf8)
        let frame = Data("0123456789012345678901234567890123456789 commit \(object.count)\n".utf8)
            + object
            + Data([0x0A])

        let result = CommitBatchParser.parse(frame)
        let commit = try XCTUnwrap(result.commits.first)
        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(commit.subject, "subject\0GDC-END")
        XCTAssertEqual(commit.body, "body\0tail")
        XCTAssertTrue(commit.bodyMetadata.completeness.isComplete)
    }

    func testLengthAwareCommitBatchReportsPartialFinalRecord() throws {
        let object = Data(([
            "tree 0123456789012345678901234567890123456789",
            "author Alice <alice@example.com> 1700000000 +0000",
            "committer Alice <alice@example.com> 1700000000 +0000",
            "",
            "subject",
            "",
            "body that is longer",
        ].joined(separator: "\n")).utf8)
        let header = Data("0123456789012345678901234567890123456789 commit \(object.count)\n".utf8)
        let partial = header + Data(object.prefix(object.count - 5))

        let result = CommitBatchParser.parse(
            partial,
            transportCompleteness: .truncated(limit: partial.count)
        )
        let commit = try XCTUnwrap(result.commits.first)
        guard case .truncated = result.completeness else {
            return XCTFail("Expected partial transport state")
        }
        guard case .truncated = commit.bodyMetadata.completeness else {
            return XCTFail("Expected partial body state")
        }
    }

    func testUnifiedParserDecodesQuotedOctalPathBytes() throws {
        let patch = """
        diff --git "a/bad\\377.txt" "b/bad\\377.txt"
        --- "a/bad\\377.txt"
        +++ "b/bad\\377.txt"
        @@ -0,0 +1,1 @@
        +value

        """

        let file = try XCTUnwrap(UnifiedDiffParser.parse(Data(patch.utf8)).files.first)
        XCTAssertEqual(file.gitPath.bytes, Data([0x62, 0x61, 0x64, 0xFF, 0x2E, 0x74, 0x78, 0x74]))
        XCTAssertTrue(file.gitPath.isLossy)
        XCTAssertEqual(file.displayPath, "bad\\xFF.txt")
        XCTAssertFalse(file.gitPath.isAddressable)
    }
    func testSummaryMetadataPreservesRawPathsAndOmittedCount() {
        var data = Data()
        data.append(contentsOf: [UInt8]([65]))
        data.append(0)
        data.append(contentsOf: Data("first.txt".utf8))
        data.append(0)
        data.append(contentsOf: [UInt8]([82]))
        data.append(0)
        data.append(contentsOf: Data("old.txt".utf8))
        data.append(0)
        data.append(contentsOf: Data([0x6E, 0x65, 0x77, 0xFF]))
        data.append(0)

        let limits = HistoryMetadataLimits(
            maximumBodyBytes: 100,
            maximumBodyLines: 10,
            maximumTransportBytes: 1_000,
            maximumSummaryFiles: 1,
            maximumSummaryBytes: 1_000
        )
        let result = DiffSummaryMetadataParser.parse(data, limits: limits)

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].path, "first.txt")
        XCTAssertEqual(result.omittedFileCount, 1)
        guard case .truncated = result.completeness else {
            return XCTFail("Expected summary truncation")
        }
        XCTAssertEqual(result.files[0].gitPath.bytes, Data("first.txt".utf8))
    }

    func testSummaryMetadataMarksIncompleteRecordWithoutInventingFile() {
        let data = Data([65, 0] + Array("partial".utf8))
        let result = DiffSummaryMetadataParser.parse(data)

        XCTAssertTrue(result.files.isEmpty)
        XCTAssertNil(result.omittedFileCount)
        guard case .truncated = result.completeness else {
            return XCTFail("Expected incomplete summary state")
        }
    }
    func testPresentationModelKeepsExplicitLimitedAndUnavailableStates() {
        let contents: [DiffFileContent] = [
            .binary(byteCount: 12),
            .oversized(reason: .byteLimit(maximumBytes: 10), byteCount: 11),
            .oversized(reason: .lineLimit(maximumLines: 10), byteCount: 11),
            .oversized(reason: .estimatedRenderSizeLimit(maximumBytes: 10), byteCount: 8),
            .unavailable(.changedDuringRead),
            .conflicted(statusX: .unmodified, statusY: .modified),
        ]
        let files = contents.enumerated().map { index, content in
            DiffFile(
                path: "file\(index).txt",
                originalPath: nil,
                change: .modified,
                content: content
            )
        }
        let model = DiffPresentationModel(
            diff: GitDiff(files: files, fallback: nil, sourceByteCount: 1, sourceLineCount: 1),
            repositoryID: UUID()
        )

        XCTAssertEqual(model.files.count, contents.count)
        XCTAssertEqual(model.stats, .unavailable)
        XCTAssertEqual(model.state, .partial(unavailableFileCount: 1, oversizedFileCount: 3))
        XCTAssertEqual(model.files[1].header.stats, .unavailable)
        XCTAssertEqual(model.files[4].state, .content(.unavailable(.changedDuringRead)))
    }
    func testAggregateFallbackRetainsRenderedSiblingFiles() {
        let rendered = DiffFile(
            path: "visible.txt",
            originalPath: nil,
            change: .modified,
            content: .text([])
        )
        let missing = DiffFileSummary(path: "missing.txt", originalPath: nil, change: .modified)
        let diff = GitDiff(
            files: [rendered],
            fallback: DiffFallback(reason: .byteLimit(10), files: [missing]),
            sourceByteCount: 11,
            sourceLineCount: 1,
            rawPatch: .mixed(GitRawOutput(bytes: Data("tracked".utf8)))
        )
        let model = DiffPresentationModel(diff: diff, repositoryID: UUID())

        XCTAssertEqual(model.files.map(\.displayPath), ["visible.txt", "missing.txt"])
        XCTAssertEqual(model.files[0].state, .content(.text([])))
        XCTAssertEqual(model.files[1].state, .aggregateFallback(.byteLimit(10)))
        XCTAssertEqual(model.state, .aggregateFallback(.byteLimit(10)))
    }
    func testBatchParserKeepsValidRecordsAfterMissingObjectFrame() throws {
        let objectID = String(repeating: "b", count: 40)
        let object = Data(([
            "tree 0123456789012345678901234567890123456789",
            "author Alice <alice@example.com> 1700000000 +0000",
            "committer Alice <alice@example.com> 1700000000 +0000",
            "",
            "subject",
        ].joined(separator: "\n")).utf8)
        let validFrame = Data("\(objectID) commit \(object.count)\n".utf8) + object + Data([0x0A])
        let result = CommitBatchParser.parse(Data("missing-object missing\n".utf8) + validFrame)

        XCTAssertEqual(result.commits.count, 1)
        XCTAssertEqual(result.unavailableCommitCount, 1)
        XCTAssertEqual(result.commits[0].objectID, objectID)
        XCTAssertEqual(result.completeness, .unavailable)
    }
    func testTruncatedRawPatchCannotAppearComplete() {
        let patch = """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old
        +new

        """
        let diff = UnifiedDiffParser.parse(
            Data(patch.utf8),
            rawCompleteness: .truncated(limit: patch.utf8.count)
        )

        XCTAssertEqual(diff.files.count, 1)
        XCTAssertEqual(diff.fallback?.reason, .truncated)
        XCTAssertNil(diff.exactRawPatch)
    }

    func testParserRetainsFileModeMetadata() throws {
        let patch = """
        diff --git a/script b/script
        old mode 100644
        new mode 100755

        """
        let file = try XCTUnwrap(UnifiedDiffParser.parse(Data(patch.utf8)).files.first)

        XCTAssertEqual(file.oldMode, "100644")
        XCTAssertEqual(file.newMode, "100755")
    }

    func testParserDecodesCStyleControlPathEscapes() throws {
        let patch = """
        diff --git "a/bell\\a.txt" "b/bell\\a.txt"
        --- "a/bell\\a.txt"
        +++ "b/bell\\a.txt"
        @@ -0,0 +1,1 @@
        +value

        """
        let file = try XCTUnwrap(UnifiedDiffParser.parse(Data(patch.utf8)).files.first)

        XCTAssertEqual(file.gitPath.bytes, Data([0x62, 0x65, 0x6C, 0x6C, 0x07, 0x2E, 0x74, 0x78, 0x74]))
    }
 }