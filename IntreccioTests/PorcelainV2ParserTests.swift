import Foundation
@testable import Intreccio
import XCTest

final class PorcelainV2ParserTests: XCTestCase {
    func testParsesBranchEveryStatePairAndOddPaths() throws {
        var input = "# branch.oid abc123\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -3\0# stash 2\0"
        for index in GitFileState.allCases {
            for worktree in GitFileState.allCases {
                input += "1 \(index.rawValue)\(worktree.rawValue) N... 100644 100644 100644 abc def \(index.rawValue)\(worktree.rawValue).txt\0"
            }
        }
        input += "? odd\tline\n雪.txt\0"

        let status = try PorcelainV2Parser.parse(Data(input.utf8))

        XCTAssertEqual(status.branch, BranchStatus(
            head: "main",
            objectID: "abc123",
            upstream: "origin/main",
            ahead: 2,
            behind: 3
        ))
        XCTAssertEqual(status.changes.count, GitFileState.allCases.count * GitFileState.allCases.count + 1)
        XCTAssertEqual(status.changes.last?.path, "odd\tline\n雪.txt")
        XCTAssertTrue(status.hasStash)
    }

    func testParsesRenameCopyConflictAndUnbornHead() throws {
        let input = Data((
            "# branch.oid (initial)\0" +
            "2 R. N... 100644 100644 100644 abc def R100 new name.txt\0old name.txt\0" +
            "2 C. N... 100644 100644 100644 abc def C075 copied.txt\0source.txt\0" +
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt\0"
        ).utf8)

        let status = try PorcelainV2Parser.parse(input)

        XCTAssertNil(status.branch.objectID)
        XCTAssertEqual(status.changes.map(\.kind), [.renamed, .copied, .unmerged])
        XCTAssertEqual(status.changes[0].originalPath, "old name.txt")
        XCTAssertTrue(status.hasConflicts)
    }

    func testRejectsPartialAndMalformedRecords() {
        XCTAssertThrowsError(try PorcelainV2Parser.parse(Data("2 R. N... 100644 100644 100644 a b R100 new.txt\0".utf8))) {
            XCTAssertEqual($0 as? PorcelainV2ParserError, .missingRenameSource("new.txt"))
        }
        XCTAssertThrowsError(try PorcelainV2Parser.parse(Data("1 X. broken\0".utf8)))
        XCTAssertThrowsError(try PorcelainV2Parser.parse(Data("unexpected\0".utf8)))
    }

    func testSidebarBadgeCombinesLocalChangesAndUpstreamCounts() throws {
        var status = try PorcelainV2Parser.parse(Data((
            "# branch.upstream origin/main\0" +
            "# branch.ab +3 -5\0" +
            "? first.txt\0" +
            "? second.txt\0"
        ).utf8))
        status.pushAccess = .allowed
        var state = RepositoryRefreshState(status: status)

        XCTAssertEqual(state.sidebarBadge, "L2 || P3 || U5")

        state.status?.branch.behind = 0
        XCTAssertEqual(state.sidebarBadge, "L2 || P3")

        state.status?.branch.ahead = 0
        XCTAssertEqual(state.sidebarBadge, "L2")
        XCTAssertNil(RepositoryRefreshState().sidebarBadge)
    }
    func testPreservesInvalidPathBytesAndDoesNotUseReplacementAsIdentity() throws {
        let prefix = Data("1 .M N... 100644 100644 100644 abc def ".utf8)
        var input = prefix
        input.append(contentsOf: [0x62, 0x61, 0x64, 0xFF, 0x2E, 0x74, 0x78, 0x74])
        input.append(0)
        input.append(prefix)
        input.append(contentsOf: [0x62, 0x61, 0x64, 0xFE, 0x2E, 0x74, 0x78, 0x74])
        input.append(0)

        let changes = try PorcelainV2Parser.parse(input).changes

        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.allSatisfy(\.isPathLossy))
        XCTAssertEqual(changes[0].gitPath.bytes[3], 0xFF)
        XCTAssertEqual(changes[1].gitPath.bytes[3], 0xFE)
        XCTAssertNotEqual(changes[0].gitPath, changes[1].gitPath)
        XCTAssertNotEqual(changes[0].displayPath, changes[1].displayPath)
        XCTAssertTrue(changes.allSatisfy { !$0.isAddressable })
    }
 }
