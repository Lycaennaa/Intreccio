import Foundation

nonisolated enum GitFileState: String, CaseIterable, Sendable {
    case unmodified = "."
    case modified = "M"
    case typeChanged = "T"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case unmerged = "U"
}

nonisolated enum FileChangeKind: Sendable {
    case ordinary
    case renamed
    case copied
    case unmerged
    case untracked
    case ignored
}

nonisolated struct FileChange: Sendable, Equatable {
    let gitPath: GitPath
    let originalGitPath: GitPath?
    let indexState: GitFileState
    let worktreeState: GitFileState
    let kind: FileChangeKind
    let submoduleState: String?

    var path: String {
        gitPath.decodedString
    }

    var originalPath: String? {
        originalGitPath?.decodedString
    }

    var displayPath: String {
        gitPath.displayString
    }

    var displayOriginalPath: String? {
        originalGitPath?.displayString
    }

    var isPathLossy: Bool {
        gitPath.isLossy || originalGitPath?.isLossy == true
    }

    var isAddressable: Bool {
        gitPath.isFileActionAddressable && (originalGitPath?.isFileActionAddressable ?? true)
    }
    var isGitAddressable: Bool {
        gitPath.isAddressable && (originalGitPath?.isAddressable ?? true)
    }

    var isIgnoreAddressable: Bool {
        gitPath.isIgnoreAddressable && (originalGitPath?.isIgnoreAddressable ?? true)
    }

    init(
        path: String,
        originalPath: String?,
        indexState: GitFileState,
        worktreeState: GitFileState,
        kind: FileChangeKind,
        submoduleState: String?
    ) {
        self.init(
            gitPath: GitPath(path),
            originalGitPath: originalPath.map(GitPath.init),
            indexState: indexState,
            worktreeState: worktreeState,
            kind: kind,
            submoduleState: submoduleState
        )
    }

    init(
        gitPath: GitPath,
        originalGitPath: GitPath?,
        indexState: GitFileState,
        worktreeState: GitFileState,
        kind: FileChangeKind,
        submoduleState: String?
    ) {
        self.gitPath = gitPath
        self.originalGitPath = originalGitPath
        self.indexState = indexState
        self.worktreeState = worktreeState
        self.kind = kind
        self.submoduleState = submoduleState
    }
}

nonisolated struct BranchStatus: Sendable, Equatable {
    var head: String?
    var objectID: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
}

nonisolated struct RepoStatus: Sendable, Equatable {
    var branch = BranchStatus()
    var changes: [FileChange] = []
    var isRebaseInProgress = false
    var hasStash = false
    var stagedLineStats: DiffLineStats?
    var unstagedLineStats: DiffLineStats?
    var hasConflicts: Bool {
        changes.contains { $0.kind == .unmerged }
    }

    var isClean: Bool {
        changes.isEmpty
    }
}

nonisolated enum PorcelainV2ParserError: Error, Equatable, CustomStringConvertible {
    case malformedRecord(String)
    case missingRenameSource(String)

    var description: String {
        switch self {
        case .malformedRecord(let record):
            "Malformed porcelain v2 record: \(record)"
        case .missingRenameSource(let path):
            "Rename/copy record missing original path for: \(path)"
        }
    }
}

nonisolated enum PorcelainV2Parser {
    static func parse(_ data: Data) throws -> RepoStatus {
        let records = splitNULRecords(data)
        var status = RepoStatus()
        var index = 0

        while index < records.count {
            let recordData = records[index]
            let record = String(decoding: recordData, as: UTF8.self)
            index += 1

            if record.hasPrefix("# stash ") {
                status.hasStash = Int(record.dropFirst(8)).map { $0 > 0 } ?? false
            } else if record.hasPrefix("# ") {
                parseHeader(record, into: &status.branch)
            } else if recordData.starts(with: Data("1 ".utf8)) {
                status.changes.append(try parseOrdinary(recordData))
            } else if recordData.starts(with: Data("2 ".utf8)) {
                guard index < records.count else {
                    throw PorcelainV2ParserError.missingRenameSource(path(in: recordData) ?? record)
                }
                let originalPath = GitPath(bytes: records[index])
                index += 1
                status.changes.append(try parseRename(recordData, originalPath: originalPath))
            } else if recordData.starts(with: Data("u ".utf8)) {
                status.changes.append(try parseUnmerged(recordData))
            } else if recordData.starts(with: Data("? ".utf8)) {
                status.changes.append(FileChange(
                    gitPath: GitPath(bytes: Data(recordData.dropFirst(2))),
                    originalGitPath: nil,
                    indexState: .unmodified,
                    worktreeState: .unmodified,
                    kind: .untracked,
                    submoduleState: nil
                ))
            } else if recordData.starts(with: Data("! ".utf8)) {
                status.changes.append(FileChange(
                    gitPath: GitPath(bytes: Data(recordData.dropFirst(2))),
                    originalGitPath: nil,
                    indexState: .unmodified,
                    worktreeState: .unmodified,
                    kind: .ignored,
                    submoduleState: nil
                ))
            } else {
                throw PorcelainV2ParserError.malformedRecord(record)
            }
        }

        return status
    }

    private static func parseHeader(_ record: String, into branch: inout BranchStatus) {
        let valueStart = record.firstIndex(of: " ").map { record.index(after: $0) }
        guard let valueStart else { return }
        let fieldAndValue = record[valueStart...]
        guard let separator = fieldAndValue.firstIndex(of: " ") else { return }
        let field = fieldAndValue[..<separator]
        let value = String(fieldAndValue[fieldAndValue.index(after: separator)...])

        switch field {
        case "branch.oid": branch.objectID = value == "(initial)" ? nil : value
        case "branch.head": branch.head = value == "(detached)" ? nil : value
        case "branch.upstream": branch.upstream = value
        case "branch.ab":
            let counts = value.split(separator: " ")
            if counts.count == 2 {
                branch.ahead = Int(counts[0].dropFirst()) ?? 0
                branch.behind = Int(counts[1].dropFirst()) ?? 0
            }
        default: break
        }
    }

    private static func parseOrdinary(_ record: Data) throws -> FileChange {
        let fields = splitFields(record, maxSplits: 8)
        guard fields.count == 9 else { throw malformed(record) }
        let states = try parseStates(fields[1], record: record)
        return FileChange(
            gitPath: GitPath(bytes: fields[8]),
            originalGitPath: nil,
            indexState: states.0,
            worktreeState: states.1,
            kind: .ordinary,
            submoduleState: String(decoding: fields[2], as: UTF8.self)
        )
    }

    private static func parseRename(_ record: Data, originalPath: GitPath) throws -> FileChange {
        let fields = splitFields(record, maxSplits: 9)
        guard fields.count == 10, let scoreKind = String(decoding: fields[8], as: UTF8.self).first else {
            throw malformed(record)
        }
        let states = try parseStates(fields[1], record: record)
        let kind: FileChangeKind
        switch scoreKind {
        case "R": kind = .renamed
        case "C": kind = .copied
        default: throw malformed(record)
        }
        return FileChange(
            gitPath: GitPath(bytes: fields[9]),
            originalGitPath: originalPath,
            indexState: states.0,
            worktreeState: states.1,
            kind: kind,
            submoduleState: String(decoding: fields[2], as: UTF8.self)
        )
    }

    private static func parseUnmerged(_ record: Data) throws -> FileChange {
        let fields = splitFields(record, maxSplits: 10)
        guard fields.count == 11 else { throw malformed(record) }
        let states = try parseStates(fields[1], record: record)
        return FileChange(
            gitPath: GitPath(bytes: fields[10]),
            originalGitPath: nil,
            indexState: states.0,
            worktreeState: states.1,
            kind: .unmerged,
            submoduleState: String(decoding: fields[2], as: UTF8.self)
        )
    }

    private static func parseStates(
        _ value: Data,
        record: Data
    ) throws -> (GitFileState, GitFileState) {
        let characters = Array(String(decoding: value, as: UTF8.self))
        guard characters.count == 2,
              let index = GitFileState(rawValue: String(characters[0])),
              let worktree = GitFileState(rawValue: String(characters[1])) else {
            throw malformed(record)
        }
        return (index, worktree)
    }

    private static func path(in record: Data) -> String? {
        splitFields(record, maxSplits: 9).last.map { GitPath(bytes: $0).displayString }
    }

    private static func malformed(_ record: Data) -> PorcelainV2ParserError {
        .malformedRecord(String(decoding: record, as: UTF8.self))
    }

    private static func splitNULRecords(_ data: Data) -> [Data] {
        var records: [Data] = []
        var start = 0
        for index in 0..<data.count where data[index] == 0 {
            if index > start { records.append(Data(data[start..<index])) }
            start = index + 1
        }
        if start < data.count { records.append(Data(data[start..<data.count])) }
        return records
    }

    private static func splitFields(_ data: Data, maxSplits: Int) -> [Data] {
        var fields: [Data] = []
        var start = 0
        var splits = 0
        for index in 0..<data.count where data[index] == 0x20 && splits < maxSplits {
            fields.append(Data(data[start..<index]))
            start = index + 1
            splits += 1
        }
        fields.append(Data(data[start..<data.count]))
        return fields
    }
}
