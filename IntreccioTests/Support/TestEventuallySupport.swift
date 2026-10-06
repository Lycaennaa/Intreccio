import Foundation

private func pollUntil(
    timeout: Duration,
    pollInterval: Duration,
    description: String,
    file: StaticString,
    line: UInt,
    isolation: isolated (any Actor)? = #isolation,
    condition: () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            throw TestEventuallyError.timedOut(
                description: description,
                timeout: timeout,
                file: file,
                line: line
            )
        }
        try await Task.sleep(for: pollInterval)
    }
}

@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(20),
    description: String = "condition",
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @MainActor () -> Bool
) async throws {
    try await pollUntil(
        timeout: timeout,
        pollInterval: pollInterval,
        description: description,
        file: file,
        line: line
    ) {
        condition()
    }
}

func waitUntil(
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(10),
    description: String = "condition",
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @Sendable () async -> Bool
) async throws {
    try await pollUntil(
        timeout: timeout,
        pollInterval: pollInterval,
        description: description,
        file: file,
        line: line
    ) {
        await condition()
    }
}

enum TestEventuallyError: Error, LocalizedError {
    case timedOut(description: String, timeout: Duration, file: StaticString, line: UInt)

    var errorDescription: String? {
        switch self {
        case let .timedOut(description, timeout, file, line):
            "Timed out after \(timeout) waiting for \(description) at \(file):\(line)"
        }
    }
}