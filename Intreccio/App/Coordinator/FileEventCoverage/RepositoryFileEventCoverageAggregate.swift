import Foundation

@MainActor
final class RepositoryFileEventCoverageAggregate {
    private let topology: RepositoryFileEventCoverageWatcherTopology
    private let readiness: RepositoryFileEventCoverageReadiness
    private var cachedSnapshot: RepositoryFileEventCoverageSnapshot?
#if DEBUG
    private(set) var buildCountForTesting = 0
#endif

    init(
        topology: RepositoryFileEventCoverageWatcherTopology,
        readiness: RepositoryFileEventCoverageReadiness
    ) {
        self.topology = topology
        self.readiness = readiness
    }

    var snapshot: RepositoryFileEventCoverageSnapshot {
        if let cachedSnapshot { return cachedSnapshot }
        let liveSourceGroupKeys: Set<RepositoryFileEventSourceGroupKey> = Set(
            topology.sourceEventMonitors.keys.filter {
                readiness.sourceMonitorIsReady($0)
            }
        )
        let liveSourceWatcherIDs: Set<UUID> = Set(
            topology.sourceEventWatcherGroups.compactMap { sourceID, groupKey in
                liveSourceGroupKeys.contains(groupKey) ? sourceID : nil
            }
        )
        let liveRepositoryWatcherIDs: Set<UUID> = Set(
            topology.repositoryEventWatchers.keys.filter {
                readiness.repositoryMonitorIsReady($0)
            }
        )
        let liveCoveredRepositoryIDs: Set<UUID> = Set(
            topology.repositoryCoverageOwners.compactMap { repositoryID, owner in
                switch owner {
                case .watchRoot(let sourceID):
                    guard let groupKey = topology.sourceEventWatcherGroups[sourceID],
                          liveSourceGroupKeys.contains(groupKey) else { return nil }
                    return repositoryID
                case .independentRepository:
                    return liveRepositoryWatcherIDs.contains(repositoryID) ? repositoryID : nil
                }
            }
        )
        let snapshot = RepositoryFileEventCoverageSnapshot(
            sourceWatcherIDs: Set(topology.sourceEventWatcherGroups.keys),
            sourceEventStreamCount: liveSourceGroupKeys.count,
            repositoryWatcherIDs: Set(topology.repositoryEventWatchers.keys),
            coveredRepositoryIDs: Set(topology.repositoryCoverageOwners.keys),
            liveSourceWatcherIDs: liveSourceWatcherIDs,
            liveCoveredRepositoryIDs: liveCoveredRepositoryIDs
        )
        cachedSnapshot = snapshot
#if DEBUG
        buildCountForTesting += 1
#endif
        return snapshot
    }

    func invalidate() {
        cachedSnapshot = nil
    }
}