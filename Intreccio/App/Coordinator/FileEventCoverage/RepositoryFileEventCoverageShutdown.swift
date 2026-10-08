import Foundation

@MainActor
final class RepositoryFileEventCoverageShutdown {
    private let stopResources: () -> Void
    private let finishEventStream: () -> Void
    private(set) var isShuttingDown = false

    init(
        stopResources: @escaping () -> Void,
        finishEventStream: @escaping () -> Void
    ) {
        self.stopResources = stopResources
        self.finishEventStream = finishEventStream
    }

    func cancelAndDrain() async {
        isShuttingDown = true
    }

    func finishShutdown() {
        isShuttingDown = true
        stopResources()
        finishEventStream()
    }

    func resumeAfterFailedShutdown() {
        isShuttingDown = false
    }
}
