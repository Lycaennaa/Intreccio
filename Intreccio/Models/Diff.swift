import Foundation

nonisolated enum DiffKind: Sendable, Equatable {
    case unstaged
    case staged
    case uncommitted

    func includes(_ change: FileChange) -> Bool {
        switch self {
        case .unstaged:
            change.hasUnstagedChange
        case .staged:
            change.hasStagedChange
        case .uncommitted:
            change.hasStagedChange || change.hasUnstagedChange
        }
    }
}
nonisolated enum SourceCodeFileClassifier {
    static let extensions = [
        "swift", "py", "js", "ts", "jsx", "tsx", "c", "h", "cpp", "hpp", "m", "mm",
        "java", "kt", "rb", "go", "rs", "php", "sh", "sql"
    ]
    private static let excludedExtensions: Set<String> = [
        "json", "json5", "jsonc", "jsonl", "yaml", "yml", "txt", "md", "markdown", "csv", "tsv",
        "cfg", "conf", "config", "env", "ini", "lock", "pbxproj", "plist", "properties", "resolved",
        "sln", "csproj", "fsproj", "iml", "props", "resx", "targets", "vcxproj", "filters", "xcconfig",
        "code-workspace", "sublime-project"
    ]
    private static let excludedDirectoryNames: Set<String> = [
        "build", "builds", "carthage", "coverage", "derived", "deriveddata", "dist", "gen", "generated",
        "node_modules", "out", "pods", "third-party", "third_party", "vendor", "vendors"
    ]
    private static let excludedFileNames: Set<String> = [
        ".babelrc", ".dockerignore", ".editorconfig", ".env", ".eslintrc", ".gitattributes", ".gitignore",
        ".gitmodules", ".npmrc", ".nvmrc", ".prettierrc", ".yarnrc", "dockerfile", "gnumakefile",
        "makefile", "readme", "license", "copying", "notice", "changelog", "todo", "to-do"
    ]
    private static let excludedLanguages: Set<String> = [
        "asciidoc", "csv", "ini", "json", "json5", "jsonc", "jsonl", "markdown",
        "plain text", "restructuredtext", "toml", "tsv", "yaml"
    ]

    static func sccFileName(for path: GitPath) -> String? {
        guard !isExcludedPath(path) else { return nil }
        let url = URL(fileURLWithPath: path.decodedString)
        let fileName = url.lastPathComponent
        let lowercasedFileName = fileName.lowercased()
        let fileExtension = url.pathExtension.lowercased()
        guard !fileName.isEmpty,
              !excludedFileNames.contains(lowercasedFileName),
              !lowercasedFileName.hasPrefix(".env."),
              !lowercasedFileName.hasPrefix("dockerfile."),
              !lowercasedFileName.hasPrefix("makefile."),
              !lowercasedFileName.hasPrefix("gnumakefile."),
              !lowercasedFileName.hasSuffix(".config"),
              !excludedExtensions.contains(fileExtension) else { return nil }
        return fileName
    }

    private static func isExcludedPath(_ path: GitPath) -> Bool {
        let components = path.decodedString.split(separator: "/")
        return components.dropLast().contains { excludedDirectoryNames.contains($0.lowercased()) }
    }

    static func isExcludedSCCLanguage(_ language: String) -> Bool {
        excludedLanguages.contains(language.lowercased())
    }
}

nonisolated enum SLOCAvailability: Sendable, Equatable {
    case available
    case unavailable
}

nonisolated struct DiffLineStats: Sendable, Equatable {
    let additions: Int
    let deletions: Int
    let slocAdditions: Int
    let slocDeletions: Int
    let hasNonCodeFiles: Bool
    let hasCodeFiles: Bool
    let slocAvailability: SLOCAvailability

    init(
        additions: Int,
        deletions: Int,
        slocAdditions: Int = 0,
        slocDeletions: Int = 0,
        hasNonCodeFiles: Bool = false,
        hasCodeFiles: Bool = false,
        slocAvailability: SLOCAvailability = .available
    ) {
        self.additions = additions
        self.deletions = deletions
        self.slocAdditions = slocAdditions
        self.slocDeletions = slocDeletions
        self.hasNonCodeFiles = hasNonCodeFiles
        self.hasCodeFiles = hasCodeFiles
        self.slocAvailability = slocAvailability
    }

    static let zero = DiffLineStats(additions: 0, deletions: 0)
}

nonisolated enum DiffLineStatsParser {
    static func parse(_ data: Data) -> DiffLineStats? {
        guard !data.isEmpty else { return .zero }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        var additions = 0
        var deletions = 0
        var hasNonCodeFiles = false
        var hasCodeFiles = false
        var index = 0
        while index < fields.count {
            let values = fields[index].split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard values.count == 3,
                  let added = count(values[0]),
                  let deleted = count(values[1]) else { return nil }
            let pathIsNonCode: Bool
            let pathIsCode: Bool
            if values[2].isEmpty {
                guard index + 2 < fields.count else { return nil }
                pathIsNonCode = isNonCodePath(fields[index + 1]) || isNonCodePath(fields[index + 2])
                pathIsCode = isCodePath(fields[index + 1]) || isCodePath(fields[index + 2])
            } else {
                pathIsNonCode = isNonCodePath(values[2])
                pathIsCode = isCodePath(values[2])
            }
            let isBinary = isBinaryCount(values[0]) || isBinaryCount(values[1])
            hasNonCodeFiles = hasNonCodeFiles || pathIsNonCode || isBinary
            hasCodeFiles = hasCodeFiles || (pathIsCode && !isBinary)
            guard add(added, to: &additions),
                  add(deleted, to: &deletions) else { return nil }
            index += 1
            if values[2].isEmpty { index += 2 }
        }
        return DiffLineStats(
            additions: additions,
            deletions: deletions,
            hasNonCodeFiles: hasNonCodeFiles,
            hasCodeFiles: hasCodeFiles
        )
    }

    private static func isCodePath(_ path: Data.SubSequence) -> Bool {
        SourceCodeFileClassifier.sccFileName(for: GitPath(bytes: Data(path))) != nil
    }

    private static func isNonCodePath(_ path: Data.SubSequence) -> Bool {
        SourceCodeFileClassifier.sccFileName(for: GitPath(bytes: Data(path))) == nil
    }

    private static func isBinaryCount(_ value: Data.SubSequence) -> Bool {
        value.count == 1 && value.first == UInt8(ascii: "-")
    }

    private static func add(_ value: Int, to total: inout Int) -> Bool {
        let result = total.addingReportingOverflow(value)
        guard !result.overflow else { return false }
        total = result.partialValue
        return true
    }

    private static func count(_ value: Data.SubSequence) -> Int? {
        guard !value.isEmpty else { return nil }
        if value.count == 1, value.first == UInt8(ascii: "-") { return 0 }
        guard value.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(String(decoding: value, as: UTF8.self))
    }
}
nonisolated struct DiffLimits: Sendable, Equatable {
    static let render = DiffLimits(maximumBytes: 2 * 1_024 * 1_024, maximumLines: 20_000)

    let maximumBytes: Int
    let maximumLines: Int
}

nonisolated enum DiffFileChange: String, Sendable, Equatable, Hashable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case conflicted
    case untracked
}

nonisolated enum DiffLineKind: Sendable, Equatable {
    case context
    case addition
    case deletion
}

nonisolated enum DiffTokenKind: Sendable, Equatable {
    case plain
    case keyword
    case string
    case comment
}

nonisolated struct DiffToken: Sendable, Equatable {
    let text: String
    let kind: DiffTokenKind
}

nonisolated struct DiffLine: Sendable, Equatable {
    let kind: DiffLineKind
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
    var hasTrailingNewline: Bool
    let tokens: [DiffToken]
}

nonisolated struct DiffRange: Sendable, Equatable {
    let start: Int
    let count: Int
}

nonisolated struct DiffHunk: Sendable, Equatable {
    let oldRange: DiffRange
    let newRange: DiffRange
    let heading: String?
    let lines: [DiffLine]
}

nonisolated enum DiffFileContent: Sendable, Equatable {
    case text([DiffHunk])
    case binary(byteCount: Int64?)
    case oversized(reason: DiffFileOversizedReason, byteCount: Int64?)
    case unavailable(DiffFileUnavailableReason)
    case conflicted(statusX: GitFileState, statusY: GitFileState)

    var oversizedReason: DiffFileOversizedReason? {
        guard case .oversized(let reason, _) = self else { return nil }
        return reason
    }
}

nonisolated struct DiffFile: Sendable, Equatable {
    let gitPath: GitPath
    let originalGitPath: GitPath?
    let change: DiffFileChange
    let content: DiffFileContent
    let oldMode: String?
    let newMode: String?

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

    init(
        path: String,
        originalPath: String?,
        change: DiffFileChange,
        content: DiffFileContent,
        oldMode: String? = nil,
        newMode: String? = nil
    ) {
        self.init(
            gitPath: GitPath(path),
            originalGitPath: originalPath.map(GitPath.init),
            change: change,
            content: content,
            oldMode: oldMode,
            newMode: newMode
        )
    }

    init(
        gitPath: GitPath,
        originalGitPath: GitPath?,
        change: DiffFileChange,
        content: DiffFileContent,
        oldMode: String? = nil,
        newMode: String? = nil
    ) {
        self.gitPath = gitPath
        self.originalGitPath = originalGitPath
        self.change = change
        self.content = content
        self.oldMode = oldMode
        self.newMode = newMode
    }
}

nonisolated struct DiffFileSummary: Sendable, Equatable, Hashable {
    let gitPath: GitPath
    let originalGitPath: GitPath?
    let change: DiffFileChange

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

    init(path: String, originalPath: String?, change: DiffFileChange) {
        self.init(
            gitPath: GitPath(path),
            originalGitPath: originalPath.map(GitPath.init),
            change: change
        )
    }

    init(gitPath: GitPath, originalGitPath: GitPath?, change: DiffFileChange) {
        self.gitPath = gitPath
        self.originalGitPath = originalGitPath
        self.change = change
    }
}

nonisolated enum DiffFallbackReason: Sendable, Equatable {
    case byteLimit(Int)
    case lineLimit(Int)
    case selectionLimit(maximumFiles: Int, maximumBytes: Int)
    case malformed
    case truncated
}

nonisolated struct DiffFallback: Sendable, Equatable {
    let reason: DiffFallbackReason
    let files: [DiffFileSummary]
}

nonisolated struct GitDiff: Sendable, Equatable {
    let files: [DiffFile]
    let fallback: DiffFallback?
    let sourceByteCount: Int
    let sourceLineCount: Int
    let rawPatch: DiffRawPatch

    init(
        files: [DiffFile],
        fallback: DiffFallback?,
        sourceByteCount: Int,
        sourceLineCount: Int,
        rawPatch: DiffRawPatch = .unavailable
    ) {
        self.files = files
        self.fallback = fallback
        self.sourceByteCount = sourceByteCount
        self.sourceLineCount = sourceLineCount
        self.rawPatch = rawPatch
    }

    static let empty = GitDiff(files: [], fallback: nil, sourceByteCount: 0, sourceLineCount: 0)

    var exactRawPatch: Data? {
        rawPatch.exactGitBytes
    }

    var text: String {
        files.map { file in
            var result = "diff --git \(file.displayOriginalPath ?? file.displayPath) \(file.displayPath)\n"
            switch file.content {
            case .binary:
                result += "Binary files differ\n"
            case .oversized:
                result += "File is too large to render\n"
            case .unavailable(let reason):
                result += "File unavailable: \(reason)\n"
            case .conflicted:
                result += "Unmerged conflict\n"
            case .text(let hunks):
                for hunk in hunks {
                    result += "@@ -\(hunk.oldRange.start),\(hunk.oldRange.count) +\(hunk.newRange.start),\(hunk.newRange.count) @@"
                    if let heading = hunk.heading { result += " \(heading)" }
                    result += "\n"
                    for line in hunk.lines {
                        let prefix = switch line.kind {
                        case .context: " "
                        case .addition: "+"
                        case .deletion: "-"
                        }
                        result += prefix + line.text + "\n"
                        if !line.hasTrailingNewline { result += "\\ No newline at end of file\n" }
                    }
                }
            }
            return result
        }.joined()
    }
}

nonisolated enum SelectedDiffState: Sendable, Equatable {
    case idle
    case loading
    case loaded(GitDiff)
    case failed(OperationFailure)
}

nonisolated extension FileChange {
    var hasStagedChange: Bool {
        kind == .unmerged || indexState != .unmodified
    }

    var hasUnstagedChange: Bool {
        kind == .unmerged || kind == .untracked || worktreeState != .unmodified
    }

    var diffFileChange: DiffFileChange {
        switch kind {
        case .renamed: .renamed
        case .copied: .copied
        case .unmerged: .conflicted
        case .untracked: .untracked
        case .ordinary, .ignored:
            if indexState == .added { .added } else if indexState == .deleted || worktreeState == .deleted { .deleted } else { .modified }
        }
    }

    var diffSummary: DiffFileSummary {
        DiffFileSummary(gitPath: gitPath, originalGitPath: originalGitPath, change: diffFileChange)
    }
}

nonisolated extension DiffFile {
    var diffSummary: DiffFileSummary {
        DiffFileSummary(gitPath: gitPath, originalGitPath: originalGitPath, change: change)
    }
}
