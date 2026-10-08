import Foundation
@testable import Intreccio
import XCTest

final class CommitParserTests: XCTestCase {
    func testParsesRootMergeUnicodeAndControlSeparators() throws {
        let separatorText = "subject\u{1e}body\u{1f}value"
        let first = ["root", "", "Zoë", "zoe@example.com", "2026-01-02T03:04:05Z", separatorText, "根 commit\n"]
        let second = ["merge", "left right", "Dev", "dev@example.com", "2026-02-03T04:05:06+00:00", "Merge", "body"]
        let data = Data((
            "\0GDC-RECORD\0" + first.joined(separator: "\0") + "\0GDC-END\0\n" +
            "\0GDC-RECORD\0" + second.joined(separator: "\0") + "\0GDC-END\0"
        ).utf8)

        let commits = try CommitParser.parse(data)

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, separatorText)
        XCTAssertEqual(commits[0].parentIDs, [])
        XCTAssertEqual(commits[1].parentIDs, ["left", "right"])
    }

    func testRejectsPartialRecordAndInvalidDate() {
        XCTAssertThrowsError(try CommitParser.parse(Data("\0GDC-RECORD\0only\0two\0GDC-END\0".utf8)))
        let fields = ["oid", "", "A", "a@example.com", "not-a-date", "s", "b"]
        let data = Data(("\0GDC-RECORD\0" + fields.joined(separator: "\0") + "\0GDC-END\0").utf8)
        XCTAssertThrowsError(try CommitParser.parse(data)) {
            XCTAssertEqual($0 as? CommitParserError, .invalidDate("not-a-date"))
        }
    }

    func testHistoryFilterMatchesLoadedSubjectAuthorEmailAndHashOnly() {
        let date = Date(timeIntervalSince1970: 0)
        let commits = [
            Commit(
                objectID: "abc12345",
                parentIDs: [],
                authorName: "Ada Lovelace",
                authorEmail: "ada@example.com",
                authoredAt: date,
                subject: "Add parser",
                body: "hidden body token"
            ),
            Commit(
                objectID: "def67890",
                parentIDs: ["abc12345"],
                authorName: "Grace Hopper",
                authorEmail: "grace@example.com",
                authoredAt: date,
                subject: "Fix paging",
                body: ""
            )
        ]
        let state = SelectedHistoryState(commits: commits)

        XCTAssertEqual(state.filteredCommits(searchText: "PARSER").map(\.objectID), ["abc12345"])
        XCTAssertEqual(state.filteredCommits(searchText: "hopper").map(\.objectID), ["def67890"])
        XCTAssertEqual(state.filteredCommits(searchText: "ADA@EXAMPLE").map(\.objectID), ["abc12345"])
        XCTAssertEqual(state.filteredCommits(searchText: "6789").map(\.objectID), ["def67890"])
        XCTAssertTrue(state.filteredCommits(searchText: "hidden body token").isEmpty)
    }
}
