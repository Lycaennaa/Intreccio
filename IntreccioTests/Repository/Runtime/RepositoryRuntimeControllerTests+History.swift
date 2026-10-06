import AppKit
import Foundation
import XCTest
@testable import Intreccio

extension RepositoryRuntimeControllerTests {
    func testStaleRefreshResultIsRejectedAfterNewerGeneration() throws {
        let repositoryID = UUID()
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: URL(fileURLWithPath: "runtime-test-repository", isDirectory: true),
            canonicalURL: URL(fileURLWithPath: "runtime-test-repository", isDirectory: true),
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        let key = RefreshKey(repositoryID: repositoryID, kind: .status)

        runtime.handleRefreshEvent(.completed(key, 4, RepoStatus()))
        runtime.handleRefreshEvent(.completed(key, 3, RepoStatus()))

        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.statusGeneration, 4)
        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, 1)
        XCTAssertEqual(delegate.changes.count, 1)
        XCTAssertTrue(delegate.statusWasPublishedAfterSnapshotUpdate)
    }

    func testUnchangedBranchStatusDoesNotInvalidateHistory() {
        let repositoryID = UUID()
        var state = PersistedState()
        state.uiState.selectedRepoID = repositoryID
        state.uiState.mode = .history
        let repository = makeRuntimeRepository(id: repositoryID, path: "unchanged-branch-status")
        let delegate = RuntimeTestDelegate(state: state, repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        let key = RefreshKey(repositoryID: repositoryID, kind: .status)
        let branch = BranchStatus(
            head: "main",
            objectID: "local-tip",
            upstream: "origin/main",
            ahead: 1,
            behind: 2
        )

        runtime.handleRefreshEvent(.completed(key, 1, RepoStatus(branch: branch)))
        let generation = runtime.snapshot.refreshStates[repositoryID]?.historyGeneration
        delegate.changes.removeAll()
        let statusWithChangedFiles = RepoStatus(
            branch: branch,
            changes: [FileChange(
                path: "file.txt",
                originalPath: nil,
                indexState: .unmodified,
                worktreeState: .modified,
                kind: .ordinary,
                submoduleState: nil
            )]
        )
        runtime.handleRefreshEvent(.completed(key, 2, statusWithChangedFiles))

        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, generation)
        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.status?.changes.count, 1)
        XCTAssertEqual(historyInvalidation(in: delegate.changes), false)
    }

    func testChangedBranchStatusInvalidatesHistory() {
        let repositoryID = UUID()
        let repository = makeRuntimeRepository(id: repositoryID, path: "changed-branch-status")
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        let key = RefreshKey(repositoryID: repositoryID, kind: .status)
        let firstBranch = BranchStatus(head: "main", objectID: "first-tip")
        let secondBranch = BranchStatus(head: "main", objectID: "second-tip")

        runtime.handleRefreshEvent(.completed(key, 1, RepoStatus(branch: firstBranch)))
        let firstGeneration = runtime.snapshot.refreshStates[repositoryID]?.historyGeneration ?? 0
        delegate.changes.removeAll()
        runtime.handleRefreshEvent(.completed(key, 2, RepoStatus(branch: secondBranch)))

        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, firstGeneration + 1)
        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.status?.branch, secondBranch)
        XCTAssertEqual(historyInvalidation(in: delegate.changes), true)
    }

    func testDetachedAndUnbornBranchStatusesCompareOptionalTips() {
        let repositoryID = UUID()
        let repository = makeRuntimeRepository(id: repositoryID, path: "detached-unborn-status")
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        let key = RefreshKey(repositoryID: repositoryID, kind: .status)
        let detached = BranchStatus(head: nil, objectID: "detached-tip")
        let detachedAdvance = BranchStatus(head: nil, objectID: "new-detached-tip")
        let unborn = BranchStatus(head: "main", objectID: nil)
        let born = BranchStatus(head: "main", objectID: "first-tip")

        runtime.handleRefreshEvent(.completed(key, 1, RepoStatus(branch: detached)))
        let detachedGeneration = runtime.snapshot.refreshStates[repositoryID]?.historyGeneration ?? 0
        runtime.handleRefreshEvent(.completed(key, 2, RepoStatus(branch: detached)))
        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, detachedGeneration)
        runtime.handleRefreshEvent(.completed(key, 3, RepoStatus(branch: detachedAdvance)))
        let advancedDetachedGeneration = runtime.snapshot.refreshStates[repositoryID]?.historyGeneration ?? 0
        XCTAssertEqual(advancedDetachedGeneration, detachedGeneration + 1)

        runtime.handleRefreshEvent(.completed(key, 4, RepoStatus(branch: unborn)))
        let unbornGeneration = runtime.snapshot.refreshStates[repositoryID]?.historyGeneration ?? 0
        runtime.handleRefreshEvent(.completed(key, 5, RepoStatus(branch: unborn)))
        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, unbornGeneration)
        runtime.handleRefreshEvent(.completed(key, 6, RepoStatus(branch: born)))
        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, unbornGeneration + 1)
    }

    func testUpstreamBranchTipStateChangeInvalidatesHistory() {
        let repositoryID = UUID()
        let repository = makeRuntimeRepository(id: repositoryID, path: "upstream-tip-status")
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        let key = RefreshKey(repositoryID: repositoryID, kind: .status)
        let current = BranchStatus(
            head: "main",
            objectID: "local-tip",
            upstream: "origin/main",
            ahead: 0,
            behind: 0
        )
        let upstreamAdvanced = BranchStatus(
            head: "main",
            objectID: "local-tip",
            upstream: "origin/main",
            ahead: 0,
            behind: 1
        )

        runtime.handleRefreshEvent(.completed(key, 1, RepoStatus(branch: current)))
        let generation = runtime.snapshot.refreshStates[repositoryID]?.historyGeneration ?? 0
        delegate.changes.removeAll()
        runtime.handleRefreshEvent(.completed(key, 2, RepoStatus(branch: upstreamAdvanced)))

        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, generation + 1)
        XCTAssertEqual(historyInvalidation(in: delegate.changes), true)
    }

    func testExplicitHistoryInvalidationWorksWhenStatusTipIsUnchanged() {
        let repositoryID = UUID()
        var state = PersistedState()
        state.uiState.selectedRepoID = repositoryID
        state.uiState.mode = .history
        let repository = makeRuntimeRepository(id: repositoryID, path: "explicit-history-refresh")
        let delegate = RuntimeTestDelegate(state: state, repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        let key = RefreshKey(repositoryID: repositoryID, kind: .status)
        let branch = BranchStatus(head: "main", objectID: "local-tip")

        runtime.handleRefreshEvent(.completed(key, 1, RepoStatus(branch: branch)))
        let generation = runtime.snapshot.refreshStates[repositoryID]?.historyGeneration ?? 0

        XCTAssertTrue(runtime.invalidateHistory(for: [repositoryID]))
        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, generation + 1)
    }

    func testUnknownStatusAndStatusErrorsInvalidateHistory() {
        let repositoryID = UUID()
        let repository = makeRuntimeRepository(id: repositoryID, path: "unknown-status")
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        let key = RefreshKey(repositoryID: repositoryID, kind: .status)
        let failure = OperationFailure.message(
            "status unavailable",
            title: "Status failed",
            recoverySuggestion: "Retry"
        )

        runtime.handleRefreshEvent(.completed(key, 1, RepoStatus()))
        XCTAssertEqual(historyInvalidation(in: delegate.changes), true)
        let unknownGeneration = runtime.snapshot.refreshStates[repositoryID]?.historyGeneration ?? 0
        delegate.changes.removeAll()
        runtime.handleRefreshEvent(.failed(key, 2, failure))
        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, unknownGeneration)
        XCTAssertEqual(historyInvalidation(in: delegate.changes), false)

        delegate.changes.removeAll()
        runtime.handleRefreshEvent(.completedWithFailure(key, 3, RepoStatus(), failure))
        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, unknownGeneration)
        XCTAssertEqual(historyInvalidation(in: delegate.changes), false)
    }

    func testFailedStatusInvalidatesHistoryWhenPriorStatusIsUnknown() {
        let repositoryID = UUID()
        let repository = makeRuntimeRepository(id: repositoryID, path: "unknown-failed-status")
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate
        let key = RefreshKey(repositoryID: repositoryID, kind: .status)
        let failure = OperationFailure.message(
            "status unavailable",
            title: "Status failed",
            recoverySuggestion: "Retry"
        )

        runtime.handleRefreshEvent(.failed(key, 1, failure))

        XCTAssertEqual(runtime.snapshot.refreshStates[repositoryID]?.historyGeneration, 1)
        XCTAssertEqual(historyInvalidation(in: delegate.changes), true)
    }
}