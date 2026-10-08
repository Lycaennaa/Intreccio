import Foundation

@MainActor
final class RepositoryFileEventCoverageReadiness {
    private struct Subscription {
        let monitor: FileSystemEventMonitor
        let id: UUID
    }

    private var sourceSubscriptions: [RepositoryFileEventSourceGroupKey: Subscription] = [:]
    private var repositorySubscriptions: [UUID: Subscription] = [:]
    private var sourceReadiness: [RepositoryFileEventSourceGroupKey: Bool] = [:]
    private var repositoryReadiness: [UUID: Bool] = [:]
    private var changeHandler: (() async -> Void)?

    func setChangeHandler(_ handler: @escaping () async -> Void) {
        changeHandler = handler
    }

    func observeSourceMonitor(
        _ monitor: FileSystemEventMonitor,
        groupKey: RepositoryFileEventSourceGroupKey
    ) {
        removeSourceMonitor(groupKey: groupKey)
        sourceReadiness[groupKey] = false
        let subscriptionID = monitor.addReadinessSubscriber { [weak self, weak monitor] ready in
            guard let monitor else { return }
            Task { @MainActor [weak self, weak monitor] in
                guard let self, let monitor else { return }
                await self.recordSourceReadiness(
                    ready,
                    groupKey: groupKey,
                    monitor: monitor
                )
            }
        }
        sourceSubscriptions[groupKey] = Subscription(monitor: monitor, id: subscriptionID)
    }

    func observeRepositoryMonitor(
        _ monitor: FileSystemEventMonitor,
        repositoryID: UUID
    ) {
        removeRepositoryMonitor(repositoryID: repositoryID)
        repositoryReadiness[repositoryID] = false
        let subscriptionID = monitor.addReadinessSubscriber { [weak self, weak monitor] ready in
            guard let monitor else { return }
            Task { @MainActor [weak self, weak monitor] in
                guard let self, let monitor else { return }
                await self.recordRepositoryReadiness(
                    ready,
                    repositoryID: repositoryID,
                    monitor: monitor
                )
            }
        }
        repositorySubscriptions[repositoryID] = Subscription(
            monitor: monitor,
            id: subscriptionID
        )
    }

    func removeSourceMonitor(groupKey: RepositoryFileEventSourceGroupKey) {
        if let subscription = sourceSubscriptions.removeValue(forKey: groupKey) {
            subscription.monitor.removeReadinessSubscriber(subscription.id)
        }
        sourceReadiness.removeValue(forKey: groupKey)
    }

    func removeRepositoryMonitor(repositoryID: UUID) {
        if let subscription = repositorySubscriptions.removeValue(forKey: repositoryID) {
            subscription.monitor.removeReadinessSubscriber(subscription.id)
        }
        repositoryReadiness.removeValue(forKey: repositoryID)
    }

    func sourceMonitorIsReady(_ groupKey: RepositoryFileEventSourceGroupKey) -> Bool {
        sourceReadiness[groupKey] == true
    }

    func repositoryMonitorIsReady(_ repositoryID: UUID) -> Bool {
        repositoryReadiness[repositoryID] == true
    }

    func stop() {
        sourceSubscriptions.values.forEach {
            $0.monitor.removeReadinessSubscriber($0.id)
        }
        repositorySubscriptions.values.forEach {
            $0.monitor.removeReadinessSubscriber($0.id)
        }
        sourceSubscriptions.removeAll()
        repositorySubscriptions.removeAll()
        sourceReadiness.removeAll()
        repositoryReadiness.removeAll()
        changeHandler = nil
    }

    private func recordSourceReadiness(
        _ ready: Bool,
        groupKey: RepositoryFileEventSourceGroupKey,
        monitor: FileSystemEventMonitor
    ) async {
        guard let subscription = sourceSubscriptions[groupKey],
              subscription.monitor === monitor,
              sourceReadiness[groupKey] != ready else { return }
        sourceReadiness[groupKey] = ready
        await changeHandler?()
    }

    private func recordRepositoryReadiness(
        _ ready: Bool,
        repositoryID: UUID,
        monitor: FileSystemEventMonitor
    ) async {
        guard let subscription = repositorySubscriptions[repositoryID],
              subscription.monitor === monitor,
              repositoryReadiness[repositoryID] != ready else { return }
        repositoryReadiness[repositoryID] = ready
        await changeHandler?()
    }
}
