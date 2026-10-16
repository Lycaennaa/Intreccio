import Foundation

extension GitService {
  private static let historyStatusOutputLimit = SelectedHistoryState.maximumLoadedCommits * 65

  func branchHistoryTips(
    repository: URL,
    branchReference: String
  ) async throws -> HistoryTips? {
    let result: ProcessCommandResult
    do {
      result = try await runner.run(
        repository: repository,
        arguments: [
          "for-each-ref",
          "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:objectname)",
          "--count=1",
          branchReference
        ],
        environment: readEnvironment,
        outputLimit: Self.historyTipOutputLimit,
        priority: .selectedRepository
      )
    } catch let error as ProcessRunnerError {
      if Self.isUnsupportedUpstreamFormat(error) {
        let fallback = try await compatibleHistoryTips(
          repository: repository,
          branchRef: branchReference
        )
        return fallback.localObjectID == nil ? nil : fallback
      }
      guard case .nonZeroExit = error else { throw error }
      let exactRefResult: ProcessCommandResult
      do {
        exactRefResult = try await runner.run(
          repository: repository,
          arguments: ["show-ref", "--verify", "--hash", branchReference],
          environment: readEnvironment,
          acceptedExitCodes: [0, 1],
          outputLimit: Self.historyTipOutputLimit,
          priority: .selectedRepository
        )
      } catch let exactRefError as ProcessRunnerError {
        if case .nonZeroExit(let result) = exactRefError,
          result.standardErrorText.contains("not a valid ref")
        {
          return nil
        }
        throw exactRefError
      }
      if exactRefResult.exitCode == 0 { throw error }
      return nil
    }
    let fields = result.standardOutput.split(
      separator: 0,
      maxSplits: 3,
      omittingEmptySubsequences: false
    )
    guard fields.count == 4,
      let resolvedRef = String(bytes: fields[0], encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      resolvedRef == branchReference,
      let localObjectID = String(bytes: fields[1], encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      localObjectID.count == 40 || localObjectID.count == 64,
      localObjectID.allSatisfy(\.isHexDigit)
    else { return nil }
    let upstreamRef = String(bytes: fields[2], encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let candidateUpstreamObjectID = String(bytes: fields[3], encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let upstreamObjectID: String?
    if let upstreamRef, upstreamRef.hasPrefix("refs/remotes/"),
      let candidateUpstreamObjectID,
      candidateUpstreamObjectID.count == 40 || candidateUpstreamObjectID.count == 64,
      candidateUpstreamObjectID.allSatisfy(\.isHexDigit)
    {
      upstreamObjectID = candidateUpstreamObjectID
    } else {
      upstreamObjectID = nil
    }
    return HistoryTips(localObjectID: localObjectID, upstreamObjectID: upstreamObjectID)
  }

  func compatibleHistoryTips(repository: URL, branchRef: String) async throws -> HistoryTips {
    let localObjectResult = try await runner.run(
      repository: repository,
      arguments: ["show-ref", "--verify", "--hash", branchRef],
      environment: readEnvironment,
      acceptedExitCodes: [0, 1, 128],
      outputLimit: Self.historyTipOutputLimit,
      priority: .selectedRepository
    )
    guard localObjectResult.exitCode == 0 else {
      if localObjectResult.exitCode == 1
        || localObjectResult.standardErrorText.contains("not a valid ref")
      {
        return HistoryTips(localObjectID: nil, upstreamObjectID: nil)
      }
      throw ProcessRunnerError.nonZeroExit(localObjectResult)
    }
    guard let localObjectID = String(
      bytes: localObjectResult.standardOutput, encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines),
      localObjectID.count == 40 || localObjectID.count == 64,
      localObjectID.allSatisfy(\.isHexDigit)
    else {
      return HistoryTips(localObjectID: nil, upstreamObjectID: nil)
    }
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
    guard let upstreamRef = String(bytes: upstreamRefResult.standardOutput, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      upstreamRef.hasPrefix("refs/remotes/")
    else {
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
    guard let upstreamObjectID = String(
      bytes: upstreamObjectResult.standardOutput, encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines), !upstreamObjectID.isEmpty else {
      return HistoryTips(localObjectID: localObjectID, upstreamObjectID: nil)
    }
    return HistoryTips(
      localObjectID: localObjectID,
      upstreamObjectID: upstreamObjectID
    )
  }

  static func isUnsupportedUpstreamFormat(_ error: ProcessRunnerError) -> Bool {
    guard case .nonZeroExit(let result) = error else { return false }
    let message = result.standardErrorText
    return message.contains("unrecognized %(upstream)")
      || (message.contains("unknown") && message.contains("%(upstream)"))
  }

  func historyStatusObjectIDs(
    repository: URL,
    scope: HistoryScope,
    tips: HistoryTips,
    skip: Int,
    commits: [Commit]
  ) async throws -> Set<String>? {
    switch scope {
    case .mixed:
      guard skip == 0,
        let localObjectID = tips.localObjectID,
        let upstreamObjectID = tips.upstreamObjectID
      else { return nil }
      return try await localOnlyObjectIDs(
        repository: repository,
        localObjectID: localObjectID,
        upstreamObjectID: upstreamObjectID
      )
    case .local:
      guard tips.upstreamObjectID != nil else { return nil }
      return Set(commits.map(\.objectID))
    case .upstream, .unmergedUpstream:
      return nil
    }
  }

  private func localOnlyObjectIDs(
    repository: URL,
    localObjectID: String,
    upstreamObjectID: String
  ) async throws -> Set<String> {
    let result = try await runner.run(
      repository: repository,
      arguments: [
        "log",
        "--format=%H",
        "--max-count=\(SelectedHistoryState.maximumLoadedCommits)",
        localObjectID,
        "--not",
        upstreamObjectID
      ],
      environment: readEnvironment,
      outputLimit: Self.historyStatusOutputLimit,
      priority: .selectedRepository
    )
    return Set(Self.parseHistoryObjectIDs(result.standardOutput))
  }
}
