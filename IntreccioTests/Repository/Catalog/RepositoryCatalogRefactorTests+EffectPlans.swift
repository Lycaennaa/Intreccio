import Foundation
import XCTest
@testable import Intreccio

extension RepositoryCatalogRefactorTests {
    func testEffectPlansMapRuntimeStepsForEachCommand() {
        let changedID = UUID()
        let removedID = UUID()
        let sourceID = UUID()

        let restored = CatalogEffectPlan.restored(
            changedRepositoryIDs: [changedID],
            refreshUpstream: true,
            clearsStatusMessage: true
        )
        XCTAssertEqual(restored.changedRepositoryIDs, [changedID])
        XCTAssertTrue(restored.messagePolicy.clearsStatusMessage)
        XCTAssertEqual(restored.runtimeSteps, [
            .setSelectedRepository,
            .scheduleGitHubURLLookups(target: .changed, forceRefresh: true),
            .enqueueStatusRefreshes(target: .changed, refreshUpstream: true),
            .reconcileRepositories(updateEventCoverage: true),
        ])
        let startup = CatalogEffectPlan.startupRestored(
            changedRepositoryIDs: [],
            refreshUpstream: true,
            clearsStatusMessage: false
        )
        XCTAssertEqual(startup.runtimeSteps, [
            .setSelectedRepository,
            .scheduleGitHubURLLookups(target: .all, forceRefresh: true),
            .enqueueStatusRefreshes(target: .changed, refreshUpstream: true),
            .reconcileRepositories(updateEventCoverage: true),
        ])
        let rescanned = CatalogEffectPlan.sourceRescanned(changedRepositoryIDs: [changedID])
        XCTAssertEqual(rescanned.runtimeSteps, [
            .scheduleGitHubURLLookups(target: .changed, forceRefresh: true),
            .reconcileRepositories(updateEventCoverage: true),
            .enqueueStatusRefreshes(target: .changed, refreshUpstream: false),
        ])

        let added = CatalogEffectPlan.sourceAdded()
        XCTAssertEqual(added.runtimeSteps, [
            .scheduleGitHubURLLookups(target: .all, forceRefresh: false),
            .updateEventCoverage,
            .enqueueStatusRefreshes(target: .all, refreshUpstream: true),
        ])

        let removed = CatalogEffectPlan.sourceRemoved(
            sourceID: sourceID,
            removedRepositoryIDs: [removedID]
        )
        XCTAssertEqual(removed.removedRepositoryIDs, [removedID])
        XCTAssertEqual(removed.sourceRescanCancellationID, sourceID)
        XCTAssertEqual(removed.runtimeSteps, [
            .scheduleGitHubURLLookups(target: .all, forceRefresh: false),
            .removeRepositories(clearRequestState: false, synchronizeSelectedRepository: false),
            .updateEventCoverage,
        ])

        let excluded = CatalogEffectPlan.sourceExcluded(removedRepositoryIDs: [removedID])
        XCTAssertEqual(excluded.runtimeSteps, [
            .scheduleGitHubURLLookups(target: .all, forceRefresh: false),
            .removeRepositories(clearRequestState: true, synchronizeSelectedRepository: true),
            .updateEventCoverage,
        ])
        XCTAssertEqual(CatalogEffectPlan.exclusionRestored.runtimeSteps, [])
        XCTAssertEqual(CatalogEffectPlan.sourceReauthorized.runtimeSteps, [.updateEventCoverage])
        XCTAssertEqual(CatalogEffectPlan.scanFailed.runtimeSteps, [])
    }

    func testSourceGenerationRejectsStaleWork() {
        let lifecycle = RepositoryCatalogLifecycle()
        let generation = RepositoryCatalogGeneration(lifecycle: lifecycle)
        let sourceID = UUID()
        let first = generation.beginSourceRescan(sourceID)
        let second = generation.beginSourceRescan(sourceID)

        XCTAssertFalse(generation.isCurrentSourceRescan(sourceID: sourceID, generation: first))
        XCTAssertTrue(generation.isCurrentSourceRescan(sourceID: sourceID, generation: second))
        lifecycle.isShuttingDown = true
        XCTAssertFalse(generation.isCurrentSourceRescan(sourceID: sourceID, generation: second))
    }
}