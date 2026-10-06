import Foundation
import XCTest
@testable import Intreccio

final class UnifiedDiffParserTests: XCTestCase {
    func testParsesHunkLineNumbersSyntaxAndNoNewlineMarker() throws {
        let patch = """
        diff --git a/Sample.swift b/Sample.swift
        index 1111111..2222222 100644
        --- a/Sample.swift
        +++ b/Sample.swift
        @@ -1,2 +1,2 @@ declaration
        -let old = "value"
        +let new = "value"
         return new
        \\ No newline at end of file

        """

        let diff = UnifiedDiffParser.parse(Data(patch.utf8))
        XCTAssertNil(diff.fallback)
        let hunk = try XCTUnwrap(diff.files.first?.textHunks.first)
        XCTAssertEqual(hunk.oldRange, DiffRange(start: 1, count: 2))
        XCTAssertEqual(hunk.newRange, DiffRange(start: 1, count: 2))
        XCTAssertEqual(hunk.lines.map(\.oldLineNumber), [1, nil, 2])
        XCTAssertEqual(hunk.lines.map(\.newLineNumber), [nil, 1, 2])
        XCTAssertFalse(try XCTUnwrap(hunk.lines.last).hasTrailingNewline)
        XCTAssertTrue(hunk.lines[1].tokens.contains { $0.kind == .keyword && $0.text == "let" })
        XCTAssertTrue(hunk.lines[1].tokens.contains { $0.kind == .string && $0.text == "\"value\"" })
    }

    func testParsesBinaryAndRenameMetadata() throws {
        let patch = """
        diff --git a/old.bin b/new.bin
        similarity index 100%
        rename from old.bin
        rename to new.bin
        Binary files a/old.bin and b/new.bin differ

        """
        let diff = UnifiedDiffParser.parse(Data(patch.utf8))
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.path, "new.bin")
        XCTAssertEqual(file.originalPath, "old.bin")
        XCTAssertEqual(file.change, .renamed)
        XCTAssertEqual(file.content, .binary(byteCount: nil))
    }

    func testMalformedHunkReturnsMetadataWithoutPartialLines() {
        let summary = DiffFileSummary(path: "bad.txt", originalPath: nil, change: .modified)
        let patch = """
        diff --git a/bad.txt b/bad.txt
        --- a/bad.txt
        +++ b/bad.txt
        @@ -1,2 +1,1 @@
        -old
        +new

        """
        let diff = UnifiedDiffParser.parse(Data(patch.utf8), summaries: [summary])
        XCTAssertEqual(diff.files, [])
        XCTAssertEqual(diff.fallback, DiffFallback(reason: .malformed, files: [summary]))
    }

    func testByteAndLineLimitsAcceptExactBoundary() {
        let patch = """
        diff --git a/a b/a
        --- a/a
        +++ b/a
        @@ -0,0 +1,1 @@
        +x

        """
        let data = Data(patch.utf8)
        let exact = DiffLimits(maximumBytes: data.count, maximumLines: 5)
        XCTAssertNil(UnifiedDiffParser.parse(data, limits: exact).fallback)
        XCTAssertEqual(
            UnifiedDiffParser.parse(data, limits: DiffLimits(maximumBytes: data.count - 1, maximumLines: 5)).fallback?.reason,
            .byteLimit(data.count - 1)
        )
        XCTAssertEqual(
            UnifiedDiffParser.parse(data, limits: DiffLimits(maximumBytes: data.count, maximumLines: 4)).fallback?.reason,
            .lineLimit(4)
        )
    }

    func testMissingFinalNewlineIsTruncated() {
        let patch = Data("diff --git a/a b/a\n--- a/a\n+++ b/a".utf8)
        XCTAssertEqual(UnifiedDiffParser.parse(patch).fallback?.reason, .truncated)
    }

    func testURLInsideStringIsNotTokenizedAsComment() {
        let tokens = DiffSyntaxTokenizer.tokenize("let url = \"https://example.com\"")
        XCTAssertFalse(tokens.contains { $0.kind == .comment })
        XCTAssertTrue(tokens.contains { $0.kind == .string && $0.text == "\"https://example.com\"" })
    }
}

private extension DiffFile {
    var textHunks: [DiffHunk] {
        if case .text(let hunks) = content { return hunks }
        return []
    }
}
