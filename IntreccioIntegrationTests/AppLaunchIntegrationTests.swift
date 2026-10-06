import Darwin
import Foundation
import XCTest

final class AppLaunchIntegrationTests: XCTestCase {
    func testBuiltAppLaunchesWithoutImmediateExit() throws {
        let productsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let executable = productsDirectory
            .appendingPathComponent("Intreccio.app/Contents/MacOS/Intreccio")
        try skipIfExternalInstanceHoldsLock(
            appURL: productsDirectory.appendingPathComponent("Intreccio.app", isDirectory: true)
        )
        let process = Process()
        let didExit = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.environment = ProcessInfo.processInfo.environment.merging([
            "INTRECCIO_TEST_INSTANCE": "1",
        ]) { _, testValue in testValue }
        process.terminationHandler = { _ in didExit.signal() }

        try process.run()
        defer { stopIfRunning(process, didExit: didExit) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(process.isRunning, "App exited immediately with status \(process.terminationStatus)")

        let primary = Process()
        let primaryDidExit = DispatchSemaphore(value: 0)
        primary.executableURL = executable
        primary.terminationHandler = { _ in primaryDidExit.signal() }
        try primary.run()
        defer { stopIfRunning(primary, didExit: primaryDidExit) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(primary.isRunning, "Production app exited immediately with status \(primary.terminationStatus)")

        let duplicate = Process()
        let duplicateDidExit = DispatchSemaphore(value: 0)
        duplicate.executableURL = executable
        duplicate.terminationHandler = { _ in duplicateDidExit.signal() }
        try duplicate.run()
        defer { stopIfRunning(duplicate, didExit: duplicateDidExit) }
        XCTAssertEqual(duplicateDidExit.wait(timeout: .now() + 5), .success, "Second app instance did not exit")
        XCTAssertEqual(duplicate.terminationStatus, EXIT_SUCCESS)
        XCTAssertTrue(primary.isRunning, "Original production app instance exited when duplicate launched")
        XCTAssertTrue(process.isRunning, "Test app instance exited when production app launched")

        primary.terminate()
        if primaryDidExit.wait(timeout: .now() + 5) == .timedOut {
            let killResult = kill(primary.processIdentifier, SIGKILL)
            XCTAssertTrue(killResult == 0 || errno == ESRCH, "Could not kill production app process: errno \(errno)")
            XCTAssertEqual(primaryDidExit.wait(timeout: .now() + 2), .success, "Killed production app process was not reaped")
            XCTFail("Production app did not terminate within five seconds")
        }

        process.terminate()
        if didExit.wait(timeout: .now() + 5) == .timedOut {
            let killResult = kill(process.processIdentifier, SIGKILL)
            XCTAssertTrue(killResult == 0 || errno == ESRCH, "Could not kill app process: errno \(errno)")
            XCTAssertEqual(didExit.wait(timeout: .now() + 2), .success, "Killed app process was not reaped")
            XCTFail("App did not terminate within five seconds")
        }

        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    }

    private func stopIfRunning(_ process: Process, didExit: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if didExit.wait(timeout: .now() + 5) == .timedOut {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = didExit.wait(timeout: .now() + 2)
        }
    }
}

    // An externally launched app instance holds the single-instance lock and makes the
    // production instance below exit via the already-running path, which looks identical
    // to a real failure. Probe the lock and skip instead.
    private func skipIfExternalInstanceHoldsLock(appURL: URL) throws {
        let identifier = Bundle(url: appURL)?.bundleIdentifier ?? "com.lycaennaa.intreccio"
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(identifier).single-instance.lock")
        let fileDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return }
        defer { close(fileDescriptor) }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 else { return }
        throw XCTSkip("An external \(identifier) instance holds the single-instance lock; close it and rerun.")
    }
