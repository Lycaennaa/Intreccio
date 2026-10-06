import Foundation
import XCTest
@testable import Intreccio

private struct SnapshotCollectionRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func index(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}

final class RepositorySnapshotCollectionsTests: XCTestCase {
    func testMapMatchesDictionaryModelAcrossRandomizedOperations() {
        let keys = (0..<64).map(Self.testUUID)
        var random = SnapshotCollectionRandomNumberGenerator(seed: 0xA11CE)
        var actual = RepositorySnapshotMap<Int>()
        var expected: [UUID: Int] = [:]

        for step in 0..<4_000 {
            let key = keys[random.index(upperBound: keys.count)]
            switch random.next() % 5 {
            case 0, 1:
                let previous = actual
                let previousExpected = expected
                let value = Int(truncatingIfNeeded: random.next())
                actual = actual.setting(value, for: key)
                expected[key] = value
                XCTAssertEqual(previous, RepositorySnapshotMap(previousExpected), "step \(step)")
            case 2:
                let previous = actual
                let previousExpected = expected
                actual = actual.setting(nil, for: key)
                expected[key] = nil
                XCTAssertEqual(previous, RepositorySnapshotMap(previousExpected), "step \(step)")
            case 3:
                XCTAssertEqual(actual[key], expected[key], "step \(step)")
                XCTAssertEqual(actual[key, default: 17], expected[key] ?? 17, "step \(step)")
            default:
                let filtered = actual.filtering { _, value in value.isMultiple(of: 3) }
                let filteredExpected = Dictionary(
                    uniqueKeysWithValues: expected.filter { $0.value.isMultiple(of: 3) }
                )
                assertMap(filtered, matches: filteredExpected, step: step)
            }

            assertMap(actual, matches: expected, step: step)
        }
    }

    func testMapDictionaryLiteralPreservesKeyOrdering() {
        let first = Self.testUUID(1)
        let second = Self.testUUID(2)
        let map: RepositorySnapshotMap<Int> = [second: 2, first: 1]

        XCTAssertEqual(map.keys, [first, second])
        XCTAssertEqual(map.values, [1, 2])
        XCTAssertEqual(map.entries.map { $0.key }, [first, second])
        XCTAssertEqual(map.entries.map { $0.value }, [1, 2])
    }

    func testSetMatchesSetModelAcrossRandomizedOperations() {
        let keys = (0..<64).map(Self.testUUID)
        var random = SnapshotCollectionRandomNumberGenerator(seed: 0xBADC0DE)
        var actual = RepositorySnapshotSet()
        var expected = Set<UUID>()

        for step in 0..<4_000 {
            let key = keys[random.index(upperBound: keys.count)]
            switch random.next() % 4 {
            case 0:
                let previous = actual
                let previousExpected = expected
                actual = actual.inserting(key)
                expected.insert(key)
                XCTAssertEqual(previous, RepositorySnapshotSet(previousExpected), "step \(step)")
            case 1:
                let previous = actual
                let previousExpected = expected
                actual = actual.removing(key)
                expected.remove(key)
                XCTAssertEqual(previous, RepositorySnapshotSet(previousExpected), "step \(step)")
            case 2:
                XCTAssertEqual(actual.contains(key), expected.contains(key), "step \(step)")
            default:
                XCTAssertEqual(actual, RepositorySnapshotSet(expected), "step \(step)")
            }

            let orderedExpected = expected.sorted { $0.uuidString < $1.uuidString }
            XCTAssertEqual(actual.count, expected.count, "step \(step)")
            XCTAssertEqual(actual.isEmpty, expected.isEmpty, "step \(step)")
            XCTAssertEqual(actual.elements, orderedExpected, "step \(step)")
            XCTAssertTrue(actual == expected, "step \(step)")
            XCTAssertTrue(expected == actual, "step \(step)")
        }
    }

    private func assertMap(
        _ actual: RepositorySnapshotMap<Int>,
        matches expected: [UUID: Int],
        step: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let orderedKeys = expected.keys.sorted { $0.uuidString < $1.uuidString }
        let orderedValues = orderedKeys.map { expected[$0]! }
        XCTAssertEqual(actual.count, expected.count, "step \(step)", file: file, line: line)
        XCTAssertEqual(actual.isEmpty, expected.isEmpty, "step \(step)", file: file, line: line)
        XCTAssertEqual(actual.keys, orderedKeys, "step \(step)", file: file, line: line)
        XCTAssertEqual(actual.values, orderedValues, "step \(step)", file: file, line: line)
        XCTAssertEqual(actual.entries.map { $0.key }, orderedKeys, "step \(step)", file: file, line: line)
        XCTAssertEqual(actual.entries.map { $0.value }, orderedValues, "step \(step)", file: file, line: line)
        XCTAssertEqual(actual, RepositorySnapshotMap(expected), "step \(step)", file: file, line: line)
#if DEBUG
        XCTAssertTrue(actual.isValidForTesting, "step \(step)", file: file, line: line)
#endif
    }

    private static func testUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
}