import XCTest
@testable import Intreccio

@MainActor
final class OpenApplicationRemovalDialogTests: XCTestCase {
    private func makeURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/Applications/\(name).app")
    }

    func testRemoveResponseInvokesOnRemoveWithSelectedURLs() {
        let dialog = OpenApplicationRemovalDialog(
            applicationURLs: [makeURL("A"), makeURL("B")],
            applicationNames: ["A", "B"]
        )
        let selected = [makeURL("B")]
        var removed: [[URL]] = []
        dialog.handleDismissal(.alertFirstButtonReturn, selectedURLs: selected) { removed.append($0) }
        XCTAssertEqual(removed, [selected])
    }

    func testCancelResponseDoesNotInvokeOnRemove() {
        let dialog = OpenApplicationRemovalDialog(
            applicationURLs: [makeURL("A")],
            applicationNames: ["A"]
        )
        var callCount = 0
        dialog.handleDismissal(.cancel, selectedURLs: [makeURL("A")]) { _ in callCount += 1 }
        XCTAssertEqual(callCount, 0)
    }

    func testEmptySelectionDoesNotInvokeOnRemove() {
        let dialog = OpenApplicationRemovalDialog(
            applicationURLs: [makeURL("A")],
            applicationNames: ["A"]
        )
        var callCount = 0
        dialog.handleDismissal(.alertFirstButtonReturn, selectedURLs: []) { _ in callCount += 1 }
        XCTAssertEqual(callCount, 0)
    }
}
