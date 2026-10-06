import XCTest
@testable import Intreccio

@MainActor
final class RepositoryCatalogCommandGateQueueTests: XCTestCase {
    func testCatalogCommandGateBackpressureBoundsQueueAndPreservesFIFO() async throws {
        let gate = RepositoryCatalogCommandGate(maximumWaiters: 2)
        let testGate = AsyncTestGate()
        let submissionGate = AsyncTestGate()
        let started = SynchronousStringRecorder()
        let submitted = SynchronousStringRecorder()
        let firstTask = Task {
            try await gate.execute(admission: .preserve) {
                started.record("0")
                await testGate.wait("first")
            }
        }
        try await waitUntil(description: "first command operation") {
            started.values == ["0"]
        }

        var tasks: [Task<Void, any Error>] = []
        for index in 1...64 {
            let task = makePreserveTask(
                gate: gate,
                submissionGate: submissionGate,
                started: started,
                submitted: submitted,
                index: index
            )
            tasks.append(task)
            await submissionGate.open("command-\(index)")
            try await waitUntil(description: "command admission \(index)") {
                await gate.admissionRequestCountForTesting == index + 1
            }
        }
        XCTAssertEqual(submitted.values, (1...64).map { String($0) })

        let waitingCount = await gate.waitingCountForTesting
        XCTAssertEqual(waitingCount, 2)
        await testGate.open("first")
        try await firstTask.value
        for task in tasks {
            try await task.value
        }
        XCTAssertEqual(started.values, (0...64).map { String($0) })
    }

    func testCatalogCommandGateCancellationRemovesWaiterAndAdmitsFollowingCommand() async throws {
        let gate = RepositoryCatalogCommandGate(maximumWaiters: 2)
        let testGate = AsyncTestGate()
        let started = StringRecorder()
        let firstTask = Task {
            try await gate.execute(admission: .preserve) {
                await started.record("first")
                await testGate.wait("first")
            }
        }
        try await waitUntil(description: "first command operation") {
            await started.values == ["first"]
        }

        let secondTask = Task {
            try await gate.execute(admission: .preserve) {
                await started.record("second")
            }
        }
        try await waitUntil(description: "second command waiter") {
            await gate.waitingCountForTesting == 1
        }

        let cancelledTask = Task {
            try await gate.execute(admission: .preserve) {
                await started.record("cancelled")
            }
        }
        try await waitUntil(description: "cancelled command waiter") {
            await gate.waitingCountForTesting == 2
        }

        let followingTask = Task {
            try await gate.execute(admission: .preserve) {
                await started.record("following")
            }
        }
        try await waitUntil(description: "following command request") {
            await gate.admissionRequestCountForTesting == 4
        }

        cancelledTask.cancel()
        _ = try? await cancelledTask.value
        try await waitUntil(description: "replacement command waiter") {
            await gate.waitingCountForTesting == 2
        }

        await testGate.open("first")
        try await firstTask.value
        try await secondTask.value
        try await followingTask.value
        let startedValues = await started.values
        XCTAssertEqual(startedValues, ["first", "second", "following"])
    }
    func testCatalogCommandGateRingPreservesFIFOAfterMiddleWaiterCancellation() async throws {
        let gate = RepositoryCatalogCommandGate(maximumWaiters: 3)
        let testGate = AsyncTestGate()
        let started = StringRecorder()
        let firstTask = Task {
            try await gate.execute(admission: .preserve) {
                await started.record("first")
                await testGate.wait("first")
            }
        }
        try await waitUntil(description: "first command operation") {
            await started.values == ["first"]
        }

        var queuedTasks: [Task<Void, any Error>] = []
        for value in ["second", "cancelled", "third"] {
            queuedTasks.append(Task {
                try await gate.execute(admission: .preserve) {
                    await started.record(value)
                }
            })
            let queuedTaskCount = queuedTasks.count
            try await waitUntil(description: "queued command \(value)") {
                await gate.waitingCountForTesting == queuedTaskCount
            }
        }

        let followingTask = Task {
            try await gate.execute(admission: .preserve) {
                await started.record("following")
            }
        }
        try await waitUntil(description: "following command request") {
            await gate.admissionRequestCountForTesting == 5
        }

        queuedTasks[1].cancel()
        _ = try? await queuedTasks[1].value
        try await waitUntil(description: "replacement command waiter") {
            await gate.waitingCountForTesting == 3
        }

        await testGate.open("first")
        try await firstTask.value
        try await queuedTasks[0].value
        try await queuedTasks[2].value
        try await followingTask.value
        let startedValues = await started.values
        XCTAssertEqual(startedValues, ["first", "second", "third", "following"])
    }


    func testCatalogCommandGateCoalescingReportsRejectionWithoutDroppingQueuedWork() async throws {
        let gate = RepositoryCatalogCommandGate(maximumWaiters: 1)
        let testGate = AsyncTestGate()
        let started = StringRecorder()
        let firstTask = Task {
            try await gate.execute(admission: .preserve) {
                await started.record("first")
                await testGate.wait("first")
            }
        }
        try await waitUntil(description: "first command operation") {
            await started.values == ["first"]
        }

        let queuedTask = Task {
            try await gate.execute(admission: .preserve) {
                await started.record("queued")
            }
        }
        try await waitUntil(description: "queued command waiter") {
            await gate.waitingCountForTesting == 1
        }

        do {
            try await gate.execute(admission: .coalesce) {
                await started.record("rejected")
            }
            XCTFail("Full command queue unexpectedly admitted a coalescing request")
        } catch RepositoryCatalogCommandError.coalesced {
        }

        await testGate.open("first")
        try await firstTask.value
        try await queuedTask.value
        let startedValues = await started.values
        XCTAssertEqual(startedValues, ["first", "queued"])
    }

    func testCatalogCommandGatePreserveOverflowCancellationAndCleanup() async throws {
        let requestCount = 256
        let gate = RepositoryCatalogCommandGate(maximumWaiters: 128)
        let testGate = AsyncTestGate()
        let started = StringRecorder()
        let firstTask = Task {
            try await gate.execute(admission: .preserve) {
                await started.record("0")
                await testGate.wait("first")
            }
        }
        try await waitUntil(description: "first command operation") {
            await started.values == ["0"]
        }

        let submissionGate = AsyncTestGate()
        var tasks: [Task<Void, any Error>] = []
        for index in 1...requestCount {
            let commandIndex = index
            tasks.append(Task { [commandIndex] in
                await submissionGate.wait("command-\(commandIndex)")
                try await gate.execute(admission: .preserve) {
                    await started.record(String(commandIndex))
                }
            })
            await submissionGate.open("command-\(commandIndex)")
            try await waitUntil(description: "command admission \(commandIndex)") {
                await gate.admissionRequestCountForTesting == commandIndex + 1
            }
        }
        let waitingCount = await gate.waitingCountForTesting
        XCTAssertEqual(waitingCount, 128)
        let admittedCount = await gate.admittedCountForTesting
        XCTAssertEqual(admittedCount, 129)
        let producerWaiterCount = await gate.producerWaiterCountForTesting
        XCTAssertLessThanOrEqual(producerWaiterCount, 1)
        let producerWakeCount = await gate.producerWakeCountForTesting
        XCTAssertEqual(producerWakeCount, 0)

        let cancelledIndex = 129
        let cancelledTask = tasks[cancelledIndex - 1]
        cancelledTask.cancel()
        do {
            try await cancelledTask.value
            XCTFail("Cancelled preserve request unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let startedBeforeRelease = await started.values
        XCTAssertEqual(startedBeforeRelease, ["0"])
        await testGate.open("first")
        try await firstTask.value
        for (index, task) in tasks.enumerated() where index != cancelledIndex - 1 {
            try await task.value
        }

        let expected = (0...requestCount)
            .filter { $0 != cancelledIndex }
            .map(String.init)
        let startedValues = await started.values
        XCTAssertEqual(startedValues, expected)
        let finalWaitingCount = await gate.waitingCountForTesting
        XCTAssertEqual(finalWaitingCount, 0)
        let finalAdmittedCount = await gate.admittedCountForTesting
        XCTAssertEqual(finalAdmittedCount, 0)
    }

    func testCatalogPreserveOverflowDoesNotRetainWaitingCommandTasks() async throws {
        let directory = try makeTestDirectory()
        let catalog = RepositoryCatalog(
            stateStore: StateStore(fileURL: directory.appendingPathComponent("state.json")),
            bookmarkStore: BookmarkStore(),
            scanner: RepoScanner(),
            gitService: GitService()
        )
        let testGate = AsyncTestGate()
        let started = StringRecorder()
        let submissionGate = AsyncTestGate()
        let firstTask = Task {
            try await catalog.executeCommand {
                await started.record("0")
                await testGate.wait("first")
                return 0
            }
        }
        try await waitUntil(description: "first catalog command") {
            await started.values == ["0"]
        }

        let requestCount = 160
        var tasks: [Task<Int, any Error>] = []
        let commandGate = catalog.commandGate
        for index in 1...requestCount {
            let commandIndex = index
            tasks.append(Task { [commandIndex] in
                await submissionGate.wait("command-\(commandIndex)")
                return try await catalog.executeCommand {
                    await started.record(String(commandIndex))
                    return commandIndex
                }
            })
            await submissionGate.open("command-\(commandIndex)")
            try await waitUntil(description: "command admission \(commandIndex)") {
                await commandGate.admissionRequestCountForTesting == commandIndex + 1
            }
        }
        let waitingCount = await commandGate.waitingCountForTesting
        XCTAssertEqual(waitingCount, 128)
        let admittedCount = await commandGate.admittedCountForTesting
        XCTAssertEqual(admittedCount, 129)
        let producerWaiterCount = await commandGate.producerWaiterCountForTesting
        XCTAssertLessThanOrEqual(producerWaiterCount, 1)
        let producerWakeCount = await commandGate.producerWakeCountForTesting
        XCTAssertEqual(producerWakeCount, 0)
        XCTAssertEqual(catalog.commandTaskCountForTesting, 1)

        await testGate.open("first")
        let firstValue = try await firstTask.value
        XCTAssertEqual(firstValue, 0)
        for (index, task) in tasks.enumerated() {
            let value = try await task.value
            XCTAssertEqual(value, index + 1)
        }
        let startedValues = await started.values
        XCTAssertEqual(startedValues, (0...requestCount).map(String.init))
        XCTAssertEqual(catalog.commandTaskCountForTesting, 0)
        await catalog.shutdown()
    }
    private func makePreserveTask(
        gate: RepositoryCatalogCommandGate,
        submissionGate: AsyncTestGate,
        started: SynchronousStringRecorder,
        submitted: SynchronousStringRecorder,
        index: Int
    ) -> Task<Void, any Error> {
        Task { [index] in
            await submissionGate.wait("command-\(index)")
            submitted.record(String(index))
            try await gate.execute(admission: .preserve) {
                started.record(String(index))
            }
        }
    }
}

@MainActor
private final class SynchronousStringRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}