import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension RepositoryRuntimeControllerTests {
    func testStatusEnqueueTaskIsRemovedAfterSuccessfulEnqueue() async throws {
        let directory = try makeTestDirectory()
        try runGit(at: directory, arguments: ["init", "-b", "main"])
        let repositoryID = UUID()
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: directory,
            canonicalURL: directory,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let controller = RepositoryStatusRefreshController(gitService: GitService())
        controller.update(context: RepositoryRuntimeContext(
            state: PersistedState(),
            repositories: [repository],
            isShuttingDown: false
        ))
        controller.enqueueStatusRefreshes(for: [repositoryID])

        try await waitUntil(timeout: .seconds(10), description: "successful status enqueue cleanup") {
            !controller.snapshot.hasPendingEnqueueTasks
                && controller.snapshot.refreshStates[repositoryID]?.status != nil
        }
        XCTAssertFalse(controller.snapshot.hasPendingEnqueueTasks)
        await controller.finishShutdown()
    }

    func testStatusEnqueueTaskIsRemovedAfterSupersedingCancellation() async throws {
        let repositoryID = UUID()
        let repository = makeRuntimeRepository(id: repositoryID, path: "status-cancelled")
        let controller = RepositoryStatusRefreshController(gitService: GitService())
        controller.update(context: RepositoryRuntimeContext(
            state: PersistedState(),
            repositories: [repository],
            isShuttingDown: false
        ))
        controller.enqueueStatusRefreshes(for: [repositoryID])
        controller.enqueueStatusRefreshes(for: [repositoryID])

        try await waitUntil(description: "superseded status enqueue cleanup") {
            !controller.snapshot.hasPendingEnqueueTasks
        }
        XCTAssertEqual(controller.snapshot.statusRequestGenerations[repositoryID], 2)
        await controller.finishShutdown()
    }

    func testStatusEnqueueTaskIsRemovedWhenRepositoryIsRemoved() async throws {
        let repositoryID = UUID()
        let repository = makeRuntimeRepository(id: repositoryID, path: "status-removed")
        let controller = RepositoryStatusRefreshController(gitService: GitService())
        controller.update(context: RepositoryRuntimeContext(
            state: PersistedState(),
            repositories: [repository],
            isShuttingDown: false
        ))
        controller.enqueueStatusRefreshes(for: [repositoryID])
        await controller.removeRepositories([repositoryID], clearRequestState: true)

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(controller.snapshot.hasPendingEnqueueTasks)
        XCTAssertNil(controller.snapshot.statusRequestGenerations[repositoryID])
        await controller.finishShutdown()
    }
}
