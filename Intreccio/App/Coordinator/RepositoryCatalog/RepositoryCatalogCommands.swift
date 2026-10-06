import Foundation

nonisolated enum RepositoryCatalogCommandAdmission: Sendable {
    case preserve
    case coalesce
}

actor RepositoryCatalogCommandGate {
    private struct Waiter {
        let id: UUID
        let admissionTicket: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct ProducerWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maximumWaiters: Int
    private var locked = false
    private var waiters: [Waiter?]
    private var waiterHead = 0
    private var waiterTail = 0
    private var waiterCount = 0
    private var waiterIndexes: [UUID: Int] = [:]
    private var producerWaiter: ProducerWaiter?
    private var admissionGeneration: UInt64 = 0
    private var nextAdmissionTicket: UInt64 = 0
    private var nextTicketToAdmit: UInt64 = 0
#if DEBUG
    private var admissionRequestCount = 0
    private var producerWakeCount = 0
#endif

    init(maximumWaiters: Int = 128) {
        self.maximumWaiters = max(1, maximumWaiters)
        waiters = Array(repeating: nil, count: max(1, maximumWaiters))
    }

#if DEBUG
    var waitingCountForTesting: Int { waiterCount }
    var admissionRequestCountForTesting: Int { admissionRequestCount }
    var admittedCountForTesting: Int { (locked ? 1 : 0) + waiterCount }
    var producerWaiterCountForTesting: Int { producerWaiter == nil ? 0 : 1 }
    var producerWakeCountForTesting: Int { producerWakeCount }
#endif

    func admit(_ admission: RepositoryCatalogCommandAdmission = .preserve) async throws {
        try await acquire(admission)
    }

    func execute<Value: Sendable>(
        admission: RepositoryCatalogCommandAdmission = .preserve,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire(admission)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    func release() {
        if waiterCount == 0 {
            locked = false
        } else {
            dequeue().continuation.resume(returning: true)
        }
        signalProducerWaiters()
    }

    func cancelPendingCommands() {
        admissionGeneration &+= 1
        while waiterCount > 0 {
            dequeue().continuation.resume(returning: false)
        }
        nextTicketToAdmit = nextAdmissionTicket
        signalProducerWaiters()
    }

    private func acquire(_ admission: RepositoryCatalogCommandAdmission) async throws {
        guard !Task.isCancelled else { throw CancellationError() }
        if case .coalesce = admission,
           locked,
           (waiterCount >= maximumWaiters || nextAdmissionTicket != nextTicketToAdmit) {
            throw RepositoryCatalogCommandError.coalesced
        }

        let ticket = nextAdmissionTicket
        nextAdmissionTicket &+= 1
        let generation = admissionGeneration
#if DEBUG
        admissionRequestCount += 1
#endif
        let admitted = await withTaskCancellationHandler {
            while ticket != nextTicketToAdmit {
                guard generation == admissionGeneration else { return false }
                if ticket < nextTicketToAdmit { return false }
                await pauseAfterFullProducerSignal()
            }
            guard generation == admissionGeneration else { return false }
            if Task.isCancelled {
                if ticket == nextTicketToAdmit {
                    nextTicketToAdmit &+= 1
                    signalProducerWaiters()
                }
                return false
            }

            if !locked {
                locked = true
                nextTicketToAdmit &+= 1
                signalProducerWaiters()
                return true
            }

            while waiterCount >= maximumWaiters {
                if await waitForProducerSignal() {
                    await pauseAfterFullProducerSignal()
                }
                guard generation == admissionGeneration,
                      ticket == nextTicketToAdmit else { return false }
                if Task.isCancelled {
                    nextTicketToAdmit &+= 1
                    signalProducerWaiters()
                    return false
                }
            }
            guard generation == admissionGeneration,
                  ticket == nextTicketToAdmit else { return false }

            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    if Task.isCancelled || generation != admissionGeneration {
                        continuation.resume(returning: false)
                    } else {
                        enqueue(Waiter(
                            id: id,
                            admissionTicket: ticket,
                            continuation: continuation
                        ))
                        nextTicketToAdmit &+= 1
                        signalProducerWaiters()
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        } onCancel: {
            Task { await self.cancelProducer(ticket: ticket, generation: generation) }
        }
        guard admitted else { throw CancellationError() }
    }

    private func waitForProducerSignal() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                installProducerWaiter(ProducerWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelProducerWaiter(id) }
        }
    }

    private func installProducerWaiter(_ waiter: ProducerWaiter) {
        guard !Task.isCancelled else {
            waiter.continuation.resume(returning: false)
            return
        }
        guard producerWaiter == nil else {
            waiter.continuation.resume(returning: true)
            return
        }
        producerWaiter = waiter
    }

    private func cancelProducerWaiter(_ id: UUID) {
        guard producerWaiter?.id == id else { return }
        let continuation = producerWaiter?.continuation
        producerWaiter = nil
        continuation?.resume(returning: false)
    }

    private func pauseAfterFullProducerSignal() async {
        if Task.isCancelled {
            let sleeper = Task.detached { try? await Task.sleep(for: .milliseconds(1)) }
            await sleeper.value
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func cancelProducer(ticket: UInt64, generation: UInt64) {
        guard generation == admissionGeneration, ticket == nextTicketToAdmit else { return }
        nextTicketToAdmit &+= 1
        signalProducerWaiters()
    }

    private func signalProducerWaiters() {
        let waiter = producerWaiter
        producerWaiter = nil
#if DEBUG
        if waiter != nil { producerWakeCount += 1 }
#endif
        waiter?.continuation.resume(returning: false)
    }

    private func enqueue(_ waiter: Waiter) {
        compactWaiters()
        guard waiterCount < waiters.count else {
            preconditionFailure("Repository catalog command queue invariant violated")
        }
        let index = (0..<waiterCount).first {
            waiters[$0]!.admissionTicket > waiter.admissionTicket
        } ?? waiterCount
        if index < waiterCount {
            for shiftedIndex in stride(from: waiterCount, to: index, by: -1) {
                waiters[shiftedIndex] = waiters[shiftedIndex - 1]
                waiterIndexes[waiters[shiftedIndex]!.id] = shiftedIndex
            }
        }
        waiters[index] = waiter
        waiterIndexes[waiter.id] = index
        waiterCount += 1
        normalizeHead()
    }

    private func compactWaiters() {
        var ordered: [Waiter] = []
        ordered.reserveCapacity(waiterCount)
        for index in 0..<waiters.count {
            if let waiter = waiters[index] { ordered.append(waiter) }
        }
        guard ordered.count == waiterCount else {
            preconditionFailure("Repository catalog command queue invariant violated")
        }
        ordered.sort { $0.admissionTicket < $1.admissionTicket }
        waiters = Array(repeating: nil, count: waiters.count)
        for (index, waiter) in ordered.enumerated() {
            waiters[index] = waiter
            waiterIndexes[waiter.id] = index
        }
        normalizeHead()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiterIndexes.removeValue(forKey: id),
              let waiter = waiters[index] else { return }
        waiters[index] = nil
        waiterCount -= 1
        compactWaiters()
        waiter.continuation.resume(returning: false)
        signalProducerWaiters()
    }

    private func normalizeHead() {
        waiterHead = 0
        waiterTail = waiterCount == waiters.count ? 0 : waiterCount
    }

    private func dequeue() -> Waiter {
        compactWaiters()
        guard let waiter = waiters[0] else {
            preconditionFailure("Repository catalog command queue invariant violated")
        }
        waiters[0] = nil
        waiterIndexes[waiter.id] = nil
        waiterCount -= 1
        compactWaiters()
        return waiter
    }
}

@MainActor
final class RepositoryCatalog {

    let stateStore: StateStore
    let bookmarkStore: BookmarkStore
    let scanner: RepoScanner
    let gitService: GitService
    let lifecycle: RepositoryCatalogLifecycle
    let state: RepositoryCatalogState
    let generation: RepositoryCatalogGeneration
    let sourceOperations: RepositoryCatalogSourceOperations
    let committer: RepositoryCatalogCommitter
    let commandGate = RepositoryCatalogCommandGate()
    weak var delegate: (any RepositoryCatalogDelegate)? {
        didSet { committer.delegate = delegate }
    }

    var sourceScans: [UUID: RepoScanResult] { state.sourceScans }
    var standaloneURLs: [UUID: URL] { state.standaloneURLs }
    var repositories: [RepoDescriptor] { state.repositories }
    var repositoryIndex: RepositoryCatalogIndex { state.repositoryIndex }
    var scanMessages: [UUID: String] { state.scanMessages }
    var isShuttingDown: Bool {
        get { lifecycle.isShuttingDown }
        set { lifecycle.isShuttingDown = newValue }
    }
    var fullRescanGeneration: UInt64 { generation.fullRescanGeneration }
    var sourceRefreshGenerations: [UUID: UInt64] { generation.sourceRefreshGenerations }

    var fullRescanTask: Task<Void, Never>?
    var sourceRefreshTasks: [UUID: Task<Void, Never>] = [:]
    var hasAcceptedLoadedState = false
    private var stateAcceptancePending = false
    private var commandTasks: [UUID: (
        cancel: @Sendable () -> Void,
        wait: @Sendable () async -> Void
    )] = [:]

#if DEBUG
    var commandTaskCountForTesting: Int { commandTasks.count }
#endif


    init(
        stateStore: StateStore,
        bookmarkStore: BookmarkStore,
        scanner: RepoScanner,
        gitService: GitService,
        fixture: RepositoryCatalogFixture? = nil,
        watchRootScanOperation: (@MainActor @Sendable (WatchRoot) async throws -> RepositoryWatchRootScanOutcome)? = nil
    ) {
        self.stateStore = stateStore
        self.bookmarkStore = bookmarkStore
        self.scanner = scanner
        self.gitService = gitService
        let lifecycle = RepositoryCatalogLifecycle()
        let state = RepositoryCatalogState(fixture: fixture)
        let generation = RepositoryCatalogGeneration(lifecycle: lifecycle)
        self.lifecycle = lifecycle
        self.state = state
        self.generation = generation
        let resolver = RepositorySourceResolver(
            bookmarkStore: bookmarkStore,
            scanner: scanner,
            gitService: gitService
        )
        sourceOperations = RepositoryCatalogSourceOperations(
            catalogState: state,
            bookmarkStore: bookmarkStore,
            gitService: gitService,
            sourceResolver: resolver,
            lifecycle: lifecycle,
            generation: generation,
            watchRootScanOperation: watchRootScanOperation
        )
        committer = RepositoryCatalogCommitter(
            stateStore: stateStore,
            lifecycle: lifecycle
        )
    }

    deinit {
        fullRescanTask?.cancel()
        sourceRefreshTasks.values.forEach { $0.cancel() }
        commandTasks.values.forEach { $0.cancel() }
    }

    func executeCommand<Value: Sendable>(
        admission: RepositoryCatalogCommandAdmission = .preserve,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
        let id = UUID()
        return try await commandGate.execute(admission: admission) { [weak self] in
            guard let self, !self.isShuttingDown, !Task.isCancelled else {
                throw CancellationError()
            }
            let commandTask = Task { @MainActor in
                try Task.checkCancellation()
                return try await operation()
            }
            self.commandTasks[id] = (
                cancel: { commandTask.cancel() },
                wait: { _ = try? await commandTask.value }
            )
            do {
                let value = try await withTaskCancellationHandler {
                    try await commandTask.value
                } onCancel: {
                    commandTask.cancel()
                }
                self.commandTasks[id] = nil
                return value
            } catch {
                self.commandTasks[id] = nil
                throw error
            }
        }
    }


    func startup() async throws {
        stateAcceptancePending = true
        try await executeCommand { [weak self] in
            guard let self, let delegate else { throw CancellationError() }
            let loaded = await stateStore.load()
            guard let state = delegate.repositoryCatalog(didLoad: loaded) else {
                throw CancellationError()
            }
            hasAcceptedLoadedState = true
            stateAcceptancePending = false
            delegate.repositoryCatalogWillBeginSourceCommand()
            let transaction = try await sourceOperations.prepareRestoreSources(
                state: state,
                generation: nil,
                refreshUpstream: true,
                initialStartup: true
            )
            try await commit(transaction)
        }
    }

    func restoreSources() async throws {
        try await executeCommand { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try sourceCommandState()
            let transaction = try await sourceOperations.prepareRestoreSources(
                state: state,
                generation: nil,
                refreshUpstream: true,
                initialStartup: false
            )
            try await commit(transaction)
        }
    }

    func rescanAll(refreshUpstream: Bool) {
        guard !isShuttingDown else { return }
        let rescanGeneration = generation.beginFullRescan()
        fullRescanTask?.cancel()
        fullRescanTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await executeCommand { [weak self] in
                    guard let self, generation.isCurrentFullRescan(rescanGeneration) else {
                        throw CancellationError()
                    }
                    let state = try sourceCommandState()
                    let transaction = try await sourceOperations.prepareRestoreSources(
                        state: state,
                        generation: rescanGeneration,
                        refreshUpstream: refreshUpstream,
                        initialStartup: false
                    )
                    try await commit(transaction)
                }
            } catch is CancellationError {
            } catch {
                delegate?.repositoryCatalog(didFail: .sourcesPersistence(String(describing: error)))
            }
            guard generation.fullRescanGeneration == rescanGeneration else { return }
            fullRescanTask = nil
        }
    }

    func rescanSource(_ sourceID: UUID) {
        guard !isShuttingDown else { return }
        let rescanGeneration = generation.beginSourceRescan(sourceID)
        sourceRefreshTasks[sourceID]?.cancel()
        sourceRefreshTasks[sourceID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await executeCommand(admission: .coalesce) { [weak self] in
                    guard let self,
                          generation.isCurrentSourceRescan(
                              sourceID: sourceID,
                              generation: rescanGeneration
                          ) else {
                        throw CancellationError()
                    }
                    let state = try sourceCommandState()
                    guard let transaction = try await sourceOperations.prepareRescanSource(
                        sourceID,
                        generation: rescanGeneration,
                        state: state
                    ) else { return }
                    try await commit(transaction)
                }
            } catch RepositoryCatalogCommandError.coalesced {
            } catch is CancellationError {
            } catch {
                delegate?.repositoryCatalog(didFail: .sourceRescanPersistence(String(describing: error)))
            }
            guard generation.sourceRefreshGenerations[sourceID] == rescanGeneration else { return }
            sourceRefreshTasks[sourceID] = nil
        }
    }

    func addWatchRoot(_ selectedURL: URL) async throws -> CatalogCommandOutcome {
        try await executeCommand { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try sourceCommandState()
            let transaction = try await sourceOperations.prepareAddWatchRoot(selectedURL, state: state)
            try await commit(transaction)
            return .changed
        }
    }

    func addStandaloneRepository(_ selectedURL: URL) async throws -> CatalogCommandOutcome {
        try await executeCommand { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try sourceCommandState()
            let preparation = try await sourceOperations.prepareAddStandaloneRepository(
                selectedURL,
                state: state
            )
            return try await commit(preparation)
        }
    }
    func createLocalRepository(named name: String, in parentDirectory: URL) async throws -> CatalogCommandOutcome {
        try await executeCommand { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try sourceCommandState()
            let receipt = try await gitService.createLocalRepository(named: name, in: parentDirectory)
            return try await commitCreatedRepository(receipt: receipt, state: state)
        }
    }

    func cloneRepository(
        from sourceURL: URL,
        into destinationParent: URL,
        control: ProcessControl? = nil,
        progress: @escaping @Sendable (RepositoryCloneProgress) -> Void = { _ in }
    ) async throws -> CatalogCommandOutcome {
        try await executeCommand { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try sourceCommandState()
            let receipt = try await gitService.cloneRepository(
                from: sourceURL,
                into: destinationParent,
                control: control,
                progress: progress
            )
            return try await commitCreatedRepository(receipt: receipt, state: state)
        }
    }

    private func commitCreatedRepository(
        receipt: RepositoryCreationReceipt,
        state: PersistedState
    ) async throws -> CatalogCommandOutcome {
        do {
            let preparation = try await sourceOperations.prepareAddStandaloneRepository(
                receipt.url,
                state: state
            )
            let outcome = try await commit(preparation)
            if case .changed = outcome {
                return .createdRepository(receipt.url)
            }
            return outcome
        } catch let operationError {
            do {
                try RepositoryPathPolicy.removeCreatedRepository(
                    at: receipt.url,
                    expectedResourceID: receipt.resourceID
                )
            } catch let cleanupError {
                throw RepositoryCatalogCommandError.createdRepositoryCleanupFailed(
                    operation: String(describing: operationError),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw operationError
        }
    }

    func removeSource(_ sourceID: UUID) async throws -> CatalogCommandOutcome {
        try await executeCommand { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try sourceCommandState()
            let transaction = try sourceOperations.prepareRemoveSource(sourceID, state: state)
            try await commit(transaction)
            return .changed
        }
    }

    func excludeRepository(_ repositoryID: UUID) async throws -> CatalogCommandOutcome {
        try await executeCommand { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try sourceCommandState()
            guard let repository = repositories.first(where: { $0.id == repositoryID }),
                  case .watchRoot(let sourceID, _, _) = repository.source,
                  let relativePath = repository.relativePath else {
                return .noChange
            }
            let preparation = try await sourceOperations.prepareExcludePath(
                sourceID: sourceID,
                path: relativePath,
                state: state
            )
            return try await commit(preparation)
        }
    }

    func excludeFolder(sourceID: UUID, path: String) async throws -> CatalogCommandOutcome {
        try await executeCommand { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try sourceCommandState()
            guard !RepositoryPathPolicy.normalizedRelativePath(path).isEmpty else {
                return .noChange
            }
            let preparation = try await sourceOperations.prepareExcludePath(
                sourceID: sourceID,
                path: path,
                state: state
            )
            return try await commit(preparation)
        }
    }

    func restoreExclusion(sourceID: UUID, path: String) async throws -> CatalogCommandOutcome {
        let outcome = try await executeCommand { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try sourceCommandState()
            let preparation = try sourceOperations.prepareRestoreExclusion(
                sourceID: sourceID,
                path: path,
                state: state
            )
            return try await commit(preparation)
        }
        if case .changed = outcome { rescanAll(refreshUpstream: true) }
        return outcome
    }

    func reauthorizeSource(_ sourceID: UUID, with selectedURL: URL) async throws -> CatalogCommandOutcome {
        let outcome = try await executeCommand { [weak self] in
            guard let self else { throw CancellationError() }
            let state = try sourceCommandState()
            let preparation = try await sourceOperations.prepareReauthorizeSource(
                sourceID,
                selectedURL: selectedURL,
                state: state
            )
            return try await commit(preparation)
        }
        if case .changed = outcome { rescanAll(refreshUpstream: true) }
        return outcome
    }

    func sourceCommandState() throws -> PersistedState {
        guard let delegate, !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
        delegate.repositoryCatalogWillBeginSourceCommand()
        return delegate.repositoryCatalogState
    }

    func saveCurrentState() async throws {
        try await executeCommand { [weak self] in
            guard let self, let delegate, !isShuttingDown else { throw CancellationError() }
            try await stateStore.save(delegate.repositoryCatalogState)
        }
    }

    func saveCurrentUIState() async throws {
        try await executeCommand(admission: .coalesce) { [weak self] in
            guard let self, let delegate, !isShuttingDown else { throw CancellationError() }
            try await stateStore.saveUI(delegate.repositoryCatalogState.uiState)
        }
    }

    func flushCurrentState() async throws {
        guard hasAcceptedLoadedState || !stateAcceptancePending else { return }
        guard let delegate else { throw CancellationError() }
        if isShuttingDown {
            try await stateStore.save(delegate.repositoryCatalogState)
        } else {
            try await saveCurrentState()
        }
    }

    func resumeAfterFailedShutdown() {
        isShuttingDown = false
    }

    func shutdown() async {
        isShuttingDown = true
        generation.invalidateForShutdown()
        let tasks = [fullRescanTask].compactMap { $0 }
            + Array(sourceRefreshTasks.values)
        let commandTasks = Array(self.commandTasks.values)
        tasks.forEach { $0.cancel() }
        commandTasks.forEach { $0.cancel() }
        await commandGate.cancelPendingCommands()
        fullRescanTask = nil
        sourceRefreshTasks.removeAll()
        await TaskCompletionDrain.waitForCompletion(tasks)
        for commandTask in commandTasks {
            await commandTask.wait()
        }
        self.commandTasks.removeAll()
    }

    func cancelSourceRescan(_ sourceID: UUID) {
        generation.cancelSourceRescan(sourceID)
        sourceRefreshTasks.removeValue(forKey: sourceID)?.cancel()
    }

    private func commit(_ preparation: CatalogCommandPreparation) async throws -> CatalogCommandOutcome {
        switch preparation {
        case .changed(let transaction):
            try await commit(transaction)
            return .changed
        case .selectedRepository(let repositoryID):
            return .selectedRepository(repositoryID)
        case .noChange:
            return .noChange
        }
    }

    private func commit(_ transaction: CatalogTransaction) async throws {
        try await committer.commit(transaction, state: state)
    }
}

nonisolated enum RepositoryCatalogCommandError: Error, Equatable, CustomStringConvertible {
    case duplicateWatchRoot
    case coalesced
    case createdRepositoryCleanupFailed(operation: String, cleanup: String)

    var description: String {
        switch self {
        case .duplicateWatchRoot:
            "That folder is already watched."
        case .coalesced:
            "The command was superseded by a newer command."
        case .createdRepositoryCleanupFailed(let operation, let cleanup):
            "\(operation)\n\nCleanup also failed: \(cleanup)"
        }
    }
}