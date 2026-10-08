import Foundation

nonisolated enum UnifiedDiffParser {
    private struct FileBuilder {
        var path: GitPath
        var originalPath: GitPath?
        var change: DiffFileChange = .modified
        var hunks: [DiffHunk] = []
        var binary = false
        var oldMode: String?
        var newMode: String?
    }

    private struct HunkBuilder {
        let oldRange: DiffRange
        let newRange: DiffRange
        let heading: String?
        var lines: [DiffLine] = []
        var oldConsumed = 0
        var newConsumed = 0
        var nextOld: Int
        var nextNew: Int
    }

    static func parse(
        _ data: Data,
        limits: DiffLimits = .render,
        summaries: [DiffFileSummary] = [],
        rawCompleteness: GitOutputCompleteness = .complete
    ) -> GitDiff {
        let rawPatch: DiffRawPatch = .git(
            GitRawOutput(bytes: data, completeness: rawCompleteness)
        )
        guard data.count <= limits.maximumBytes else {
            return fallback(.byteLimit(limits.maximumBytes), summaries, data.count, 0, rawPatch: rawPatch)
        }
        guard !data.isEmpty else {
            return GitDiff(files: [], fallback: nil, sourceByteCount: 0, sourceLineCount: 0, rawPatch: rawPatch)
        }
        guard data.last == 0x0A else {
            return fallback(.truncated, summaries, data.count, 0, rawPatch: rawPatch)
        }

        let physicalLines = data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        guard physicalLines <= limits.maximumLines else {
            return fallback(.lineLimit(limits.maximumLines), summaries, data.count, physicalLines, rawPatch: rawPatch)
        }

        let lines = splitPhysicalLines(data)
        var files: [DiffFile] = []
        var file: FileBuilder?
        var hunk: HunkBuilder?
        var malformed = false

        func finishHunk() -> Bool {
            guard let value = hunk else { return true }
            guard value.oldConsumed == value.oldRange.count,
                  value.newConsumed == value.newRange.count,
                  file != nil else { return false }
            file!.hunks.append(DiffHunk(
                oldRange: value.oldRange,
                newRange: value.newRange,
                heading: value.heading,
                lines: value.lines
            ))
            hunk = nil
            return true
        }

        func finishFile() -> Bool {
            guard finishHunk() else { return false }
            guard let value = file else { return true }
            files.append(DiffFile(
                gitPath: value.path,
                originalGitPath: value.originalPath,
                change: value.change,
                content: value.binary ? .binary(byteCount: nil) : .text(value.hunks),
                oldMode: value.oldMode,
                newMode: value.newMode
            ))
            file = nil
            return true
        }

        for rawLine in lines.dropLast() {
            let line = String(decoding: rawLine, as: UTF8.self)
            if line.hasPrefix("diff --git ") {
                guard finishFile(), let paths = parseDiffHeader(Data(rawLine.dropFirst(11))) else {
                    malformed = true
                    break
                }
                file = FileBuilder(path: paths.new, originalPath: paths.old == paths.new ? nil : paths.old)
                continue
            }
            guard file != nil else {
                malformed = true
                break
            }

            if line.hasPrefix("@@ ") {
                guard finishHunk(), let parsed = parseHunkHeader(line) else {
                    malformed = true
                    break
                }
                hunk = HunkBuilder(
                    oldRange: parsed.old,
                    newRange: parsed.new,
                    heading: parsed.heading,
                    nextOld: parsed.old.start,
                    nextNew: parsed.new.start
                )
                continue
            }

            if hunk != nil {
                if line == "\\ No newline at end of file" {
                    guard !hunk!.lines.isEmpty, hunk!.lines.last!.hasTrailingNewline else {
                        malformed = true
                        break
                    }
                    hunk!.lines[hunk!.lines.count - 1].hasTrailingNewline = false
                    continue
                }
                guard let prefix = line.first, prefix == " " || prefix == "+" || prefix == "-" else {
                    malformed = true
                    break
                }
                let text = String(line.dropFirst())
                let kind: DiffLineKind
                let oldNumber: Int?
                let newNumber: Int?
                switch prefix {
                case " ":
                    kind = .context
                    oldNumber = hunk!.nextOld
                    newNumber = hunk!.nextNew
                    hunk!.nextOld += 1
                    hunk!.nextNew += 1
                    hunk!.oldConsumed += 1
                    hunk!.newConsumed += 1
                case "+":
                    kind = .addition
                    oldNumber = nil
                    newNumber = hunk!.nextNew
                    hunk!.nextNew += 1
                    hunk!.newConsumed += 1
                default:
                    kind = .deletion
                    oldNumber = hunk!.nextOld
                    newNumber = nil
                    hunk!.nextOld += 1
                    hunk!.oldConsumed += 1
                }
                hunk!.lines.append(DiffLine(
                    kind: kind,
                    text: text,
                    oldLineNumber: oldNumber,
                    newLineNumber: newNumber,
                    hasTrailingNewline: true,
                    tokens: DiffSyntaxTokenizer.tokenize(text)
                ))
                continue
            }

            if line.hasPrefix("--- ") {
                file!.originalPath = parsePatchPath(Data(rawLine.dropFirst(4)), sidePrefix: "a/")
            } else if line.hasPrefix("+++ ") {
                guard let path = parsePatchPath(Data(rawLine.dropFirst(4)), sidePrefix: "b/") else {
                    file!.change = .deleted
                    continue
                }
                file!.path = path
                if file!.originalPath == nil { file!.change = .added }
            } else if line.hasPrefix("rename from ") {
                file!.originalPath = decodeGitPath(Data(rawLine.dropFirst(12)))
                file!.change = .renamed
            } else if line.hasPrefix("rename to ") {
                file!.path = decodeGitPath(Data(rawLine.dropFirst(10)))
                file!.change = .renamed
            } else if line.hasPrefix("copy from ") {
                file!.originalPath = decodeGitPath(Data(rawLine.dropFirst(10)))
                file!.change = .copied
            } else if line.hasPrefix("copy to ") {
                file!.path = decodeGitPath(Data(rawLine.dropFirst(8)))
                file!.change = .copied
            } else if line.hasPrefix("new file mode ") {
                file!.change = .added
                file!.newMode = String(line.dropFirst(14))
            } else if line.hasPrefix("deleted file mode ") {
                file!.change = .deleted
                file!.oldMode = String(line.dropFirst(18))
            } else if line.hasPrefix("old mode ") {
                file!.oldMode = String(line.dropFirst(9))
            } else if line.hasPrefix("new mode ") {
                file!.newMode = String(line.dropFirst(9))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                file!.binary = true
            }
        }

        guard !malformed, finishFile() else {
            return fallback(
                .malformed,
                summaries.isEmpty ? files.map(summary) : summaries,
                data.count,
                physicalLines,
                rawPatch: rawPatch
            )
        }
        guard rawCompleteness.isComplete else {
            let renderedSummaries = Set(files.map(\.diffSummary))
            let unrenderedSummaries = (summaries.isEmpty ? files.map(summary) : summaries)
                .filter { !renderedSummaries.contains($0) }
            return GitDiff(
                files: files,
                fallback: DiffFallback(reason: .truncated, files: unrenderedSummaries),
                sourceByteCount: data.count,
                sourceLineCount: physicalLines,
                rawPatch: rawPatch
            )
        }
        return GitDiff(
            files: files,
            fallback: nil,
            sourceByteCount: data.count,
            sourceLineCount: physicalLines,
            rawPatch: rawPatch
        )
    }

    private static func fallback(
        _ reason: DiffFallbackReason,
        _ files: [DiffFileSummary],
        _ bytes: Int,
        _ lines: Int,
        rawPatch: DiffRawPatch
    ) -> GitDiff {
        GitDiff(
            files: [],
            fallback: DiffFallback(reason: reason, files: files),
            sourceByteCount: bytes,
            sourceLineCount: lines,
            rawPatch: rawPatch
        )
    }

    private static func summary(_ file: DiffFile) -> DiffFileSummary {
        DiffFileSummary(
            gitPath: file.gitPath,
            originalGitPath: file.originalGitPath,
            change: file.change
        )
    }

    private static func parseHunkHeader(_ line: String) -> (old: DiffRange, new: DiffRange, heading: String?)? {
        guard let close = line.range(of: " @@", options: [], range: line.index(line.startIndex, offsetBy: 3)..<line.endIndex) else {
            return nil
        }
        let ranges = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound].split(separator: " ")
        guard ranges.count == 2,
              let old = parseRange(String(ranges[0]), prefix: "-"),
              let new = parseRange(String(ranges[1]), prefix: "+") else { return nil }
        let headingStart = close.upperBound
        let heading = headingStart < line.endIndex ? String(line[headingStart...]).trimmingCharacters(in: .whitespaces) : nil
        return (old, new, heading?.isEmpty == true ? nil : heading)
    }

    private static func parseRange(_ value: String, prefix: Character) -> DiffRange? {
        guard value.first == prefix else { return nil }
        let parts = value.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(parts[0]), start >= 0 else { return nil }
        let count = parts.count == 1 ? 1 : Int(parts[1])
        guard parts.count <= 2, let count, count >= 0 else { return nil }
        return DiffRange(start: start, count: count)
    }

    private static func parseDiffHeader(_ value: Data) -> (old: GitPath, new: GitPath)? {
        let fields = parseGitPathTokens(value)
        guard fields.count == 2 else { return nil }
        return (
            stripSidePrefix(decodeGitPath(fields[0]), "a/"),
            stripSidePrefix(decodeGitPath(fields[1]), "b/")
        )
    }

    private static func parsePatchPath(_ value: Data, sidePrefix: String) -> GitPath? {
        guard value != Data("/dev/null".utf8) else { return nil }
        return stripSidePrefix(decodeGitPath(value), sidePrefix)
    }

    private static func parseGitPathTokens(_ value: Data) -> [Data] {
        var fields: [Data] = []
        var index = 0
        while index < value.count {
            while index < value.count, value[index] == 0x20 { index += 1 }
            guard index < value.count else { break }
            let start = index
            if value[index] == 0x22 {
                index += 1
                var escaped = false
                var closed = false
                while index < value.count {
                    let byte = value[index]
                    if !escaped, byte == 0x22 {
                        index += 1
                        closed = true
                        break
                    }
                    if !escaped, byte == 0x5C {
                        escaped = true
                    } else {
                        escaped = false
                    }
                    index += 1
                }
                guard closed else { return [] }
            } else {
                while index < value.count, value[index] != 0x20 { index += 1 }
            }
            fields.append(Data(value[start..<index]))
        }
        return fields
    }

    private static func stripSidePrefix(_ path: GitPath, _ prefix: String) -> GitPath {
        let prefixBytes = Data(prefix.utf8)
        guard path.bytes.starts(with: prefixBytes) else { return path }
        return GitPath(bytes: Data(path.bytes.dropFirst(prefixBytes.count)))
    }

    private static func decodeGitPath(_ value: Data) -> GitPath {
        guard value.first == 0x22, value.last == 0x22 else {
            return GitPath(bytes: value)
        }
        let content = Data(value.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var index = 0
        while index < content.count {
            guard content[index] == 0x5C else {
                bytes.append(content[index])
                index += 1
                continue
            }
            index += 1
            guard index < content.count else {
                bytes.append(0x5C)
                break
            }
            let escaped = content[index]
            switch escaped {
            case 0x61: bytes.append(0x07)
            case 0x62: bytes.append(0x08)
            case 0x74: bytes.append(0x09)
            case 0x6E: bytes.append(0x0A)
            case 0x76: bytes.append(0x0B)
            case 0x66: bytes.append(0x0C)
            case 0x72: bytes.append(0x0D)
            case 0x5C: bytes.append(0x5C)
            case 0x22: bytes.append(0x22)
            case 0x30...0x37:
                var octal = UInt32(escaped - 0x30)
                index += 1
                for _ in 0..<2 where index < content.count && (0x30...0x37).contains(content[index]) {
                    octal = octal * 8 + UInt32(content[index] - 0x30)
                    index += 1
                }
                bytes.append(UInt8(octal))
                continue
            default:
                bytes.append(0x5C)
                bytes.append(escaped)
            }
            index += 1
        }
        return GitPath(bytes: Data(bytes))
    }

    private static func splitPhysicalLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = 0
        for index in 0..<data.count where data[index] == 0x0A {
            lines.append(Data(data[start..<index]))
            start = index + 1
        }
        lines.append(Data(data[start..<data.count]))
        return lines
    }
}

nonisolated enum DiffSyntaxTokenizer {
    private static let keywords: Set<String> = [
        "actor", "case", "class", "else", "enum", "extension", "false", "func", "guard",
        "if", "import", "let", "nil", "private", "protocol", "return", "static", "struct",
        "switch", "true", "var", "while"
    ]

    static func tokenize(_ text: String) -> [DiffToken] {
        return tokenizeCode(text)
    }

    private static func tokenizeCode(_ text: String) -> [DiffToken] {
        var tokens: [DiffToken] = []
        var buffer = ""
        var inString = false
        var escaped = false
        var index = text.startIndex

        func flush(_ kind: DiffTokenKind = .plain) {
            guard !buffer.isEmpty else { return }
            if kind == .plain {
                var word = ""
                var plain = ""
                func flushPlain() {
                    guard !plain.isEmpty else { return }
                    tokens.append(DiffToken(text: plain, kind: .plain))
                    plain = ""
                }
                for character in buffer {
                    if character.isLetter || character == "_" {
                        flushPlain()
                        word.append(character)
                    } else {
                        if !word.isEmpty {
                            tokens.append(DiffToken(text: word, kind: keywords.contains(word) ? .keyword : .plain))
                            word = ""
                        }
                        plain.append(character)
                    }
                }
                flushPlain()
                if !word.isEmpty { tokens.append(DiffToken(text: word, kind: keywords.contains(word) ? .keyword : .plain)) }
            } else {
                tokens.append(DiffToken(text: buffer, kind: kind))
            }
            buffer = ""
        }

        while index < text.endIndex {
            let character = text[index]
            if inString {
                buffer.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { flush(.string); inString = false }
            } else if character == "/",
                      text.index(after: index) < text.endIndex,
                      text[text.index(after: index)] == "/" {
                flush()
                tokens.append(DiffToken(text: String(text[index...]), kind: .comment))
                return tokens
            } else if character == "\"" {
                flush()
                buffer.append(character)
                inString = true
            } else {
                buffer.append(character)
            }
            index = text.index(after: index)
        }
        flush(inString ? .string : .plain)
        return tokens
    }
}
