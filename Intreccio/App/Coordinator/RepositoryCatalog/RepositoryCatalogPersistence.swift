import Foundation

@MainActor
final class RepositoryCatalogLifecycle {
    var isShuttingDown = false
}

nonisolated enum CatalogPersistenceOrder: Sendable, Equatable {
    case beforeAcceptance
    case afterAcceptance(clearPersistenceErrorOnSuccess: Bool)
    case acceptanceOnly
}

nonisolated struct CatalogTransaction: Sendable {
    let change: CatalogChange
    let persistenceOrder: CatalogPersistenceOrder
}

nonisolated enum CatalogPersistenceStatus: Sendable, Equatable {
    case notRequested
    case succeeded
    case failed
}

nonisolated struct CatalogCommitResult: Sendable {
    let change: CatalogChange
    let persistenceStatus: CatalogPersistenceStatus
    let clearsPersistenceErrorOnSuccess: Bool
}

@MainActor
final class RepositoryCatalogCommitter {
    let stateStore: StateStore
    let lifecycle: RepositoryCatalogLifecycle
    weak var delegate: (any RepositoryCatalogDelegate)?
#if DEBUG
    var persistenceDidCompleteForTesting: (() -> Void)?
#endif

    init(stateStore: StateStore, lifecycle: RepositoryCatalogLifecycle) {
        self.stateStore = stateStore
        self.lifecycle = lifecycle
    }

    func commit(_ transaction: CatalogTransaction, state: RepositoryCatalogState) async throws {
        guard let delegate else { throw CancellationError() }

        guard !Task.isCancelled, !lifecycle.isShuttingDown else { throw CancellationError() }

        var validatedCatalogData: StateStoreValidatedCatalog?
        if case .afterAcceptance = transaction.persistenceOrder {
            validatedCatalogData = try await stateStore.validateCatalog(transaction.change.state)
        } else {
            validatedCatalogData = nil
        }

        if case .beforeAcceptance = transaction.persistenceOrder {
            try await stateStore.save(transaction.change.state)
#if DEBUG
            persistenceDidCompleteForTesting?()
#endif
        }

        state.accept(transaction.change)
        let acceptedState = delegate.repositoryCatalog(reconcile: transaction.change)

        var persistenceStatus: CatalogPersistenceStatus
        var persistenceError: (any Error)?
        let clearsPersistenceErrorOnSuccess: Bool
        switch transaction.persistenceOrder {
        case .beforeAcceptance:
            persistenceStatus = .succeeded
            clearsPersistenceErrorOnSuccess = false

        case .afterAcceptance(let clears):
            clearsPersistenceErrorOnSuccess = clears
            do {
                try await stateStore.save(
                    acceptedState,
                    validatedCatalogData: validatedCatalogData
                )
                persistenceStatus = .succeeded
            } catch {
                persistenceStatus = .failed
                persistenceError = error
            }

        case .acceptanceOnly:
            persistenceStatus = .notRequested
            clearsPersistenceErrorOnSuccess = false
        }

        await delegate.repositoryCatalog(didCommit: CatalogCommitResult(
            change: transaction.change,
            persistenceStatus: persistenceStatus,
            clearsPersistenceErrorOnSuccess: clearsPersistenceErrorOnSuccess
        ))
        if let persistenceError { throw persistenceError }
    }
}
