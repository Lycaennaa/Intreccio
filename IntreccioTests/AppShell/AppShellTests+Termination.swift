import AppKit
@testable import Intreccio
import XCTest

extension AppShellTests {
    @MainActor
    func testQuitDuringMutationPresentsWaitAndCancelActionsAtRuntime() throws {
        let directory = try makeTestDirectory()
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json"))
        )
        let windowController = MainWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(windowController.window)
        window.makeKeyAndOrderFront(nil)
        let appDelegate = AppDelegate()
        appDelegate.mainWindowController = windowController
        let activeMutation = Task<OperationFailure?, Never> { nil }
        coordinator.mutationTask = activeMutation
        defer {
            activeMutation.cancel()
            coordinator.mutationTask = nil
            if let sheet = window.sheets.first { window.endSheet(sheet) }
            window.orderOut(nil)
        }

        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApp), .terminateLater)
        let sheet = try XCTUnwrap(window.sheets.first)
        let sheetContentView = try XCTUnwrap(sheet.contentView)
        sheetContentView.layoutSubtreeIfNeeded()
        let buttonTitles = allDescendantViews(in: sheetContentView)
            .compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(buttonTitles.contains("Wait and Quit"))
        let alertText = allDescendantViews(in: sheetContentView)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(alertText.contains { $0.contains("two minutes") })
        XCTAssertTrue(buttonTitles.contains("Cancel Quit"))
    }

    @MainActor
    func testWaitAndQuitCancelsTerminationWhenMutationFails() async throws {
        let directory = try makeTestDirectory()
        let coordinator = AppCoordinator(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json"))
        )
        let windowController = MainWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(windowController.window)
        window.makeKeyAndOrderFront(nil)
        let failure = OperationFailure.message(
            "Transfer may have partially changed main.",
            title: "Transfer failed",
            recoverySuggestion: "Inspect main before continuing."
        )
        let activeMutation = Task<OperationFailure?, Never> { failure }
        coordinator.mutationTask = activeMutation
        var replies: [Bool] = []
        let replyExpectation = expectation(description: "failed wait cancels termination")
        let appDelegate = AppDelegate(terminationReplyHandler: { _, shouldTerminate in
            replies.append(shouldTerminate)
            replyExpectation.fulfill()
        })
        appDelegate.mainWindowController = windowController
        defer {
            activeMutation.cancel()
            coordinator.mutationTask = nil
            if let sheet = window.sheets.first { window.endSheet(sheet) }
            window.orderOut(nil)
        }

        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApp), .terminateLater)
        let sheet = try XCTUnwrap(window.sheets.first)
        let waitButton = try XCTUnwrap(
            allDescendantViews(in: try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
                .first { $0.title == "Wait and Quit" }
        )
        waitButton.performClick(nil)
        XCTAssertTrue(coordinator.mutationAdmissionClosed)
        await fulfillment(of: [replyExpectation], timeout: 1)
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(coordinator.mutationAdmissionClosed)
        XCTAssertFalse(coordinator.isShuttingDown)
    }
    @MainActor
    func testMutationWaitTimeoutCanBeRetriedWithoutStartingASecondWaiter() async throws {
        let coordinator = AppCoordinator()
        let windowController = MainWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(windowController.window)
        window.makeKeyAndOrderFront(nil)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let activeMutation = Task<OperationFailure?, Never> {
            for await _ in stream { break }
            return nil
        }
        coordinator.mutationTask = activeMutation
        var replies: [Bool] = []
        let timeoutReply = expectation(description: "first quit request times out")
        let retryReply = expectation(description: "retry completes after mutation")
        let appDelegate = AppDelegate(
            mutationWaitTimeout: .milliseconds(100),
            terminationReplyHandler: { _, shouldTerminate in
                replies.append(shouldTerminate)
                if replies.count == 1 { timeoutReply.fulfill() }
                if replies.count == 2 { retryReply.fulfill() }
            }
        )
        appDelegate.mainWindowController = windowController
        defer {
            continuation.finish()
            activeMutation.cancel()
            coordinator.mutationTask = nil
            if let sheet = window.sheets.first { window.endSheet(sheet) }
            window.orderOut(nil)
        }

        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApp), .terminateLater)
        let firstSheet = try XCTUnwrap(window.sheets.first)
        let firstSheetContent = try XCTUnwrap(firstSheet.contentView)
        try XCTUnwrap(findButton(titled: "Wait and Quit", in: firstSheetContent)).performClick(nil)
        await fulfillment(of: [timeoutReply], timeout: 1)
        XCTAssertEqual(replies, [false])
        XCTAssertTrue(coordinator.mutationAdmissionClosed)

        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApp), .terminateLater)
        let retrySheet = try XCTUnwrap(window.sheets.first)
        let retrySheetContent = try XCTUnwrap(retrySheet.contentView)
        try XCTUnwrap(findButton(titled: "Wait and Quit", in: retrySheetContent)).performClick(nil)
        continuation.yield(())
        continuation.finish()
        await fulfillment(of: [retryReply], timeout: 1)
        XCTAssertEqual(replies, [false, true])
        XCTAssertTrue(coordinator.isShuttingDown)
    }

    @MainActor
    func testFailedStateFlushCancelsQuitAndReopensMutationAdmission() async throws {
        let directory = try makeTestDirectory()
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockedParent)
        let stateStore = StateStore(fileURL: blockedParent.appendingPathComponent("state.json"))
        let coordinator = AppCoordinator(stateStore: stateStore)
        let windowController = MainWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(windowController.window)
        window.makeKeyAndOrderFront(nil)
        if let startupTask = coordinator.startupTask { await startupTask.value }
        var replies: [Bool] = []
        let replyExpectation = expectation(description: "failed state flush cancels quit")
        let appDelegate = AppDelegate(terminationReplyHandler: { _, shouldTerminate in
            replies.append(shouldTerminate)
            replyExpectation.fulfill()
        })
        appDelegate.mainWindowController = windowController
        defer { window.orderOut(nil) }

        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApp), .terminateLater)
        await fulfillment(of: [replyExpectation], timeout: 1)
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(coordinator.isShuttingDown)
        XCTAssertFalse(coordinator.mutationAdmissionClosed)
        _ = await coordinator.shutdown()
    }
}
