import Darwin
import Foundation

extension GitService {
  static let historyTipOutputLimit = 2 * 1_024

  func historyTips(repository: URL, branchReference: String) async throws -> HistoryTips? {
    guard branchReference.hasPrefix("refs/heads/") || branchReference.hasPrefix("refs/remotes/")
    else { return nil }
    if branchReference.hasPrefix("refs/heads/") {
      return try await branchHistoryTips(
        repository: repository,
        branchReference: branchReference
      )
    }
    let result = try await runner.run(
      repository: repository,
      arguments: ["show-ref", "--verify", "--hash", branchReference],
      environment: readEnvironment,
      acceptedExitCodes: [0, 1],
      outputLimit: Self.historyTipOutputLimit,
      priority: .selectedRepository
    )
    guard result.exitCode == 0 else { return nil }
    guard let objectID = String(bytes: result.standardOutput, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    guard objectID.count == 40 || objectID.count == 64, objectID.allSatisfy(\.isHexDigit)
    else { return nil }
    return HistoryTips(localObjectID: objectID, upstreamObjectID: nil)
  }

  func history(repository: URL, skip: Int = 0) async throws -> [Commit] {
    let tips = try await historyTips(repository: repository)
    return try await history(repository: repository, scope: .mixed, tips: tips, skip: skip)
  }

  func headObjectID(repository: URL) async throws -> String? {
    do {
      let result = try await runner.run(
        repository: repository,
        arguments: ["rev-parse", "--verify", "--quiet", "HEAD"],
        environment: readEnvironment,
        outputLimit: Self.historyTipOutputLimit,
        priority: .selectedRepository
      )
      let objectID = String(decoding: result.standardOutput, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return objectID.isEmpty ? nil : objectID
    } catch ProcessRunnerError.nonZeroExit(let result)
      where result.exitCode == 1 && result.standardOutput.isEmpty && result.standardError.isEmpty {
      return nil
    }
  }

  func history(repository: URL, headObjectID: String, skip: Int = 0) async throws -> [Commit] {
    try await history(
      repository: repository,
      scope: .mixed,
      tips: HistoryTips(localObjectID: headObjectID, upstreamObjectID: nil),
      skip: skip
    )
  }

  func historyTips(repository: URL) async throws -> HistoryTips {
    let symbolicHeadResult = try await runner.run(
      repository: repository,
      arguments: ["symbolic-ref", "--quiet", "HEAD"],
      environment: readEnvironment,
      acceptedExitCodes: [0, 1],
      outputLimit: Self.historyTipOutputLimit,
      priority: .selectedRepository
    )
    guard symbolicHeadResult.exitCode == 0 else {
      guard symbolicHeadResult.standardOutput.isEmpty, symbolicHeadResult.standardError.isEmpty
      else {
        throw ProcessRunnerError.nonZeroExit(symbolicHeadResult)
      }
      return HistoryTips(
        localObjectID: try await headObjectID(repository: repository),
        upstreamObjectID: nil
      )
    }

    let branchRef = String(decoding: symbolicHeadResult.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard branchRef.hasPrefix("refs/heads/") else {
      return HistoryTips(
        localObjectID: try await headObjectID(repository: repository),
        upstreamObjectID: nil
      )
    }

    return try await branchHistoryTips(
      repository: repository,
      branchReference: branchRef
    ) ?? HistoryTips(localObjectID: nil, upstreamObjectID: nil)
  }

  func history(
    repository: URL,
    scope: HistoryScope,
    tips: HistoryTips,
    skip: Int = 0
  ) async throws -> [Commit] {
    try await historyPage(repository: repository, scope: scope, tips: tips, skip: skip).commits
  }

  func historyPage(
    repository: URL,
    scope: HistoryScope,
    tips: HistoryTips,
    skip: Int = 0
  ) async throws -> HistoryMetadataPage {
    guard let revisions = Self.historyRevisions(scope: scope, tips: tips) else { return .empty }
    let result = try await runner.run(
      repository: repository,
      arguments: [
        "log", "--skip=\(max(0, skip))", "-n", String(Self.historyPageSize),
        "--format=\(CommitParser.format)"
      ] + revisions,
      environment: readEnvironment,
      outputLimit: Self.historyTipOutputLimit,
      priority: .selectedRepository
    )
    let objectIDs = Self.parseHistoryObjectIDs(result.standardOutput)
    guard !objectIDs.isEmpty else {
      guard result.standardOutput.isEmpty else {
        throw CommitParserError.malformedFieldCount(0)
      }
      return .empty
    }
    let metadataPage = try await fetchHistoryMetadataPage(
      repository: repository,
      objectIDs: objectIDs
    )
    let notOnUpstreamObjectIDs = try await historyStatusObjectIDs(
      repository: repository,
      scope: scope,
      tips: tips,
      skip: skip,
      commits: metadataPage.commits
    )
    return HistoryMetadataPage(
      commits: metadataPage.commits,
      completeness: metadataPage.completeness,
      omittedCommitCount: metadataPage.omittedCommitCount,
      unavailableCommitCount: metadataPage.unavailableCommitCount,
      notOnUpstreamObjectIDs: notOnUpstreamObjectIDs
    )
  }

  private static func historyRevisions(scope: HistoryScope, tips: HistoryTips) -> [String]? {
    switch scope {
    case .mixed:
      return tips.localObjectID.map { [$0] }
    case .local:
      guard let localObjectID = tips.localObjectID else { return nil }
      return tips.upstreamObjectID.map { [localObjectID, "--not", $0] } ?? [localObjectID]
    case .upstream:
      return tips.upstreamObjectID.map { [$0] }
    case .unmergedUpstream:
      guard let upstreamObjectID = tips.upstreamObjectID else { return nil }
      return tips.localObjectID.map { [upstreamObjectID, "--not", $0] } ?? [upstreamObjectID]
    }
  }

  private func fetchHistoryMetadataPage(
    repository: URL,
    objectIDs: [String]
  ) async throws -> HistoryMetadataPage {
    let input = Data((objectIDs.map { $0 + "\n" }.joined()).utf8)
    let metadataResult: ProcessCommandResult
    let transportCompleteness: GitOutputCompleteness
    do {
      metadataResult = try await runner.run(
        repository: repository,
        arguments: ["cat-file", "--batch"],
        input: input,
        environment: readEnvironment,
        outputLimit: HistoryMetadataLimits.default.maximumTransportBytes,
        priority: .selectedRepository
      )
      transportCompleteness = .complete
    } catch ProcessRunnerError.outputLimitExceeded(let stream, let limit, let partialResult)
      where stream == .standardOutput {
      metadataResult = partialResult
      transportCompleteness = .truncated(limit: limit)
    }
    let parsed = CommitBatchParser.parse(
      metadataResult.standardOutput,
      limits: .default,
      transportCompleteness: transportCompleteness
    )
    guard parsed.completeness != .unavailable || parsed.unavailableCommitCount > 0 else {
      throw CommitParserError.malformedFieldCount(parsed.commits.count)
    }
    return HistoryMetadataPage(
      commits: parsed.commits,
      completeness: parsed.completeness,
      omittedCommitCount: parsed.omittedCommitCount,
      unavailableCommitCount: parsed.unavailableCommitCount,
      notOnUpstreamObjectIDs: nil
    )
  }

  func show(repository: URL, objectID: String) async throws -> CommitDetails {
    try await show(repository: repository, objectID: objectID, fallbackCommit: nil)
  }

  func show(repository: URL, commit: Commit) async throws -> CommitDetails {
    try await show(repository: repository, objectID: commit.objectID, fallbackCommit: commit)
  }

  private func show(repository: URL, objectID: String, fallbackCommit: Commit?) async throws
    -> CommitDetails {
    guard objectID.count >= 4, objectID.count <= 64,
      objectID.allSatisfy(\.isHexDigit)
    else {
      throw GitServiceError.invalidObjectID(objectID)
    }
    if let fallbackCommit, fallbackCommit.objectID != objectID {
      throw GitServiceError.invalidObjectID(objectID)
    }

    let metadataResult: ProcessCommandResult
    let metadataTransportCompleteness: GitOutputCompleteness
    do {
      metadataResult = try await runner.run(
        repository: repository,
        arguments: ["cat-file", "--batch"],
        input: Data("\(objectID)\n".utf8),
        environment: readEnvironment,
        outputLimit: HistoryMetadataLimits.default.maximumTransportBytes,
        priority: .selectedRepository
      )
      metadataTransportCompleteness = .complete
    } catch ProcessRunnerError.outputLimitExceeded(let stream, let limit, let partialResult)
      where stream == .standardOutput {
      metadataResult = partialResult
      metadataTransportCompleteness = .truncated(limit: limit)
    } catch is CancellationError {
      throw CancellationError()
    } catch ProcessRunnerError.cancelled {
      throw CancellationError()
    } catch {
      guard fallbackCommit != nil else { throw error }
      metadataResult = ProcessCommandResult(
        exitCode: -1, standardOutput: Data(), standardError: Data())
      metadataTransportCompleteness = .unavailable
    }

    let parsed = CommitBatchParser.parse(
      metadataResult.standardOutput,
      limits: .default,
      transportCompleteness: metadataTransportCompleteness
    )
    let commit: Commit
    let commitMetadataUnavailable: Bool
    if parsed.commits.count == 1, let parsedCommit = parsed.commits.first {
      commit = parsedCommit
      commitMetadataUnavailable = parsed.completeness == .unavailable
    } else if let fallbackCommit {
      commit = fallbackCommit
      commitMetadataUnavailable = true
    } else {
      throw GitServiceError.expectedSingleCommit(parsed.commits.count)
    }

    let patchArguments: [String]
    let comparisonBasis: String
    if let firstParent = commit.parentIDs.first {
      patchArguments = [
        "show", "--format=", "--no-color", "--no-ext-diff", "--find-renames", "--src-prefix=a/",
        "--dst-prefix=b/",
        "--first-parent", objectID, "--"
      ]
      comparisonBasis = firstParent
    } else {
      let emptyTree: String
      do {
        emptyTree = try await emptyTreeObjectID(repository: repository)
      } catch is CancellationError {
        throw CancellationError()
      } catch ProcessRunnerError.cancelled {
        throw CancellationError()
      }
      patchArguments = [
        "diff", "--no-color", "--no-ext-diff", "--find-renames", "--src-prefix=a/",
        "--dst-prefix=b/", emptyTree, objectID, "--"
      ]
      comparisonBasis = emptyTree
    }

    let metadataLimits = HistoryMetadataLimits.default
    let summaries: DiffSummaryMetadata
    do {
      let summaryResult = try await runner.run(
        repository: repository,
        arguments: [
          "diff", "--name-status", "-z", "--no-color", "--no-ext-diff", "--find-renames",
          comparisonBasis, objectID, "--"
        ],
        environment: readEnvironment,
        outputLimit: min(Self.diffOutputLimit, metadataLimits.maximumSummaryBytes),
        priority: .selectedRepository
      )
      summaries = DiffSummaryMetadataParser.parse(
        summaryResult.standardOutput,
        limits: metadataLimits,
        transportCompleteness: .complete
      )
    } catch ProcessRunnerError.outputLimitExceeded(let stream, let limit, let partialResult)
      where stream == .standardOutput {
      summaries = DiffSummaryMetadataParser.parse(
        partialResult.standardOutput,
        limits: metadataLimits,
        transportCompleteness: .truncated(limit: limit)
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch ProcessRunnerError.cancelled {
      throw CancellationError()
    } catch {
      guard fallbackCommit != nil else { throw error }
      summaries = DiffSummaryMetadata(files: [], completeness: .unavailable, omittedFileCount: nil)
    }
    let detailsSummaries =
      commitMetadataUnavailable
      ? DiffSummaryMetadata(
        files: summaries.files,
        completeness: .unavailable,
        omittedFileCount: summaries.omittedFileCount
      )
      : summaries
    let detailsMetadata = CommitDetailsMetadata(
      subject: commit.subjectMetadata, body: commit.bodyMetadata, changedFiles: detailsSummaries)
    do {
      let patch = try await runner.run(
        repository: repository,
        arguments: patchArguments,
        environment: readEnvironment,
        outputLimit: Self.diffOutputLimit,
        priority: .selectedRepository
      )
      let rawPatch = GitRawOutput(bytes: patch.standardOutput)
      let diff = UnifiedDiffParser.parse(
        patch.standardOutput,
        summaries: summaries.files,
        rawCompleteness: .complete
      )
      return CommitDetails(
        commit: commit,
        rawPatch: rawPatch,
        diff: diff,
        comparisonBasis: comparisonBasis,
        metadata: detailsMetadata
      )
    } catch ProcessRunnerError.outputLimitExceeded(let stream, let limit, let partialResult)
      where stream == .standardOutput {
      let rawPatch = GitRawOutput(
        bytes: partialResult.standardOutput,
        completeness: .truncated(limit: limit)
      )
      let diff = UnifiedDiffParser.parse(
        partialResult.standardOutput,
        summaries: summaries.files,
        rawCompleteness: .truncated(limit: limit)
      )
      return CommitDetails(
        commit: commit,
        rawPatch: rawPatch,
        diff: diff,
        comparisonBasis: comparisonBasis,
        metadata: detailsMetadata
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch ProcessRunnerError.cancelled {
      throw CancellationError()
    }
  }

  nonisolated static func parseHistoryObjectIDs(_ data: Data) -> [String] {
    let candidates = splitNULRecords(data).flatMap { record in
      String(decoding: record, as: UTF8.self)
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
    }
    return candidates.filter { value in
      (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }
  }

  nonisolated private static func splitNULRecords(_ data: Data) -> [Data] {
    var records: [Data] = []
    var start = 0
    for index in 0..<data.count where data[index] == 0 {
      if index > start { records.append(Data(data[start..<index])) }
      start = index + 1
    }
    if start < data.count { records.append(Data(data[start..<data.count])) }
    return records
  }
}
