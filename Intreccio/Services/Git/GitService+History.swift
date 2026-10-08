import Darwin
import Foundation

extension GitService {
  private static let historyTipOutputLimit = 2 * 1_024

  func historyTips(repository: URL, branchReference: String) async throws -> HistoryTips? {
    guard branchReference.hasPrefix("refs/heads/") || branchReference.hasPrefix("refs/remotes/")
    else { return nil }
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

    let result: ProcessCommandResult
    do {
      result = try await runner.run(
        repository: repository,
        arguments: [
          "for-each-ref",
          "--format=%(objectname)%00%(upstream)%00%(upstream:objectname)",
          "--count=1",
          branchRef
        ],
        environment: readEnvironment,
        outputLimit: Self.historyTipOutputLimit,
        priority: .selectedRepository
      )
    } catch let error as ProcessRunnerError {
      guard Self.isUnsupportedUpstreamFormat(error) else { throw error }
      return try await compatibleHistoryTips(repository: repository, branchRef: branchRef)
    }
    let fields = result.standardOutput.split(
      separator: 0,
      maxSplits: 2,
      omittingEmptySubsequences: false
    )
    guard fields.count == 3 else {
      return HistoryTips(localObjectID: nil, upstreamObjectID: nil)
    }

    let localObjectID = String(decoding: fields[0], as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let upstreamRef = String(decoding: fields[1], as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let upstreamObjectID = String(decoding: fields[2], as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return HistoryTips(
      localObjectID: localObjectID.isEmpty ? nil : localObjectID,
      upstreamObjectID: upstreamRef.hasPrefix("refs/remotes/") && !upstreamObjectID.isEmpty
        ? upstreamObjectID
        : nil
    )
  }

  private func compatibleHistoryTips(repository: URL, branchRef: String) async throws -> HistoryTips {
    let localObjectID = try await headObjectID(repository: repository)
    let branchName = String(branchRef.dropFirst("refs/heads/".count))
    let upstreamRefResult = try await runner.run(
      repository: repository,
      arguments: [
        "rev-parse", "--symbolic-full-name", "--verify", "\(branchName)@{upstream}"
      ],
      environment: readEnvironment,
      acceptedExitCodes: [0, 1, 128],
      outputLimit: Self.historyTipOutputLimit,
      priority: .selectedRepository
    )
    guard upstreamRefResult.exitCode == 0 else {
      return HistoryTips(localObjectID: localObjectID, upstreamObjectID: nil)
    }
    let upstreamRef = String(decoding: upstreamRefResult.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard upstreamRef.hasPrefix("refs/remotes/") else {
      return HistoryTips(localObjectID: localObjectID, upstreamObjectID: nil)
    }
    let upstreamObjectResult = try await runner.run(
      repository: repository,
      arguments: ["show-ref", "--verify", "--hash", upstreamRef],
      environment: readEnvironment,
      acceptedExitCodes: [0, 1, 128],
      outputLimit: Self.historyTipOutputLimit,
      priority: .selectedRepository
    )
    guard upstreamObjectResult.exitCode == 0 else {
      return HistoryTips(localObjectID: localObjectID, upstreamObjectID: nil)
    }
    let upstreamObjectID = String(decoding: upstreamObjectResult.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return HistoryTips(
      localObjectID: localObjectID,
      upstreamObjectID: upstreamObjectID.isEmpty ? nil : upstreamObjectID
    )
  }

  private static func isUnsupportedUpstreamFormat(_ error: ProcessRunnerError) -> Bool {
    guard case .nonZeroExit(let result) = error else { return false }
    let message = result.standardErrorText
    return message.contains("unrecognized %(upstream)")
      || (message.contains("unknown") && message.contains("%(upstream)"))
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
    let revisions: [String]
    switch scope {
    case .mixed:
      revisions = tips.localObjectID.map { [$0] } ?? []
    case .local:
      guard let localObjectID = tips.localObjectID else { return .empty }
      revisions =
        if let upstreamObjectID = tips.upstreamObjectID {
          [localObjectID, "--not", upstreamObjectID]
        } else {
          [localObjectID]
        }
    case .upstream:
      revisions = tips.upstreamObjectID.map { [$0] } ?? []
    case .unmergedUpstream:
      guard let upstreamObjectID = tips.upstreamObjectID else { return .empty }
      revisions =
        if let localObjectID = tips.localObjectID {
          [upstreamObjectID, "--not", localObjectID]
        } else {
          [upstreamObjectID]
        }
    }
    guard !revisions.isEmpty else { return .empty }
    let safeSkip = max(0, skip)
    let result = try await runner.run(
      repository: repository,
      arguments: [
        "log", "--skip=\(safeSkip)", "-n", String(Self.historyPageSize),
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
      unavailableCommitCount: parsed.unavailableCommitCount
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

  nonisolated private static func parseHistoryObjectIDs(_ data: Data) -> [String] {
    let fields = splitNULRecords(data)
    let candidates =
      fields.isEmpty
      ? String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
      : fields.map {
        String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
