import Foundation

@MainActor
extension AppCoordinator {
    func scheduleUIStateSave() {
        guard !isShuttingDown else { return }
        uiSaveTask?.cancel()
        uiSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            do {
                try await catalog.saveCurrentUIState()
                clearStateSaveError()
            } catch RepositoryCatalogCommandError.coalesced {
            } catch {
                guard !isShuttingDown, !Task.isCancelled else { return }
                setStateSaveError("Could not save UI state: \(error)")
            }
        }
    }

    func scheduleRememberedApplicationSave() {
        guard !isShuttingDown else { return }
        rememberedApplicationSaveTask?.cancel()
        rememberedApplicationSaveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await catalog.saveCurrentUIState()
                clearStateSaveError()
            } catch RepositoryCatalogCommandError.coalesced {
            } catch {
                guard !isShuttingDown, !Task.isCancelled else { return }
                setStateSaveError("Could not save UI state: \(error)")
            }
        }
    }

    func setStateSaveError(_ message: String) {
        stateSaveErrorMessage = message
        errorMessage = message
        publish()
    }

    func clearStateSaveError() {
        guard let stateSaveErrorMessage else { return }
        self.stateSaveErrorMessage = nil
        guard errorMessage == stateSaveErrorMessage else { return }
        errorMessage = nil
        publish()
    }

    func flushState() async -> Bool {
        uiSaveTask?.cancel()
        rememberedApplicationSaveTask?.cancel()
        var succeeded = true
        guard catalog.hasAcceptedLoadedState || !hasStarted else { return true }
        do {
            try await catalog.flushCurrentState()
        } catch {
            succeeded = false
            errorMessage = "Could not save state before quitting: \(error)"
            publish()
        }
        return succeeded
    }

    func waitForActiveMutation() async {
        await mutationTask?.value
    }

    func shutdown() async -> Bool {
        isShuttingDown = true
        let tasks = [
            startupTask,
            mutationTask,
            uiSaveTask,
            rememberedApplicationSaveTask,
        ].compactMap { $0 }
        mutationGeneration &+= 1
        tasks.forEach { $0.cancel() }
        startupTask = nil
        mutationTask = nil
        uiSaveTask = nil
        rememberedApplicationSaveTask = nil
        async let catalogShutdown: Void = catalog.shutdown()
        async let runtimeShutdown: Void = runtime.cancelAndDrain()
        async let selectedSessionShutdown: Void = selectedSession.cancelAndDrain()
        await TaskCompletionDrain.waitForCompletion(tasks)
        _ = await (catalogShutdown, runtimeShutdown, selectedSessionShutdown)
        let saved = await flushState()
        guard saved else {
            isShuttingDown = false
            catalog.resumeAfterFailedShutdown()
            runtime.resumeAfterFailedShutdown()
            rescanAll(refreshUpstream: false)
            runtime.enqueueStatusRefreshes(
                for: repositories.map(\.id),
                requestKind: .explicit
            )
            return false
        }
        await runtime.finishShutdown()
        return true
    }

    func assignPersistedState(
        _ persisted: PersistedState,
        updateUI: (inout PersistedUIState) -> Void = { _ in }
    ) {
        var committed = persisted
        var latestUI = state.uiState
        updateUI(&latestUI)
        committed.uiState = latestUI
        state = committed
    }

    func makeSnapshot(sidebarUpdate: SidebarSnapshotUpdate = .structural) -> AppSnapshot {
        AppSnapshot(
            state: state,
            repositories: catalog.repositories,
            scanMessages: catalog.scanMessages,
            runtime: runtime.snapshot,
            selectedSession: selectedSession.snapshot,
            mutationState: mutationState,
            commitMessage: commitMessage,
            usesDefaultCommitMessage: usesDefaultCommitMessage,
            amendSession: amendSession,
            errorMessage: errorMessage,
            stateSaveErrorMessage: stateSaveErrorMessage,
            statusMessage: statusMessage,
            hasLoadedState: hasLoadedState,
            hasStarted: hasStarted,
            sidebarUpdate: sidebarUpdate
        )
    }

    func publish(sidebarUpdate: SidebarSnapshotUpdate = .structural) {
        publishSnapshot(makeSnapshot(sidebarUpdate: sidebarUpdate))
    }

}
