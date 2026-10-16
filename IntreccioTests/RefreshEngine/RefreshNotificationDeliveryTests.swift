import Foundation
@testable import Intreccio
import XCTest

@MainActor
private final class RefreshNotificationTestDelegate: RepositoryRuntimeControllerDelegate {
    let repositories: [RepoDescriptor]
    var state = PersistedState()
    var changes: [RepositoryRuntimeChange] = []
    var statusSnapshotsAreCurrent = true

    init(repositories: [RepoDescriptor]) {
        self.repositories = repositories
    }

    var repositoryRuntimeContext: RepositoryRuntimeContext {
        RepositoryRuntimeContext(
            state: state,
            repositories: repositories,
            isShuttingDown: false
        )
    }

    func repositoryRuntimeController(
        _ controller: RepositoryRuntimeController,
        didChange change: RepositoryRuntimeChange
    ) {
        if case .status(let event, _) = change {
            switch event {
            case .completed(let key, let generation, _, _):
                let state = controller.snapshot.refreshStates[key.repositoryID]
                statusSnapshotsAreCurrent = statusSnapshotsAreCurrent
                    && state?.statusGeneration == generation
                    && state?.phase == .idle
            case .failed(let key, let generation, _, _):
                let state = controller.snapshot.refreshStates[key.repositoryID]
                if case .failed = state?.phase {
                    statusSnapshotsAreCurrent = statusSnapshotsAreCurrent
                        && state?.statusGeneration == generation
                } else {
                    statusSnapshotsAreCurrent = false
                }
            default:
                break
            }
        }
        changes.append(change)
    }
}

@MainActor
final class RefreshNotificationDeliveryTests: XCTestCase {
    private func makeRepository(id: UUID = UUID(), path: String) -> RepoDescriptor {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return RepoDescriptor(
            id: id,
            source: .standalone(id: id),
            url: url,
            canonicalURL: url,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
    }

    func testScheduledRefreshDeliversTerminalSuccessWithCurrentSnapshot() async throws {
        let repository = makeRepository(path: "notification-success")
        let delegate = RefreshNotificationTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(
            gitService: GitService(
                runner: RecordingGitRunner(
                    responses: [
                        .result(recordedGitResult()),
                        .result(recordedGitResult())
                    ]
                )
            ),
            githubURLLookup: { _ in nil }
        )
        runtime.delegate = delegate

        runtime.enqueueStatusRefreshes(for: [repository.id], requestKind: .explicit)
        try await waitUntil(description: "scheduled status success") {
            guard let state = runtime.snapshot.refreshStates[repository.id] else { return false }
            return state.statusGeneration > 0 && state.phase == .idle
        }

        XCTAssertTrue(delegate.changes.contains { change in
            guard case .status(let event, _) = change else { return false }
            if case .completed(let key, _, _, _) = event { return key.repositoryID == repository.id }
            return false
        })
        XCTAssertTrue(delegate.statusSnapshotsAreCurrent)
        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }

    func testScheduledRefreshDeliversFailureWithCurrentSnapshot() async throws {
        let repository = makeRepository(path: "notification-failure")
        let delegate = RefreshNotificationTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(
            gitService: GitService(
                runner: RecordingGitRunner(
                    responses: [.failure(.launchFailed("status failure"))]
                )
            ),
            githubURLLookup: { _ in nil }
        )
        runtime.delegate = delegate

        runtime.enqueueStatusRefreshes(for: [repository.id], requestKind: .explicit)
        try await waitUntil(description: "scheduled status failure") {
            guard let state = runtime.snapshot.refreshStates[repository.id] else { return false }
            if case .failed = state.phase { return true }
            return false
        }

        XCTAssertTrue(delegate.changes.contains { change in
            guard case .status(let event, _) = change else { return false }
            if case .failed(let key, _, _, _) = event { return key.repositoryID == repository.id }
            return false
        })
        XCTAssertTrue(delegate.statusSnapshotsAreCurrent)
        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }
}
