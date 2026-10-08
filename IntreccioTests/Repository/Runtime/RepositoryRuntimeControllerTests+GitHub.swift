import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension RepositoryRuntimeControllerTests {
    func testStaleGitHubResultIsRejectedAfterIdentityGenerationChanges() async throws {
        let directory = try makeTestDirectory()
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
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(gitService: GitService())
        runtime.delegate = delegate

        runtime.scheduleGitHubURLLookups(for: [repository], forceRefresh: false)
        runtime.invalidateGitHubURLLookup(for: repositoryID)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertGreaterThan(runtime.githubResolutionSnapshot.generations[repositoryID] ?? 0, 0)
        XCTAssertNil(runtime.snapshot.githubURLs[repositoryID])
    }

    func testInvalidatingOneRepositoryPreservesOtherCachedGitHubURL() async throws {
        let first = makeRuntimeRepository(path: "runtime-first")
        let second = makeRuntimeRepository(path: "runtime-second")
        let delegate = RuntimeTestDelegate(repositories: [first, second])
        let runtime = RepositoryRuntimeController(
            gitService: GitService(),
            githubURLLookup: { repository in
                URL(string: "https://github.com/cache/\(repository.lastPathComponent)")
            }
        )
        runtime.delegate = delegate

        runtime.scheduleGitHubURLLookups(for: [first, second], forceRefresh: false)
        try await waitUntil(description: "initial GitHub URL lookups") {
            runtime.githubResolutionSnapshot.completedRepositoryIDs == Set([first.id, second.id])
        }
        let secondURL = try XCTUnwrap(runtime.snapshot.githubURLs[second.id])
        let secondGeneration = runtime.githubResolutionSnapshot.generations[second.id]

        runtime.invalidateGitHubURLLookup(for: first.id)

        XCTAssertEqual(runtime.snapshot.githubURLs[second.id], secondURL)
        XCTAssertEqual(runtime.githubResolutionSnapshot.generations[second.id], secondGeneration)
        XCTAssertTrue(runtime.githubResolutionSnapshot.completedRepositoryIDs.contains(second.id))

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }
    func testUnchangedFullRescanPreservesCachedGitHubURLs() async throws {
        let first = makeRuntimeRepository(path: "runtime-unchanged-first")
        let second = makeRuntimeRepository(path: "runtime-unchanged-second")
        let probe = ImmediateGitHubLookupProbe()
        let delegate = RuntimeTestDelegate(repositories: [first, second])
        let runtime = RepositoryRuntimeController(
            gitService: GitService(),
            githubURLLookup: { repository in await probe.lookup(repository) }
        )
        runtime.delegate = delegate

        runtime.scheduleGitHubURLLookups(for: [first, second], forceRefresh: false)
        try await waitUntil(description: "initial unchanged-rescan GitHub URLs") {
            runtime.githubResolutionSnapshot.completedRepositoryIDs == Set([first.id, second.id])
        }
        let firstURL = try XCTUnwrap(runtime.snapshot.githubURLs[first.id])
        let secondURL = try XCTUnwrap(runtime.snapshot.githubURLs[second.id])
        let firstGeneration = runtime.githubResolutionSnapshot.generations[first.id]
        let secondGeneration = runtime.githubResolutionSnapshot.generations[second.id]
        let rescan = CatalogEffectPlan.restored(
            changedRepositoryIDs: [],
            refreshUpstream: false,
            clearsStatusMessage: true
        )

        XCTAssertEqual(
            rescan.runtimeSteps[1],
            .scheduleGitHubURLLookups(target: .changed, forceRefresh: true)
        )
        runtime.scheduleGitHubURLLookups(for: [], forceRefresh: true)

        let firstCallCount = await probe.callCount(for: first.canonicalURL)
        let secondCallCount = await probe.callCount(for: second.canonicalURL)
        XCTAssertEqual(firstCallCount, 1)
        XCTAssertEqual(secondCallCount, 1)
        XCTAssertEqual(runtime.snapshot.githubURLs[first.id], firstURL)
        XCTAssertEqual(runtime.snapshot.githubURLs[second.id], secondURL)
        XCTAssertEqual(runtime.githubResolutionSnapshot.generations[first.id], firstGeneration)
        XCTAssertEqual(runtime.githubResolutionSnapshot.generations[second.id], secondGeneration)

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }

    func testGitHubLookupCancellationIsDrained() async throws {
        let repository = makeRuntimeRepository(path: "runtime-cancel")
        let probe = CancellableGitHubLookupProbe()
        let delegate = RuntimeTestDelegate(repositories: [repository])
        let runtime = RepositoryRuntimeController(
            gitService: GitService(),
            githubURLLookup: { repository in try await probe.lookup(repository) }
        )
        runtime.delegate = delegate

        runtime.scheduleGitHubURLLookups(for: [repository], forceRefresh: false)
        try await waitUntil(description: "in-flight GitHub URL lookup") {
            await probe.hasStarted(repository.canonicalURL)
        }

        await runtime.cancelAndDrain()

        let cancellationCount = await probe.cancellationCountValue()
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(runtime.githubResolutionSnapshot.hasLookupTask)
        await runtime.finishShutdown()
    }

    func testTargetedGitHubInvalidationRejectsStaleResultWithoutCancellingOtherLookup() async throws {
        let first = makeRuntimeRepository(path: "runtime-stale-first")
        let second = makeRuntimeRepository(path: "runtime-stale-second")
        let probe = GitHubLookupContinuationProbe()
        let delegate = RuntimeTestDelegate(repositories: [first, second])
        let runtime = RepositoryRuntimeController(
            gitService: GitService(),
            githubURLLookup: { repository in await probe.lookup(repository) }
        )
        runtime.delegate = delegate

        runtime.scheduleGitHubURLLookups(for: [first, second], forceRefresh: false)
        try await waitUntil(description: "parallel GitHub URL lookups") {
            let firstCount = await probe.callCount(for: first.canonicalURL)
            let secondCount = await probe.callCount(for: second.canonicalURL)
            return firstCount == 1 && secondCount == 1
        }
        let secondGeneration = runtime.githubResolutionSnapshot.generations[second.id]
        let staleURL = URL(string: "https://github.com/stale/first")
        let freshURL = URL(string: "https://github.com/fresh/first")
        let secondURL = URL(string: "https://github.com/fresh/second")

        runtime.invalidateGitHubURLLookup(for: first.id)
        await probe.finishNext(for: first.canonicalURL, with: staleURL)

        try await waitUntil(description: "replacement GitHub URL lookup") {
            await probe.callCount(for: first.canonicalURL) == 2
        }
        XCTAssertNil(runtime.snapshot.githubURLs[first.id])
        XCTAssertEqual(runtime.githubResolutionSnapshot.generations[second.id], secondGeneration)
        let secondCallCount = await probe.callCount(for: second.canonicalURL)
        XCTAssertEqual(secondCallCount, 1)

        await probe.finishNext(for: first.canonicalURL, with: freshURL)
        await probe.finishNext(for: second.canonicalURL, with: secondURL)
        try await waitUntil(description: "fresh GitHub URL results") {
            runtime.snapshot.githubURLs[first.id] == freshURL
                && runtime.snapshot.githubURLs[second.id] == secondURL
                && !runtime.githubResolutionSnapshot.hasLookupTask
        }

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }

    func testTargetedAndExplicitFullGitHubRefreshScopesLookups() async throws {
        let first = makeRuntimeRepository(path: "runtime-refresh-first")
        let second = makeRuntimeRepository(path: "runtime-refresh-second")
        let probe = ImmediateGitHubLookupProbe()
        let delegate = RuntimeTestDelegate(repositories: [first, second])
        let runtime = RepositoryRuntimeController(
            gitService: GitService(),
            githubURLLookup: { repository in await probe.lookup(repository) }
        )
        runtime.delegate = delegate

        runtime.scheduleGitHubURLLookups(for: [first, second], forceRefresh: false)
        try await waitUntil(description: "initial GitHub URL results") {
            let firstCount = await probe.callCount(for: first.canonicalURL)
            let secondCount = await probe.callCount(for: second.canonicalURL)
            return firstCount == 1 && secondCount == 1
        }

        let changedRescan = CatalogEffectPlan.restored(
            changedRepositoryIDs: [first.id],
            refreshUpstream: false,
            clearsStatusMessage: false
        )
        XCTAssertEqual(
            changedRescan.runtimeSteps[1],
            .scheduleGitHubURLLookups(target: .changed, forceRefresh: true)
        )
        runtime.scheduleGitHubURLLookups(for: [first], forceRefresh: true)
        try await waitUntil(description: "targeted GitHub URL refresh") {
            await probe.callCount(for: first.canonicalURL) == 2
        }
        let secondCallCountAfterTargetedRefresh = await probe.callCount(for: second.canonicalURL)
        XCTAssertEqual(secondCallCountAfterTargetedRefresh, 1)

        runtime.scheduleGitHubURLLookups(for: [first, second], forceRefresh: true)
        try await waitUntil(description: "explicit full GitHub URL refresh") {
            let firstCount = await probe.callCount(for: first.canonicalURL)
            let secondCount = await probe.callCount(for: second.canonicalURL)
            return firstCount == 3 && secondCount == 2
        }

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }
    func testTargetedGitHubRefreshSkipsUnrelatedIdentityReconciliation() async throws {
        let first = makeRuntimeRepository(path: "runtime-targeted-first")
        let second = makeRuntimeRepository(path: "runtime-targeted-second")
        let changedSecond = makeRuntimeRepository(
            id: second.id,
            path: "runtime-targeted-second-replaced"
        )
        let probe = ImmediateGitHubLookupProbe()
        let delegate = RuntimeTestDelegate(repositories: [first, second])
        let runtime = RepositoryRuntimeController(
            gitService: GitService(),
            githubURLLookup: { repository in await probe.lookup(repository) }
        )
        runtime.delegate = delegate

        runtime.scheduleGitHubURLLookups(for: [first, second], forceRefresh: false)
        try await waitUntil(description: "initial targeted GitHub URLs") {
            runtime.githubResolutionSnapshot.completedRepositoryIDs == Set([first.id, second.id])
        }
        let secondURL = try XCTUnwrap(runtime.snapshot.githubURLs[second.id])

        delegate.repositories = [first, changedSecond]
        runtime.scheduleGitHubURLLookups(for: [first], forceRefresh: false)

        XCTAssertEqual(runtime.snapshot.githubURLs[second.id], secondURL)
        XCTAssertTrue(runtime.githubResolutionSnapshot.completedRepositoryIDs.contains(second.id))

        let fullReconciliationEffect = CatalogEffectPlan(
            changedRepositoryIDs: [],
            removedRepositoryIDs: [],
            uiReconciliation: CatalogUIReconciliation(invalidatesSelectedRepositoryWork: false),
            messagePolicy: CatalogMessagePolicy(
                clearsStatusMessage: false,
                clearsErrorMessage: false
            ),
            sourceRescanCancellationID: nil,
            runtimeSteps: [
                .scheduleGitHubURLLookups(target: .all, forceRefresh: false)
            ]
        )
        let change = CatalogChange(
            state: delegate.state,
            sourceScans: [:],
            standaloneRepositories: [:],
            repositories: [first, changedSecond],
            scanMessages: [:],
            effect: fullReconciliationEffect
        )
        await runtime.applyCatalogChange(change)

        let changedSecondURL = try XCTUnwrap(
            URL(string: "https://github.com/cache/\(changedSecond.canonicalURL.lastPathComponent)")
        )
        try await waitUntil(description: "full GitHub identity reconciliation") {
            runtime.snapshot.githubURLs[changedSecond.id] == changedSecondURL
        }

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }

    func testGitConfigEventInvalidatesOnlyAffectedRepository() async throws {
        let directory = try makeTestDirectory()
        let first = makeRuntimeRepository(
            path: directory.appendingPathComponent("config-first", isDirectory: true).path
        )
        let second = makeRuntimeRepository(
            path: directory.appendingPathComponent("config-second", isDirectory: true).path
        )
        let probe = ImmediateGitHubLookupProbe()
        let delegate = RuntimeTestDelegate(repositories: [first, second])
        let runtime = RepositoryRuntimeController(
            gitService: GitService(),
            githubURLLookup: { repository in await probe.lookup(repository) }
        )
        runtime.delegate = delegate

        runtime.scheduleGitHubURLLookups(for: [first, second], forceRefresh: false)
        try await waitUntil(description: "GitHub URLs before config event") {
            runtime.githubResolutionSnapshot.completedRepositoryIDs == Set([first.id, second.id])
        }
        let secondURL = try XCTUnwrap(runtime.snapshot.githubURLs[second.id])
        let secondGeneration = runtime.githubResolutionSnapshot.generations[second.id]
        let configPath = first.canonicalURL.appendingPathComponent(".git/config").path

        await runtime.routeRepositoryFileEvents(
            FileEventBatch(
                paths: [configPath],
                sourceRescanPaths: [],
                requiresFullRescan: false
            ),
            repositoryID: first.id
        )

        XCTAssertEqual(runtime.snapshot.githubURLs[second.id], secondURL)
        XCTAssertEqual(runtime.githubResolutionSnapshot.generations[second.id], secondGeneration)
        XCTAssertGreaterThan(
            runtime.githubResolutionSnapshot.generations[first.id] ?? 0,
            secondGeneration ?? 0
        )

        await runtime.cancelAndDrain()
        await runtime.finishShutdown()
    }
    func testGitHubResolutionBurstCoalescesPayloadlessNotifications() async throws {
        let repositories = (0..<8).map { index in
            makeRuntimeRepository(path: "runtime-burst-\(index)")
        }
        let controller = RepositoryGitHubResolutionController(
            gitService: GitService(),
            githubURLLookup: { repository in
                URL(string: "https://github.com/cache/\(repository.lastPathComponent)")
            }
        )
        defer { controller.finishShutdown() }
        controller.update(context: RepositoryRuntimeContext(
            state: PersistedState(),
            repositories: repositories,
            isShuttingDown: false
        ))
        let stream = controller.events

        controller.scheduleGitHubURLLookups(for: repositories, forceRefresh: false)
        try await waitUntil(description: "GitHub URL burst") {
            controller.snapshot.completedRepositoryIDs == Set(repositories.map(\.id))
        }

        XCTAssertEqual(controller.pendingEventCountForTesting, 1)
        XCTAssertEqual(controller.snapshot.githubURLs.count, repositories.count)
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event, .urlResolved)
        controller.finishShutdown()
        let terminal = await iterator.next()
        XCTAssertNil(terminal)
    }
}
