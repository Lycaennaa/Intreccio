import Foundation

@MainActor
struct SelectedRepositorySessionSnapshot {
    let diffState: SelectedDiffState
    let historyScope: HistoryScope
    let historyState: SelectedHistoryState
    let commitState: SelectedCommitState
    let diffGeneration: UInt64
    let historyGeneration: UInt64
    let commitGeneration: UInt64
    let modeGeneration: UInt64
}

@MainActor
final class SelectedRepositorySession {
    var diffState: SelectedDiffState = .idle
    var historyScope: HistoryScope = .mixed
    var historyState = SelectedHistoryState()
    var commitState: SelectedCommitState = .idle

    private(set) var diffGeneration: UInt64 = 0
    private(set) var historyGeneration: UInt64 = 0
    private(set) var commitGeneration: UInt64 = 0
    private(set) var modeGeneration: UInt64 = 0

    private var loadTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?

    var snapshot: SelectedRepositorySessionSnapshot {
        SelectedRepositorySessionSnapshot(
            diffState: diffState,
            historyScope: historyScope,
            historyState: historyState,
            commitState: commitState,
            diffGeneration: diffGeneration,
            historyGeneration: historyGeneration,
            commitGeneration: commitGeneration,
            modeGeneration: modeGeneration
        )
    }

    var hasHistoryTask: Bool { historyTask != nil }

    deinit {
        loadTask?.cancel()
        diffTask?.cancel()
        historyTask?.cancel()
        commitTask?.cancel()
    }

    func replaceLoadTask(with task: Task<Void, Never>?) {
        loadTask?.cancel()
        loadTask = task
    }

    func beginDiff(state: SelectedDiffState) -> UInt64 {
        diffGeneration &+= 1
        diffTask?.cancel()
        diffTask = nil
        diffState = state
        return diffGeneration
    }

    func installDiffTask(_ task: Task<Void, Never>, generation: UInt64) {
        guard diffGeneration == generation else {
            task.cancel()
            return
        }
        diffTask = task
    }

    func isCurrentDiff(_ generation: UInt64) -> Bool {
        diffGeneration == generation
    }

    func finishDiff(_ state: SelectedDiffState, generation: UInt64) -> Bool {
        guard diffGeneration == generation else { return false }
        diffTask = nil
        diffState = state
        return true
    }

    func clearDiff() {
        _ = beginDiff(state: .idle)
    }

    func nextModeGeneration() -> UInt64 {
        modeGeneration &+= 1
        return modeGeneration
    }

    func beginHistoryTask() -> UInt64 {
        historyGeneration &+= 1
        return historyGeneration
    }

    func installHistoryTask(_ task: Task<Void, Never>, generation: UInt64) {
        guard historyGeneration == generation else {
            task.cancel()
            return
        }
        historyTask = task
    }

    func isCurrentHistory(_ generation: UInt64) -> Bool {
        historyGeneration == generation
    }

    func finishHistoryTask(generation: UInt64) {
        guard historyGeneration == generation else { return }
        historyTask = nil
    }

    func beginCommit() -> UInt64 {
        commitGeneration &+= 1
        commitTask?.cancel()
        commitTask = nil
        return commitGeneration
    }

    func installCommitTask(_ task: Task<Void, Never>, generation: UInt64) {
        guard commitGeneration == generation else {
            task.cancel()
            return
        }
        commitTask = task
    }

    func isCurrentCommit(_ generation: UInt64) -> Bool {
        commitGeneration == generation
    }

    func finishCommitTask(generation: UInt64) {
        guard commitGeneration == generation else { return }
        commitTask = nil
    }

    func clearHistory() {
        historyGeneration &+= 1
        commitGeneration &+= 1
        historyTask?.cancel()
        commitTask?.cancel()
        historyTask = nil
        commitTask = nil
        historyState = SelectedHistoryState(scope: historyScope)
        commitState = .idle
    }

    func cancelAndDrain() async {
        diffGeneration &+= 1
        historyGeneration &+= 1
        commitGeneration &+= 1
        modeGeneration &+= 1
        let tasks = [loadTask, diffTask, historyTask, commitTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }
        loadTask = nil
        diffTask = nil
        historyTask = nil
        commitTask = nil
        diffState = .idle
        historyState = SelectedHistoryState()
        commitState = .idle
        await TaskCompletionDrain.waitForCompletion(tasks)
    }
}