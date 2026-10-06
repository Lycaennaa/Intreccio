import Foundation
import XCTest
@testable import Intreccio

extension GitServiceIntegrationTests {
    func testRenameDeleteBinaryUnbornConflictAndMergeFixtures() async throws {
        let service = GitService()

        let unborn = try GitFixture(testCase: self)
        try unborn.write("new", to: "new.txt")
        try unborn.git("add", "--", "new.txt")
        let unbornStatus = try await service.status(repository: unborn.url, refreshUpstream: true)
        XCTAssertNil(unbornStatus.branch.objectID)
        XCTAssertEqual(unbornStatus.changes.first?.indexState, .added)

        let fixture = try GitFixture(testCase: self)
        try fixture.write("rename me", to: "old.txt")
        try fixture.write(Data([0, 1, 2, 0, 3]), to: "image.bin")
        try fixture.write("delete me", to: "delete.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")
        try fixture.git("mv", "old.txt", "new.txt")
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("delete.txt"))
        try fixture.write(Data([0, 9, 2, 0, 3]), to: "image.bin")

        let changed = try await service.status(repository: fixture.url)
        XCTAssertTrue(changed.changes.contains { $0.kind == .renamed && $0.originalPath == "old.txt" && $0.path == "new.txt" })
        XCTAssertTrue(changed.changes.contains { $0.path == "delete.txt" && $0.worktreeState == .deleted })
        let binaryChange = try XCTUnwrap(changed.changes.first { $0.path == "image.bin" })
        let binaryDiff = try await service.diff(repository: fixture.url, kind: .unstaged, changes: [binaryChange])
        XCTAssertEqual(binaryDiff.files.first?.content, .binary(byteCount: nil))

        try fixture.git("reset", "--hard", "HEAD")
        try fixture.git("checkout", "-b", "side")
        try fixture.write("side\n", to: "old.txt")
        try fixture.git("commit", "-am", "side")
        try fixture.git("checkout", "main")
        try fixture.write("main\n", to: "old.txt")
        try fixture.git("commit", "-am", "main")
        XCTAssertThrowsError(try fixture.git("merge", "side"))
        let conflict = try await service.status(repository: fixture.url)
        XCTAssertTrue(conflict.hasConflicts)
        let conflictChange = try XCTUnwrap(conflict.changes.first { $0.kind == .unmerged })
        let conflictDiff = try await service.diff(repository: fixture.url, kind: .unstaged, changes: [conflictChange])
        XCTAssertEqual(
            conflictDiff.files.first?.content,
            .conflicted(statusX: conflictChange.indexState, statusY: conflictChange.worktreeState)
        )

        try fixture.git("merge", "--abort")
        try fixture.git("merge", "side", "-m", "merge", "-X", "ours")
        let mergeHistory = try await service.history(repository: fixture.url)
        let merge = try XCTUnwrap(mergeHistory.first)
        XCTAssertEqual(merge.parentIDs.count, 2)
        let mergeDetails = try await service.show(repository: fixture.url, objectID: merge.objectID)
        XCTAssertEqual(mergeDetails.comparisonBasis, merge.parentIDs[0])
    }

    func testUntrackedTextBinaryAndStagedNoMatch() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("one\ntwo", to: "new.swift")
        try fixture.write(Data([0, 1, 2]), to: "new.bin")
        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let text = try XCTUnwrap(status.changes.first { $0.path == "new.swift" })
        let binary = try XCTUnwrap(status.changes.first { $0.path == "new.bin" })

        let unstaged = try await service.diff(repository: fixture.url, kind: .unstaged, changes: [text, binary])
        XCTAssertEqual(unstaged.files.count, 2)
        XCTAssertTrue(unstaged.text.contains("one"))
        XCTAssertEqual(unstaged.files.first(where: { $0.path == "new.bin" })?.content, .binary(byteCount: 3))

        let staged = try await service.diff(repository: fixture.url, kind: .staged, changes: [text, binary])
        XCTAssertEqual(staged, .empty)
    }

    func testDiffStatsCountsStagedUnstagedAndUntrackedLines() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("before\n", to: "staged.txt")
        try fixture.write("one\ntwo\n", to: "unstaged.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-m", "base")

        try fixture.write("after\n", to: "staged.txt")
        try fixture.git("add", "--", "staged.txt")
        try fixture.write("one\ntwo\nthree\n", to: "unstaged.txt")
        try fixture.write("new\nnew2", to: "untracked.txt")

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)
        XCTAssertEqual(
            try XCTUnwrap(status.stagedLineStats),
            DiffLineStats(additions: 1, deletions: 1, hasNonCodeFiles: true)
        )
        XCTAssertEqual(
            try XCTUnwrap(status.unstagedLineStats),
            DiffLineStats(additions: 3, deletions: 0, hasNonCodeFiles: true)
        )
    }

    func testDiffStatsCountsSLOCOnlyForCodeFiles() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("before\n", to: "tracked.swift")
        try fixture.write("before\n", to: "tracked.txt")
        try fixture.write("<div>before</div>\n", to: "tracked.html")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")

        try fixture.write("after\n\n// new\n", to: "tracked.swift")
        try fixture.write("after\n", to: "tracked.txt")
        try fixture.write("<div>after</div>\n\n<!-- comment -->\n", to: "tracked.html")
        try fixture.write("one\n\n// comment\ntwo\n", to: "untracked.swift")
        try fixture.write("one\ntwo\n", to: "untracked.txt")
        try fixture.write("one\ntwo\n", to: "untracked.md")
        try fixture.write("{\"one\": 1}\n", to: "untracked.json")
        try fixture.write("one: 1\n", to: "untracked.yaml")
        try fixture.write("one = 1\n", to: "untracked.cfg")
        try fixture.write("FROM alpine\n", to: "Dockerfile")
        try fixture.write("all:\n\t@echo all\n", to: "Makefile")
        try fixture.write("generated\n", to: "generated/generated.swift")
        try fixture.write("vendor\n", to: "vendor/vendor.swift")

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)

        XCTAssertEqual(
            status.unstagedLineStats,
            DiffLineStats(
                additions: 23,
                deletions: 3,
                slocAdditions: 4,
                slocDeletions: 2,
                hasNonCodeFiles: true,
                hasCodeFiles: true
            )
        )
    }
    func testDiffStatsIncludesMultipleUntrackedFilesWithTrackedChanges() async throws {
        let fixture = try GitFixture(testCase: self)
        let trackedCount = 12
        let untrackedCount = 5
        for index in 0..<trackedCount {
            try fixture.write("before\n", to: "tracked-\(index).txt")
        }
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")
        for index in 0..<trackedCount {
            try fixture.write("after\n", to: "tracked-\(index).txt")
        }
        for index in 0..<untrackedCount {
            try fixture.write("new\none\n", to: "untracked-\(index).txt")
        }

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)
        XCTAssertEqual(
            status.unstagedLineStats,
            DiffLineStats(
                additions: trackedCount + untrackedCount * 2,
                deletions: trackedCount,
                hasNonCodeFiles: true
            )
        )
    }
    func testDiffStatsIncludesTextUntrackedFilesAlongsideBinary() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("before\n", to: "tracked.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")
        try fixture.write("after\n", to: "tracked.txt")
        try fixture.write("one\ntwo\n", to: "text.txt")
        try fixture.write(Data([0, 1, 2]), to: "binary.dat")

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)
        XCTAssertEqual(status.unstagedLineStats, DiffLineStats(additions: 3, deletions: 1, hasNonCodeFiles: true))
    }
    func testDiffStatsIncludesTextUntrackedFilesAlongsideOversized() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("one\ntwo\n", to: "text.txt")
        try fixture.write(
            Data(repeating: 1, count: DiffLimits.render.maximumBytes + 1),
            to: "oversized.dat"
        )

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)
        XCTAssertEqual(status.unstagedLineStats, DiffLineStats(additions: 2, deletions: 0, hasNonCodeFiles: true))
    }
    func testUntrackedAnalysisCacheReusesVerifiedContentForStatsAndDiff() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("one\ntwo\n", to: "new.txt")
        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let change = try XCTUnwrap(status.changes.first { $0.path == "new.txt" })

        let stats = try await service.diffStats(repository: fixture.url, kind: .unstaged, changes: [change])
        XCTAssertEqual(stats, DiffLineStats(additions: 2, deletions: 0, hasNonCodeFiles: true))
        let cachedAfterStats = await service.untrackedDiffAnalysisCache
        let analysis = try XCTUnwrap(cachedAfterStats.value(for: "new.txt"))
        XCTAssertEqual(analysis.lineStats, DiffLineStats(additions: 2, deletions: 0))
        XCTAssertEqual(analysis.content, Data("one\ntwo\n".utf8))

        let diff = try await service.diff(repository: fixture.url, kind: .unstaged, changes: [change])
        XCTAssertNil(diff.fallback)
        XCTAssertTrue(diff.text.contains("+one\n+two\n"))
    }
    func testUntrackedDiffPreservesRequestedOrderWithCachedAnalysis() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("first\n", to: "first.txt")
        try fixture.write("second\n", to: "second.txt")
        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let second = try XCTUnwrap(status.changes.first { $0.path == "second.txt" })
        let first = try XCTUnwrap(status.changes.first { $0.path == "first.txt" })
        let changes = [second, first]

        _ = try await service.diffStats(repository: fixture.url, kind: .unstaged, changes: changes)
        let diff = try await service.diff(repository: fixture.url, kind: .unstaged, changes: changes)

        XCTAssertEqual(diff.files.map(\.path), ["second.txt", "first.txt"])
        XCTAssertTrue(diff.text.contains("+first\n"))
        XCTAssertTrue(diff.text.contains("+second\n"))
    }

    func testUntrackedAnalysisCacheRecomputesAfterConsistencyMismatch() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("before\n", to: "new.txt")
        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let change = try XCTUnwrap(status.changes.first { $0.path == "new.txt" })
        _ = try await service.diffStats(repository: fixture.url, kind: .unstaged, changes: [change])
        let cacheBefore = await service.untrackedDiffAnalysisCache
        let before = try XCTUnwrap(cacheBefore.value(for: "new.txt"))

        try fixture.write("after\n", to: "new.txt")
        let diff = try await service.diff(repository: fixture.url, kind: .unstaged, changes: [change])
        XCTAssertTrue(diff.text.contains("+after\n"))
        let cacheAfter = await service.untrackedDiffAnalysisCache
        let after = try XCTUnwrap(cacheAfter.value(for: "new.txt"))
        XCTAssertNotEqual(after.fingerprint, before.fingerprint)
        XCTAssertEqual(after.content, Data("after\n".utf8))
    }

    func testUntrackedAnalysisCacheIsByteBudgeted() throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write(String(repeating: "x", count: 100), to: "cached.txt")
        let analysis = try SyntheticUntrackedDiff.analyze(
            repository: fixture.url,
            relativePath: "cached.txt",
            maximumBytes: DiffLimits.render.maximumBytes,
            maximumLines: DiffLimits.render.maximumLines
        )
        var cache = UntrackedDiffAnalysisCache(maximumBytes: 200)
        cache.store(analysis, for: "cached.txt")

        XCTAssertLessThanOrEqual(cache.storedByteCount, 200)
        let cached = try XCTUnwrap(cache.value(for: "cached.txt"))
        XCTAssertEqual(cached.fingerprint, analysis.fingerprint)
        XCTAssertNil(cached.content)

        cache.store(analysis, for: "second.txt")
        XCTAssertLessThanOrEqual(cache.storedByteCount, 200)
        XCTAssertNil(cache.value(for: "cached.txt"))
    }
    func testUntrackedAnalysisCachePreservesEvictionOrderAfterQueueCompaction() throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("value\n", to: "cached.txt")
        let analysis = try SyntheticUntrackedDiff.analyze(
            repository: fixture.url,
            relativePath: "cached.txt",
            maximumBytes: DiffLimits.render.maximumBytes,
            maximumLines: DiffLimits.render.maximumLines
        )
        var cache = UntrackedDiffAnalysisCache(maximumBytes: 300)
        cache.store(analysis, for: "first.txt")
        cache.store(analysis, for: "second.txt")
        for _ in 0..<80 {
            cache.store(analysis, for: "first.txt")
        }

        cache.store(analysis, for: "third.txt")
        XCTAssertLessThanOrEqual(cache.storedByteCount, 300)
        XCTAssertNil(cache.value(for: "second.txt"))
        XCTAssertNotNil(cache.value(for: "first.txt"))
        XCTAssertNotNil(cache.value(for: "third.txt"))

        cache.store(analysis, for: "fourth.txt")
        XCTAssertLessThanOrEqual(cache.storedByteCount, 300)
        XCTAssertNil(cache.value(for: "first.txt"))
        XCTAssertNotNil(cache.value(for: "third.txt"))
        XCTAssertNotNil(cache.value(for: "fourth.txt"))
    }


    func testUntrackedAnalysisHonorsCancellation() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write(String(repeating: "line\n", count: 10_000), to: "cancel.txt")
        let gate = AsyncTestGate()
        let task = Task { () throws -> UntrackedFileAnalysis in
            await gate.wait("continue")
            return try SyntheticUntrackedDiff.analyze(
                repository: fixture.url,
                relativePath: "cancel.txt",
                maximumBytes: DiffLimits.render.maximumBytes,
                maximumLines: DiffLimits.render.maximumLines
            )
        }
        await Task.yield()
        task.cancel()
        await gate.open("continue")

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDiffStatsFingerprintCacheReusesStagedAndUnstagedOverlap() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "shared.txt")
        try fixture.git("add", "--", "shared.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.write("staged\n", to: "shared.txt")
        try fixture.git("add", "--", "shared.txt")
        try fixture.write("unstaged\n", to: "shared.txt")

        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let change = try XCTUnwrap(status.changes.first { $0.path == "shared.txt" })
        XCTAssertTrue(change.hasStagedChange)
        XCTAssertTrue(change.hasUnstagedChange)

        let budget = Int64(DiffLimits.render.maximumBytes / 2)
        var cache = DiffStatsRefreshFingerprintCache(statusGeneration: 1)
        let stagedFingerprint = try service.trackedWorktreeFingerprints(
            repository: fixture.url,
            changes: [change],
            maximumBytes: budget,
            cache: &cache
        )
        try fixture.write("changed after first read\n", to: "shared.txt")
        let unstagedFingerprint = try service.trackedWorktreeFingerprints(
            repository: fixture.url,
            changes: [change],
            maximumBytes: budget,
            cache: &cache
        )
        XCTAssertEqual(stagedFingerprint, unstagedFingerprint)

        var freshCache = DiffStatsRefreshFingerprintCache(statusGeneration: 1)
        let freshFingerprint = try service.trackedWorktreeFingerprints(
            repository: fixture.url,
            changes: [change],
            maximumBytes: budget,
            cache: &freshCache
        )
        XCTAssertNotEqual(stagedFingerprint, freshFingerprint)
        let refreshed = try await service.status(repository: fixture.url, includeDiffStats: true)
        XCTAssertEqual(refreshed.stagedLineStats, DiffLineStats(additions: 1, deletions: 1, hasNonCodeFiles: true))
        XCTAssertEqual(refreshed.unstagedLineStats, DiffLineStats(additions: 1, deletions: 1, hasNonCodeFiles: true))
    }

    func testDiffStatsFingerprintCacheInvalidatesOnMismatch() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("before\n", to: "tracked.txt")
        try fixture.git("add", "--", "tracked.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.write("first\n", to: "tracked.txt")

        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let change = try XCTUnwrap(status.changes.first { $0.path == "tracked.txt" })
        let budget = Int64(DiffLimits.render.maximumBytes / 2)
        var cache = DiffStatsRefreshFingerprintCache(statusGeneration: 1)
        let before = try service.trackedWorktreeFingerprints(
            repository: fixture.url,
            changes: [change],
            maximumBytes: budget,
            cache: &cache
        )

        try fixture.write("second\n", to: "tracked.txt")
        cache.invalidate(for: 2)
        let after = try service.trackedWorktreeFingerprints(
            repository: fixture.url,
            changes: [change],
            maximumBytes: budget,
            cache: &cache
        )
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(cache.key(path: "tracked.txt", maximumBytes: budget).statusGeneration, 2)
    }

    func testDiffStatsFingerprintCacheHonorsCancellation() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("tracked\n", to: "tracked.txt")
        let change = FileChange(
            path: "tracked.txt",
            originalPath: nil,
            indexState: .modified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )
        let service = GitService()
        let gate = AsyncTestGate()
        let task = Task { () throws -> [String: FileContentFingerprint]? in
            await gate.open("started")
            await gate.wait("continue")
            var cache = DiffStatsRefreshFingerprintCache(statusGeneration: 1)
            return try service.trackedWorktreeFingerprints(
                repository: fixture.url,
                changes: [change],
                maximumBytes: Int64(DiffLimits.render.maximumBytes / 2),
                cache: &cache
            )
        }
        await gate.wait("started")
        task.cancel()
        await gate.open("continue")

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUntrackedSymlinkIsRejectedWithoutFollowingTarget() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("secret", to: "target.txt")
        let link = fixture.url.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.url.appendingPathComponent("target.txt"))
        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let linkChange = try XCTUnwrap(status.changes.first { $0.path == "link.txt" })

        let diff = try await service.diff(repository: fixture.url, kind: .unstaged, changes: [linkChange])
        let file = try XCTUnwrap(diff.files.first)
        guard case .unavailable(.unsupportedFile) = file.content else {
            return XCTFail("Expected symlink to remain unavailable")
        }
    }

    func testUnavailableUntrackedFileDoesNotHideValidSibling() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("valid\n", to: "valid.txt")
        let target = fixture.url.deletingLastPathComponent().appendingPathComponent("outside-target-\(UUID().uuidString)")
        try "secret".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: target) }
        let link = fixture.url.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let changes = status.changes.filter { $0.kind == .untracked }

        let diff = try await service.diff(repository: fixture.url, kind: .unstaged, changes: changes)
        XCTAssertEqual(diff.files.count, 2)
        XCTAssertTrue(diff.files.contains { file in
            file.path == "valid.txt" && {
                if case .text = file.content { return true }
                return false
            }()
        })
        XCTAssertTrue(diff.files.contains { file in
            file.path == "link.txt" && file.content == .unavailable(.unsupportedFile)
        })
    }

    func testSamePathStagedDeletionAndUntrackedReplacementRemainOneExactSelection() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("tracked\n", to: "same.txt")
        try fixture.git("add", "--", "same.txt")
        try fixture.git("commit", "-m", "base")
        try fixture.git("rm", "--cached", "--", "same.txt")
        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let records = status.changes.filter { $0.path == "same.txt" }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(RepositoryRefreshState(status: status).changeCount, 1)
        let deletion = try XCTUnwrap(records.first { $0.hasStagedChange })
        let replacement = try XCTUnwrap(records.first { $0.kind == .untracked })

        let staged = try await service.diff(repository: fixture.url, kind: .staged, changes: records)
        XCTAssertEqual(staged.files.first?.change, .deleted)
        let unstaged = try await service.diff(repository: fixture.url, kind: .unstaged, changes: records)
        XCTAssertEqual(unstaged.files.first?.change, .untracked)
        let deletionUnstaged = try await service.diff(repository: fixture.url, kind: .unstaged, changes: [deletion])
        let replacementStaged = try await service.diff(repository: fixture.url, kind: .staged, changes: [replacement])
        XCTAssertEqual(deletionUnstaged, .empty)
        XCTAssertEqual(replacementStaged, .empty)
    }

    func testUntrackedOversizedReasonsRemainDistinct() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write(Data(repeating: 65, count: 20), to: "bytes.txt")
        try fixture.write("one\ntwo\nthree\n", to: "lines.txt")
        try fixture.write("x\n", to: "estimated.txt")
        let service = GitService()
        let status = try await service.status(repository: fixture.url)

        let byteChange = try XCTUnwrap(status.changes.first { $0.path == "bytes.txt" })
        let byteDiff = try await service.diff(
            repository: fixture.url,
            kind: .unstaged,
            changes: [byteChange],
            limits: DiffLimits(maximumBytes: 10, maximumLines: 100)
        )
        guard case .oversized(let reason, let byteCount) = byteDiff.files.first?.content else {
            return XCTFail("Expected byte-limit file state")
        }
        XCTAssertEqual(reason, .byteLimit(maximumBytes: 10))
        XCTAssertEqual(byteCount, 20)

        let lineChange = try XCTUnwrap(status.changes.first { $0.path == "lines.txt" })
        let lineDiff = try await service.diff(
            repository: fixture.url,
            kind: .unstaged,
            changes: [lineChange],
            limits: DiffLimits(maximumBytes: 100, maximumLines: 5)
        )
        guard case .oversized(let reason, let byteCount) = lineDiff.files.first?.content else {
            return XCTFail("Expected line-limit file state")
        }
        XCTAssertEqual(reason, .lineLimit(maximumLines: 5))
        XCTAssertEqual(byteCount, 14)

        let estimatedChange = try XCTUnwrap(status.changes.first { $0.path == "estimated.txt" })
        let estimatedDiff = try await service.diff(
            repository: fixture.url,
            kind: .unstaged,
            changes: [estimatedChange],
            limits: DiffLimits(maximumBytes: 100, maximumLines: 100)
        )
        guard case .oversized(let reason, let byteCount) = estimatedDiff.files.first?.content else {
            return XCTFail("Expected estimated-render-size file state")
        }
        XCTAssertEqual(reason, .estimatedRenderSizeLimit(maximumBytes: 100))
        XCTAssertEqual(byteCount, 2)
    }

    func testCombinedUntrackedSelectionStopsAtAggregateCap() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write(String(repeating: "a", count: 80), to: "one.txt")
        try fixture.write(String(repeating: "b", count: 80), to: "two.txt")
        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let limits = DiffLimits(maximumBytes: 260, maximumLines: 100)
        let diff = try await service.diff(repository: fixture.url, kind: .unstaged, changes: status.changes, limits: limits)
        XCTAssertEqual(diff.fallback?.reason, .byteLimit(260))
        XCTAssertEqual(diff.files.count, 1)
        let renderedAndFallbackPaths = Set(
            diff.files.map(\.path) + (diff.fallback?.files.map(\.path) ?? [])
        )
        XCTAssertEqual(renderedAndFallbackPaths, Set(["one.txt", "two.txt"]))
    }
    func testLargeUntrackedSelectionStopsAtAggregateLineLimit() async throws {
        let fixture = try GitFixture(testCase: self)
        let limits = DiffLimits.render
        let count = limits.maximumLines / 5 + 1
        var changes: [FileChange] = []
        changes.reserveCapacity(count)
        for index in 0..<count {
            let path = "large-\(index).txt"
            try fixture.write("line\n", to: path)
            changes.append(FileChange(
                path: path,
                originalPath: nil,
                indexState: .unmodified,
                worktreeState: .unmodified,
                kind: .untracked,
                submoduleState: nil
            ))
        }
        let diff = try await GitService().diff(
            repository: fixture.url,
            kind: .unstaged,
            changes: changes,
            limits: limits
        )
        XCTAssertEqual(diff.fallback?.reason, .lineLimit(limits.maximumLines))
        XCTAssertGreaterThan(diff.files.count, 0)
        XCTAssertGreaterThan(diff.sourceLineCount, limits.maximumLines)
    }

    func testDuplicatePathKeepsUntrackedFingerprintValidation() async throws {
        let fixture = try GitFixture(testCase: self)
        try FileManager.default.createDirectory(
            at: fixture.url.appendingPathComponent("duplicate"),
            withIntermediateDirectories: true
        )
        let tracked = FileChange(
            path: "duplicate",
            originalPath: nil,
            indexState: .modified,
            worktreeState: .modified,
            kind: .ordinary,
            submoduleState: nil
        )
        let untracked = FileChange(
            path: "duplicate",
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .unmodified,
            kind: .untracked,
            submoduleState: nil
        )
        do {
            _ = try await GitService().worktreeFingerprints(
                repository: fixture.url,
                changes: [tracked, untracked],
                maximumBytes: Int64(DiffLimits.render.maximumBytes)
            )
            XCTFail("Expected unsupported untracked directory")
        } catch let error as SyntheticUntrackedDiffError {
            if case .unsupportedFile("duplicate") = error {
                return
            }
            XCTFail("Unexpected error: \(error)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }


    func testBinaryMetadataCountsTowardAggregateLineCap() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write(Data([0]), to: "one.bin")
        try fixture.write(Data([0]), to: "two.bin")
        try fixture.write(Data([0]), to: "three.bin")
        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let limits = DiffLimits(maximumBytes: 1_024, maximumLines: 4)
        let diff = try await service.diff(repository: fixture.url, kind: .unstaged, changes: status.changes, limits: limits)
        XCTAssertEqual(diff.fallback?.reason, .lineLimit(4))
        XCTAssertEqual(diff.files.count, 3)
    }

    func testDiffStatsCountsUntrackedFilesBeyondOnePathspecLimit() async throws {
        let fixture = try GitFixture(testCase: self)
        let fileCount = GitService.diffPathspecCountLimit + 1
        for index in 0..<fileCount {
            try fixture.write("line\n", to: "untracked-\(index).txt")
        }

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)
        XCTAssertEqual(status.stagedLineStats, .zero)
        XCTAssertEqual(
            status.unstagedLineStats,
            DiffLineStats(additions: fileCount, deletions: 0, hasNonCodeFiles: true)
        )
    }

    func testDiffStatsCountsTrackedFilesBeyondOnePathspecBatch() async throws {
        let fixture = try GitFixture(testCase: self)
        let fileCount = GitService.diffPathspecCountLimit + 1
        for index in 0..<fileCount {
            try fixture.write("before\n", to: "tracked-\(index).txt")
        }
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")
        for index in 0..<fileCount {
            try fixture.write("after\n", to: "tracked-\(index).txt")
        }

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)
        XCTAssertEqual(
            status.unstagedLineStats,
            DiffLineStats(additions: fileCount, deletions: fileCount, hasNonCodeFiles: true)
        )
    }

    func testDiffStatsCountsTrackedFilesBeyondFingerprintBudget() async throws {
        let fixture = try GitFixture(testCase: self)
        let fileCount = 193
        let lineCount = 1_024
        let before = String(repeating: "before\n", count: lineCount)
        let after = String(repeating: "after\n", count: lineCount)
        for index in 0..<fileCount {
            try fixture.write(before, to: "large-\(index).swift")
        }
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")
        for index in 0..<fileCount {
            try fixture.write(after, to: "large-\(index).swift")
        }

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)
        let totalLines = fileCount * lineCount
        XCTAssertEqual(
            status.unstagedLineStats,
            DiffLineStats(
                additions: totalLines,
                deletions: totalLines,
                hasCodeFiles: true,
                slocAvailability: .unavailable
            )
        )
    }

    func testDiffStatsCountsUntrackedFilesBeyondFingerprintBudget() async throws {
        let fixture = try GitFixture(testCase: self)
        let fileCount = 193
        let lineCount = 1_024
        let content = String(repeating: "line\n", count: lineCount)
        for index in 0..<fileCount {
            try fixture.write(content, to: "large-untracked-\(index).txt")
        }

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)
        XCTAssertEqual(
            status.unstagedLineStats,
            DiffLineStats(additions: fileCount * lineCount, deletions: 0, hasNonCodeFiles: true)
        )
    }

    func testTrackedPathspecPreflightRejectsOversizedSelection() {
        XCTAssertTrue(GitService.isDiffPathspecWithinLimit(["short.txt"]))
        XCTAssertFalse(GitService.isDiffPathspecWithinLimit(
            Array(repeating: "file.txt", count: GitService.diffPathspecCountLimit + 1)
        ))
        XCTAssertFalse(GitService.isDiffPathspecWithinLimit([
            String(repeating: "x", count: GitService.diffPathspecByteLimit)
        ]))
    }

    func testDiffRejectsLossyRenameSourceBeforeGitPathspec() async throws {
        let runner = RecordingGitRunner(responses: [])
        let change = FileChange(
            gitPath: GitPath("new.txt"),
            originalGitPath: GitPath(bytes: Data([0x6F, 0x6C, 0x64, 0xFF, 0x2E, 0x74, 0x78, 0x74])),
            indexState: .renamed,
            worktreeState: .unmodified,
            kind: .renamed,
            submoduleState: nil
        )

        let diff = try await GitService(runner: runner).diff(
            repository: URL(fileURLWithPath: "/repository"),
            kind: .staged,
            changes: [change]
        )

        XCTAssertEqual(diff.files.first?.content, .unavailable(.invalidPath))
        let invocations = await runner.invocations
        XCTAssertTrue(invocations.isEmpty)
    }

    func testUncommittedDiffIncludesStagedUnstagedAndUntrackedChanges() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("base\n", to: "staged.txt")
        try fixture.write("base\n", to: "unstaged.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")

        try fixture.write("staged\n", to: "staged.txt")
        try fixture.git("add", "--", "staged.txt")
        try fixture.write("unstaged\n", to: "unstaged.txt")
        try fixture.write("untracked\n", to: "untracked.txt")

        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let diff = try await service.diff(repository: fixture.url, kind: .uncommitted, changes: status.changes)

        XCTAssertNil(diff.fallback)
        XCTAssertEqual(Set(diff.files.map(\.path)), Set(["staged.txt", "unstaged.txt", "untracked.txt"]))
        XCTAssertTrue(diff.text.contains("+staged\n"))
        XCTAssertTrue(diff.text.contains("+unstaged\n"))
        XCTAssertTrue(diff.text.contains("+untracked\n"))
    }

    func testUncommittedDiffIncludesStagedChangesBeforeFirstCommit() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("new\n", to: "new.txt")
        try fixture.git("add", "--", "new.txt")

        let service = GitService()
        let status = try await service.status(repository: fixture.url)
        let diff = try await service.diff(repository: fixture.url, kind: .uncommitted, changes: status.changes)

        XCTAssertEqual(diff.files.map(\.path), ["new.txt"])
        XCTAssertTrue(diff.text.contains("+new\n"))
    }

    func testDiffStatsExcludesBlankAndCommentOnlyChanges() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("value = 1\n// old\n", to: "comment.swift")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")

        try fixture.write("value = 1\n\n// new\n", to: "comment.swift")

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)

        XCTAssertEqual(
            status.unstagedLineStats,
            DiffLineStats(additions: 2, deletions: 1, hasCodeFiles: true)
        )
    }

    func testDiffStatsHandlesBinaryFilesWithoutSLOC() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write(Data([0, 1, 2]), to: "image.bin")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")

        try fixture.write(Data([0, 1, 3]), to: "image.bin")

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)
        let stats = try XCTUnwrap(status.unstagedLineStats)

        XCTAssertEqual(stats.additions, 0)
        XCTAssertEqual(stats.deletions, 0)
        XCTAssertTrue(stats.hasNonCodeFiles)
        XCTAssertFalse(stats.hasCodeFiles)
        XCTAssertEqual(stats.slocAvailability, .available)
    }

    func testDiffStatsHandlesCRLFAndEmptyCodeFiles() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write(Data("one\r\ntwo\r\n".utf8), to: "crlf.swift")
        try fixture.write(Data(), to: "empty.swift")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")

        try fixture.write(Data("one\r\ntwo\r\nthree\r\n".utf8), to: "crlf.swift")
        try fixture.write("value = 1\n", to: "empty.swift")

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)

        XCTAssertEqual(
            status.unstagedLineStats,
            DiffLineStats(additions: 2, deletions: 0, slocAdditions: 2, hasCodeFiles: true)
        )
    }

    func testDiffStatsHandlesCodeRenames() async throws {
        let fixture = try GitFixture(testCase: self)
        try fixture.write("value = 1\n", to: "old.swift")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")

        try fixture.git("mv", "old.swift", "new.swift")
        try fixture.write("value = 2\n", to: "new.swift")
        try fixture.git("add", "-A")

        let status = try await GitService().status(repository: fixture.url, includeDiffStats: true)
        let stats = try XCTUnwrap(status.stagedLineStats)

        XCTAssertFalse(stats.hasNonCodeFiles)
        XCTAssertTrue(stats.hasCodeFiles)
        XCTAssertEqual(stats.slocAvailability, .available)
        XCTAssertEqual(stats.slocAdditions, stats.additions)
        XCTAssertEqual(stats.slocDeletions, stats.deletions)
    }

}
