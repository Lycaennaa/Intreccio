import Foundation

nonisolated struct GitWorktree: Sendable, Equatable, Identifiable {
    let path: URL
    let branchReference: String?

    var id: URL { path.standardizedFileURL }
    var branchName: String? {
        guard let branchReference else { return nil }
        let name = branchReference.split(separator: "/").dropFirst(2).joined(separator: "/")
        return name.isEmpty ? nil : name
    }
}

nonisolated struct GitTreeEntry: Sendable, Equatable, Identifiable {
  let mode: String
  let type: String
  let objectID: String
  let path: GitPath

  var id: GitPath { path }
}

nonisolated enum GitBlobPreview: Sendable, Equatable {
  case text(String)
  case binary
  case tooLarge
}

extension GitService {
  private static let branchTreeOutputLimit = ProcessRunner.defaultOutputLimit
  static let branchBlobPreviewLimit = 1 * 1_024 * 1_024
  func branchReferences(repository: URL) async throws -> [GitBranchReference] {
    let result = try await runner.run(
      repository: repository,
      arguments: [
        "for-each-ref",
        "--format=%(refname)%00%(refname:short)%00%(objectname)%00%(HEAD)%00%(symref)",
        "refs/heads",
        "refs/remotes"
      ],
      environment: readEnvironment,
      outputLimit: ProcessRunner.defaultOutputLimit,
      priority: .selectedRepository
    )
    var branches: [GitBranchReference] = []
    for record in result.standardOutput.split(separator: 0x0A, omittingEmptySubsequences: true) {
      let fields = record.split(separator: 0, omittingEmptySubsequences: false)
      guard fields.count == 5,
        fields[4].isEmpty,
        let branch = Self.parseBranchReference(fields)
      else { continue }
      branches.append(branch)
    }
    return branches
  }
  private nonisolated static func parseBranchReference(
    _ fields: [Data.SubSequence]
  ) -> GitBranchReference? {
    guard fields.count == 5,
      let refName = String(bytes: fields[0], encoding: .utf8),
      let name = String(bytes: fields[1], encoding: .utf8),
      let objectID = String(bytes: fields[2], encoding: .utf8)
    else { return nil }
    guard refName.hasPrefix("refs/heads/") || refName.hasPrefix("refs/remotes/"),
      !name.isEmpty,
      objectID.count == 40 || objectID.count == 64,
      objectID.allSatisfy(\.isHexDigit)
    else { return nil }
    return GitBranchReference(
      refName: refName,
      name: name,
      objectID: objectID,
      isCurrent: fields[3] == Data("*".utf8)
    )
  }

    func worktrees(repository: URL) async throws -> [GitWorktree] {
        let result = try await runner.run(
            repository: repository,
            arguments: ["worktree", "list", "--porcelain", "-z"],
            environment: readEnvironment,
            outputLimit: ProcessRunner.defaultOutputLimit,
            priority: .selectedRepository
        )
        var worktrees: [GitWorktree] = []
        var path: URL?
        var branchReference: String?
        var shouldOmit = false
        for field in result.standardOutput.split(separator: 0, omittingEmptySubsequences: true) {
            let separator = field.firstIndex(of: 0x20)
            let keyData = separator.map { field[..<$0] } ?? field
            guard let key = String(bytes: keyData, encoding: .utf8) else { continue }
            let valueData = separator.map { field[field.index(after: $0)...] }
            switch key {
            case "worktree":
                if let path, !shouldOmit {
                    worktrees.append(GitWorktree(path: path, branchReference: branchReference))
                }
                path = valueData
                    .flatMap { String(bytes: $0, encoding: .utf8) }
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                branchReference = nil
                shouldOmit = false
            case "branch":
                branchReference = valueData.flatMap { String(bytes: $0, encoding: .utf8) }
            case "bare", "prunable":
                shouldOmit = true
            default:
                break
            }
        }
        if let path, !shouldOmit {
            worktrees.append(GitWorktree(path: path, branchReference: branchReference))
        }
        return worktrees
    }

    func linkedWorktreeURL(repository: URL, branchReference: String) async throws -> URL? {
        guard branchReference.hasPrefix("refs/heads/") else { return nil }
        let worktrees = try await worktrees(repository: repository)
        return worktrees.first { $0.branchReference == branchReference }?.path
    }

  func branchTreeEntries(repository: URL, commitObjectID: String) async throws -> [GitTreeEntry] {
    guard Self.isFullObjectID(commitObjectID) else {
      throw GitServiceError.invalidObjectID(commitObjectID)
    }
    let result = try await runner.run(
      repository: repository,
      arguments: ["ls-tree", "-r", "-z", "--full-tree", commitObjectID],
      environment: readEnvironment,
      outputLimit: Self.branchTreeOutputLimit,
      priority: .selectedRepository
    )
    var entries: [GitTreeEntry] = []
    for record in result.standardOutput.split(separator: 0, omittingEmptySubsequences: true) {
      guard let tab = record.firstIndex(of: 0x09) else { continue }
      let fields = record[..<tab].split(separator: 0x20, omittingEmptySubsequences: true)
      guard fields.count == 3 else { continue }
      guard let mode = String(bytes: fields[0], encoding: .utf8),
        let type = String(bytes: fields[1], encoding: .utf8),
        let objectID = String(bytes: fields[2], encoding: .utf8)
      else { continue }
      let path = GitPath(bytes: Data(record[record.index(after: tab)...]))
      guard path.relativeComponents != nil,
        Self.isFullObjectID(objectID),
        type == "blob" || type == "commit"
      else { continue }
      entries.append(GitTreeEntry(mode: mode, type: type, objectID: objectID, path: path))
    }
    return entries
  }

  func branchBlobPreview(repository: URL, objectID: String) async throws -> GitBlobPreview {
    guard Self.isFullObjectID(objectID) else { throw GitServiceError.invalidObjectID(objectID) }
    let result: ProcessCommandResult
    do {
      result = try await runner.run(
        repository: repository,
        arguments: ["cat-file", "blob", objectID],
        environment: readEnvironment,
        outputLimit: Self.branchBlobPreviewLimit,
        priority: .selectedRepository
      )
    } catch ProcessRunnerError.outputLimitExceeded(let stream, _, _) where stream == .standardOutput {
      return .tooLarge
    }
    guard !result.standardOutput.contains(0),
      let text = String(data: result.standardOutput, encoding: .utf8)
    else { return .binary }
    return .text(text)
  }

  private nonisolated static func isFullObjectID(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
  }
}
