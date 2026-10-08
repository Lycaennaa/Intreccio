import AppKit
import Foundation
@testable import Intreccio
import XCTest

extension AppCoordinatorTests {
    func testDefaultCommitMessageListsUpToThreeStagedFiles() {
        func change(_ path: String, _ state: GitFileState) -> FileChange {
            FileChange(
                path: path,
                originalPath: nil,
                indexState: state,
                worktreeState: .unmodified,
                kind: .ordinary,
                submoduleState: nil
            )
        }

        XCTAssertEqual(
            AppCoordinator.defaultCommitMessage(for: RepoStatus(changes: [change("new.txt", .added)])),
            "Create new.txt"
        )
        XCTAssertEqual(
            AppCoordinator.defaultCommitMessage(for: RepoStatus(changes: [change("line\nbreak.txt", .modified)])),
            "Update line\\nbreak.txt"
        )
        XCTAssertEqual(
            AppCoordinator.defaultCommitMessage(for: RepoStatus(changes: [
                change("a\u{000B}b\u{000C}c\u{0085}d\u{2028}e\u{2029}f.txt", .modified)
            ])),
            "Update a\\u{B}b\\u{C}c\\u{85}d\\u{2028}e\\u{2029}f.txt"
        )
        XCTAssertEqual(
            AppCoordinator.defaultCommitMessage(for: RepoStatus(changes: [
                FileChange(
                    gitPath: GitPath(bytes: Data([0x62, 0x61, 0x64, 0xFF, 0x2E, 0x74, 0x78, 0x74])),
                    originalGitPath: nil,
                    indexState: .modified,
                    worktreeState: .unmodified,
                    kind: .ordinary,
                    submoduleState: nil
                )
            ])),
            "Update bad\\xFF.txt"
        )
        XCTAssertEqual(
            AppCoordinator.defaultCommitMessage(for: RepoStatus(changes: [
                change("old.txt", .deleted),
                change("older.txt", .deleted)
            ])),
            "Delete old.txt and older.txt"
        )
        XCTAssertEqual(
            AppCoordinator.defaultCommitMessage(for: RepoStatus(changes: [
                change("one.txt", .modified),
                change("two.txt", .modified),
                change("three.txt", .modified)
            ])),
            "Update one.txt, two.txt and three.txt"
        )
        XCTAssertEqual(
            AppCoordinator.defaultCommitMessage(for: RepoStatus(changes: [
                change("two.txt", .modified),
                change("one.txt", .modified),
                change("two.txt", .modified),
                change("three.txt", .modified)
            ])),
            "Update two.txt, one.txt and three.txt"
        )
        XCTAssertNil(AppCoordinator.defaultCommitMessage(for: RepoStatus(changes: [
            change("one.txt", .modified),
            change("two.txt", .modified),
            change("three.txt", .modified),
            change("four.txt", .modified)
        ])))
    }

    func testCommitFailurePreservesMessageAndSuccessClearsIt() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        try "content\n".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(at: repository, arguments: ["config", "user.name", ""])
        try runGit(at: repository, arguments: ["config", "user.email", ""])
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.selectRepository(repositoryID)
        try await waitUntil { coordinator.repositoryRefreshStates[repositoryID]?.status != nil }

        coordinator.stageAll()
        try await waitUntil {
            coordinator.mutationState == .idle
                && coordinator.repositoryRefreshStates[repositoryID]?.status?.changes.first?.hasStagedChange == true
        }
        XCTAssertEqual(coordinator.commitMessage, "Create file.txt")
        let generationBeforeCommit = coordinator.repositoryRefreshStates[repositoryID]?.historyGeneration ?? 0
        coordinator.setCommitMessage("keep this message")
        coordinator.commit()
        try await waitUntil {
            if case .failed = coordinator.mutationState { return true }
            return false
        }

        XCTAssertEqual(coordinator.commitMessage, "keep this message")
        if case .failed(let failure) = coordinator.mutationState {
            XCTAssertFalse(failure.details.isEmpty)
            XCTAssertTrue(failure.copyText.contains(failure.recoverySuggestion))
        } else {
            XCTFail("Expected failed mutation state")
        }
        XCTAssertGreaterThan(coordinator.repositoryRefreshStates[repositoryID]?.historyGeneration ?? 0, generationBeforeCommit)
        XCTAssertTrue(coordinator.repositoryRefreshStates[repositoryID]?.status?.changes.first?.hasStagedChange == true)

        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        coordinator.commit()
        try await waitUntil {
            coordinator.mutationState == .idle
                && coordinator.repositoryRefreshStates[repositoryID]?.status?.isClean == true
        }
        XCTAssertEqual(coordinator.commitMessage, "")
    }

    func testHistoryModeManualRefreshUpdatesUpstreamBehindStatus() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        let remote = directory.appendingPathComponent("remote.git", isDirectory: true)
        let peer = directory.appendingPathComponent("Peer", isDirectory: true)
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        try "base\n".write(
            to: repository.appendingPathComponent("base.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: repository, arguments: ["add", "--", "base.txt"])
        try runGit(at: repository, arguments: ["commit", "-m", "base"])
        try runGit(at: directory, arguments: ["init", "--bare", "-b", "main", remote.path])
        try runGit(at: repository, arguments: ["remote", "add", "origin", remote.path])
        try runGit(at: repository, arguments: ["push", "-u", "origin", "main"])

        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.selectRepository(repositoryID)
        try await waitUntil {
            coordinator.repositoryRefreshStates[repositoryID]?.phase == .idle
                && coordinator.repositoryRefreshStates[repositoryID]?.status != nil
        }
        coordinator.setMode(.history)
        try await waitUntil { coordinator.selectedHistoryState.commits.count == 1 }

        try runGit(at: directory, arguments: ["clone", remote.path, peer.path])
        try runGit(at: peer, arguments: ["config", "user.name", "Peer User"])
        try runGit(at: peer, arguments: ["config", "user.email", "peer@example.com"])
        try "remote\n".write(
            to: peer.appendingPathComponent("remote.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: peer, arguments: ["add", "--", "remote.txt"])
        try runGit(at: peer, arguments: ["commit", "-m", "remote change"])
        try runGit(at: peer, arguments: ["push", "origin", "main"])

        coordinator.refreshSelectedRepository()

        try await waitUntil(description: "history-mode upstream refresh") {
            coordinator.repositoryRefreshStates[repositoryID]?.status?.branch.behind == 1
        }
        XCTAssertEqual(coordinator.state.uiState.mode, .history)
    }

    func testHistoryModeManualRefreshDoesNotReloadUnchangedHistory() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        let remote = directory.appendingPathComponent("remote.git", isDirectory: true)
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        try "base\n".write(
            to: repository.appendingPathComponent("base.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: repository, arguments: ["add", "--", "base.txt"])
        try runGit(at: repository, arguments: ["commit", "-m", "base"])
        try runGit(at: directory, arguments: ["init", "--bare", "-b", "main", remote.path])
        try runGit(at: repository, arguments: ["remote", "add", "origin", remote.path])
        try runGit(at: repository, arguments: ["push", "-u", "origin", "main"])

        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.selectRepository(repositoryID)
        try await waitUntil(description: "initial status") {
            coordinator.repositoryRefreshStates[repositoryID]?.phase == .idle
                && coordinator.repositoryRefreshStates[repositoryID]?.status != nil
        }
        coordinator.setMode(.history)
        try await waitUntil(description: "initial history") {
            coordinator.selectedHistoryState.phase == .idle
                && coordinator.selectedHistoryState.commits.map(\.subject) == ["base"]
        }

        let historyGeneration = coordinator.repositoryRefreshStates[repositoryID]?.historyGeneration ?? 0
        let statusGeneration = try XCTUnwrap(
            coordinator.repositoryRefreshStates[repositoryID]?.statusGeneration
        )
        coordinator.refreshSelectedRepository()

        try await waitUntil(description: "unchanged upstream refresh") {
            guard let state = coordinator.repositoryRefreshStates[repositoryID] else { return false }
            return state.phase == .idle && state.statusGeneration > statusGeneration
        }

        XCTAssertEqual(coordinator.repositoryRefreshStates[repositoryID]?.historyGeneration, historyGeneration)
        XCTAssertEqual(coordinator.selectedHistoryState.commits.map(\.subject), ["base"])
    }

    func testAmendHeadCommitAndCancelRestoresPreviousDraft() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        try "base\n".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(at: repository, arguments: ["add", "-A"])
        try runGit(at: repository, arguments: ["commit", "-m", "Original subject", "-m", "Original body"])
        let service = GitService()
        let loadedOriginalHead = try await service.headObjectID(repository: repository)
        let originalHead = try XCTUnwrap(loadedOriginalHead)
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.selectRepository(repositoryID)
        try await waitUntil { coordinator.repositoryRefreshStates[repositoryID]?.status != nil }
        coordinator.setCommitMessage("Saved draft")

        coordinator.setMode(.history)
        try await waitUntil { coordinator.selectedHistoryState.commits.count == 1 }
        coordinator.beginAmending(try XCTUnwrap(coordinator.selectedHistoryState.commits.first))
        XCTAssertEqual(coordinator.state.uiState.mode, .changes)
        XCTAssertTrue(coordinator.isAmendingCommit)
        XCTAssertEqual(coordinator.commitMessage, "Original subject\n\nOriginal body")

        coordinator.cancelAmendingCommit()
        XCTAssertFalse(coordinator.isAmendingCommit)
        XCTAssertEqual(coordinator.commitMessage, "Saved draft")

        coordinator.setMode(.history)
        try await waitUntil { coordinator.selectedHistoryState.commits.count == 1 }
        coordinator.beginAmending(try XCTUnwrap(coordinator.selectedHistoryState.commits.first))
        try await waitUntil { coordinator.repositoryRefreshStates[repositoryID]?.status != nil }
        coordinator.setCommitMessage("Amended subject\n\nAmended body")
        coordinator.commit()
        try await waitUntil {
            coordinator.mutationState == .idle && !coordinator.isAmendingCommit
        }

        let loadedAmendedHead = try await service.headObjectID(repository: repository)
        let amendedHead = try XCTUnwrap(loadedAmendedHead)
        let amendedHistory = try await service.history(repository: repository)
        XCTAssertNotEqual(amendedHead, originalHead)
        XCTAssertEqual(coordinator.commitMessage, "")
        XCTAssertEqual(amendedHistory.first?.subject, "Amended subject")
    }

    func testHistoryPaginationFilteringDetailsAndHeadInvalidation() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        for number in 1...16 {
            try "\(number)\n".write(
                to: repository.appendingPathComponent("history.txt"),
                atomically: true,
                encoding: .utf8
            )
            try runGit(at: repository, arguments: ["add", "--", "history.txt"])
            try runGit(at: repository, arguments: ["commit", "-m", "commit \(number)"])
        }

        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.setMode(.history)
        coordinator.selectRepository(repositoryID)
        try await waitUntil(description: "initial history page") { coordinator.selectedHistoryState.commits.count == 15 }
        XCTAssertFalse(coordinator.selectedHistoryState.reachedEnd)

        coordinator.loadNextHistoryPage()
        try await waitUntil(description: "second history page") { coordinator.selectedHistoryState.commits.count == 16 }
        XCTAssertTrue(coordinator.selectedHistoryState.reachedEnd)

        coordinator.setSearchText("COMMIT 4")
        XCTAssertEqual(coordinator.filteredHistoryCommits.map(\.subject), ["commit 4"])
        coordinator.setSearchText("")

        let root = try XCTUnwrap(coordinator.selectedHistoryState.commits.last)
        coordinator.selectCommit(root)
        try await waitUntil(description: "root commit details") {
            if case .loaded = coordinator.selectedCommitState { return true }
            return false
        }
        if case .loaded(let details) = coordinator.selectedCommitState {
            XCTAssertEqual(details.commit.objectID, root.objectID)
            XCTAssertEqual(details.commit.parentIDs, [])
            XCTAssertEqual(details.diff.files.map(\.path), ["history.txt"])
        } else {
            XCTFail("Expected loaded commit details")
        }

        try "17\n".write(
            to: repository.appendingPathComponent("history.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: repository, arguments: ["add", "--", "history.txt"])
        try runGit(at: repository, arguments: ["commit", "-m", "commit 17"])
        coordinator.refreshSelectedRepository()
        try await waitUntil(description: "history HEAD invalidation") {
            coordinator.selectedHistoryState.commits.first?.subject == "commit 17"
        }
        XCTAssertEqual(coordinator.selectedHistoryState.commits.count, 15)
        XCTAssertEqual(coordinator.selectedCommitState, .idle)
    }

    func testHistoryLoadingPublicationCannotReenterPageRequest() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        try "content\n".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(at: repository, arguments: ["add", "--", "file.txt"])
        try runGit(at: repository, arguments: ["commit", "-m", "initial"])
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        let subscriptionID = coordinator.addSnapshotHandler { snapshot in
            if case .loading = snapshot.selectedSession.historyState.phase {
                coordinator.loadNextHistoryPage()
            }
        }
        defer { coordinator.removeSnapshotHandler(subscriptionID) }

        coordinator.setMode(.history)
        coordinator.selectRepository(repositoryID)
        try await waitUntil(description: "reentrant history load") {
            coordinator.selectedHistoryState.commits.count == 1
        }

        XCTAssertTrue(coordinator.selectedHistoryState.reachedEnd)
    }

    func testHistoryScopeSwitchReloadsWithoutUpstream() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        try "content\n".write(
            to: repository.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: repository, arguments: ["add", "--", "file.txt"])
        try runGit(at: repository, arguments: ["commit", "-m", "initial"])
        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.setMode(.history)
        coordinator.selectRepository(repositoryID)
        try await waitUntil(description: "mixed history") {
            coordinator.selectedHistoryState.commits.map(\.subject) == ["initial"]
        }

        coordinator.setHistoryScope(.upstream)
        try await waitUntil(description: "empty upstream history") {
            coordinator.selectedHistoryState.scope == .upstream
                && coordinator.selectedHistoryState.commits.isEmpty
                && coordinator.selectedHistoryState.reachedEnd
        }

        coordinator.setHistoryScope(.local)
        try await waitUntil(description: "local history") {
            coordinator.selectedHistoryState.scope == .local
                && coordinator.selectedHistoryState.commits.map(\.subject) == ["initial"]
        }
    }

    func testUpstreamRefreshReloadsUnmergedHistoryAfterFetchCompletes() async throws {
        let directory = try makeTestDirectory()
        let repository = directory.appendingPathComponent("Repo", isDirectory: true)
        let remote = directory.appendingPathComponent("remote.git", isDirectory: true)
        let peer = directory.appendingPathComponent("Peer", isDirectory: true)
        try initializeRepository(at: repository)
        try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
        try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
        try "base\n".write(
            to: repository.appendingPathComponent("base.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: repository, arguments: ["add", "--", "base.txt"])
        try runGit(at: repository, arguments: ["commit", "-m", "base"])
        try runGit(at: directory, arguments: ["init", "--bare", "-b", "main", remote.path])
        try runGit(at: repository, arguments: ["remote", "add", "origin", remote.path])
        try runGit(at: repository, arguments: ["push", "-u", "origin", "main"])

        let coordinator = makeCoordinator(stateFile: directory.appendingPathComponent("state.json"))
        await coordinator.addStandaloneRepository(repository)
        let repositoryID = try XCTUnwrap(coordinator.repositories.first?.id)
        coordinator.setMode(.history)
        coordinator.selectRepository(repositoryID)
        coordinator.setHistoryScope(.unmergedUpstream)
        try await waitUntil(description: "initial empty unmerged history") {
            coordinator.selectedHistoryState.scope == .unmergedUpstream
                && coordinator.selectedHistoryState.commits.isEmpty
                && coordinator.selectedHistoryState.reachedEnd
        }
        try await waitUntil(description: "initial status refresh") {
            coordinator.repositoryRefreshStates[repositoryID]?.phase == .idle
                && coordinator.repositoryRefreshStates[repositoryID]?.status != nil
                && coordinator.selectedHistoryState.phase == .idle
        }
        let historyGenerationBeforeRefresh = coordinator.repositoryRefreshStates[repositoryID]?.historyGeneration ?? 0

        try runGit(at: directory, arguments: ["clone", remote.path, peer.path])
        try runGit(at: peer, arguments: ["config", "user.name", "Peer User"])
        try runGit(at: peer, arguments: ["config", "user.email", "peer@example.com"])
        try "remote\n".write(
            to: peer.appendingPathComponent("remote.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(at: peer, arguments: ["add", "--", "remote.txt"])
        try runGit(at: peer, arguments: ["commit", "-m", "remote change"])
        try runGit(at: peer, arguments: ["push", "origin", "main"])

        coordinator.refreshSelectedRepository()

        try await waitUntil(description: "refreshed unmerged upstream history") {
            coordinator.selectedHistoryState.commits.map(\.subject) == ["remote change"]
        }
        XCTAssertEqual(
            coordinator.repositoryRefreshStates[repositoryID]?.historyGeneration,
            historyGenerationBeforeRefresh + 1
        )

    }

}
