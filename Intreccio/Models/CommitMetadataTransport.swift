import Foundation

nonisolated struct CommitBatchParseResult: Sendable, Equatable {
    let commits: [Commit]
    let completeness: MetadataCompleteness
    let omittedCommitCount: Int?
    let unavailableCommitCount: Int
}

nonisolated struct HistoryMetadataPage: Sendable, Equatable {
    let commits: [Commit]
    let completeness: MetadataCompleteness
    let omittedCommitCount: Int?
    let unavailableCommitCount: Int

    static let empty = HistoryMetadataPage(
        commits: [],
        completeness: .complete,
        omittedCommitCount: 0,
        unavailableCommitCount: 0
    )
}
nonisolated enum CommitBatchParser {
    static func parse(
        _ data: Data,
        limits: HistoryMetadataLimits = .default,
        transportCompleteness: GitOutputCompleteness = .complete
    ) -> CommitBatchParseResult {
        var commits: [Commit] = []
        var unavailableCommitCount = 0
        var cursor = 0
        var completeness: MetadataCompleteness = transportCompleteness.isComplete ? .complete : .truncated(
            omittedBytes: 0,
            omittedLines: nil
        )

        while cursor < data.count {
            guard let headerEnd = data[cursor..<data.count].firstIndex(of: 0x0A) else {
                completeness = .truncated(omittedBytes: 0, omittedLines: nil)
                break
            }
            let header = Data(data[cursor..<headerEnd])
            cursor = headerEnd + 1
            let fields = splitFields(header)
            guard fields.count >= 2 else {
                completeness = .unavailable
                break
            }
            let objectID = String(decoding: fields[0], as: UTF8.self)
            let type = String(decoding: fields[1], as: UTF8.self)
            if type == "missing" {
                unavailableCommitCount += 1
                completeness = .unavailable
                continue
            }
            guard fields.count >= 3,
                  let objectSize = Int(String(decoding: fields[2], as: UTF8.self)) else {
                completeness = .unavailable
                break
            }
            guard type == "commit" else {
                let available = min(objectSize, data.count - cursor)
                cursor += available
                if available < objectSize {
                    completeness = .truncated(omittedBytes: objectSize - available, omittedLines: nil)
                    break
                }
                if cursor < data.count, data[cursor] == 0x0A { cursor += 1 }
                continue
            }

            let available = min(objectSize, data.count - cursor)
            let object = Data(data[cursor..<(cursor + available)])
            cursor += available
            let objectIsComplete = available == objectSize
            if objectIsComplete, cursor < data.count, data[cursor] == 0x0A {
                cursor += 1
            } else if objectIsComplete {
                completeness = .truncated(omittedBytes: 0, omittedLines: nil)
            }

            if let commit = parseCommitObject(
                object,
                objectID: objectID,
                objectSize: objectSize,
                limits: limits,
                objectIsComplete: objectIsComplete
            ) {
                commits.append(commit)
            } else {
                completeness = .unavailable
            }

            guard objectIsComplete else {
                completeness = .truncated(omittedBytes: objectSize - available, omittedLines: nil)
                break
            }
        }

        return CommitBatchParseResult(
            commits: commits,
            completeness: completeness,
            omittedCommitCount: completeness.isComplete ? 0 : nil,
            unavailableCommitCount: unavailableCommitCount
        )
    }

    private static func parseCommitObject(
        _ object: Data,
        objectID: String,
        objectSize: Int,
        limits: HistoryMetadataLimits,
        objectIsComplete: Bool
    ) -> Commit? {
        guard !objectID.isEmpty else { return nil }
        let separator = object.range(of: Data([0x0A, 0x0A]))
        let headerEnd = separator?.lowerBound ?? object.endIndex
        let header = Data(object[..<headerEnd])
        let message = separator.map { Data(object[$0.upperBound...]) } ?? Data()
        let headerLines = splitLines(header)

        var parentIDs: [String] = []
        var authorName = ""
        var authorEmail = ""
        var authoredAt = Date(timeIntervalSince1970: 0)
        var hasAuthor = false
        for line in headerLines {
            if line.starts(with: Data("parent ".utf8)) {
                parentIDs.append(String(decoding: line.dropFirst(7), as: UTF8.self))
            } else if line.starts(with: Data("author ".utf8)),
                      let author = parseAuthor(Data(line.dropFirst(7))) {
                authorName = author.name
                authorEmail = author.email
                authoredAt = author.date
                hasAuthor = true
            }
        }
        guard hasAuthor || objectIsComplete else { return nil }

        guard separator != nil || !objectIsComplete else { return nil }
        let subjectBytes: Data
        let bodyBytes: Data
        let bodyStartInMessage: Int?
        if let newline = message.firstIndex(of: 0x0A) {
            subjectBytes = Data(message[..<newline])
            var bodyStart = newline + 1
            if bodyStart < message.count, message[bodyStart] == 0x0A { bodyStart += 1 }
            bodyStartInMessage = bodyStart
            bodyBytes = Data(message[bodyStart...])
        } else {
            subjectBytes = message
            bodyStartInMessage = nil
            bodyBytes = Data()
        }
        let subjectMetadata: CommitTextMetadata
        if !objectIsComplete, separator == nil {
            subjectMetadata = CommitTextMetadata(
                bytes: Data(),
                totalByteCount: 0,
                totalLineCount: nil,
                completeness: .unavailable
            )
        } else {
            subjectMetadata = boundedText(subjectBytes, limits: limits)
        }
        let bodyMetadata = boundedText(bodyBytes, limits: limits)
        let bodyOffset = separator.map { $0.upperBound + (bodyStartInMessage ?? message.count) }
        let bodyTotalByteCount = bodyOffset.map { max(0, objectSize - $0) } ?? 0
        let omittedBodyBytes = bodyOffset.map { _ in max(0, bodyTotalByteCount - bodyBytes.count) }
            ?? max(0, objectSize - object.count)
        let metadata: CommitTextMetadata
        if objectIsComplete {
            metadata = bodyMetadata
        } else {
            metadata = CommitTextMetadata(
                bytes: bodyMetadata.bytes,
                totalByteCount: bodyTotalByteCount,
                totalLineCount: nil,
                completeness: .truncated(
                    omittedBytes: omittedBodyBytes,
                    omittedLines: nil
                )
            )
        }
        let body = metadata.text
        return Commit(
            objectID: objectID,
            parentIDs: parentIDs,
            authorName: authorName,
            authorEmail: authorEmail,
            authoredAt: authoredAt,
            subject: subjectMetadata.text,
            body: body,
            subjectMetadata: subjectMetadata,
            bodyMetadata: metadata
        )
    }

    private static func parseAuthor(_ value: Data) -> (name: String, email: String, date: Date)? {
        guard let open = value.lastIndex(of: 0x3C),
              let close = value.lastIndex(of: 0x3E),
              open > value.startIndex,
              open < close else { return nil }
        let nameEnd = value.index(before: open)
        let name = Data(value[..<nameEnd])
        let email = Data(value[(open + 1)..<close])
        let suffix = Data(value[(close + 1)...])
        let dateFields = String(decoding: suffix, as: UTF8.self).split(separator: " ")
        guard let timestamp = dateFields.first.flatMap({ Int($0) }) else { return nil }
        return (
            String(decoding: name, as: UTF8.self),
            String(decoding: email, as: UTF8.self),
            Date(timeIntervalSince1970: TimeInterval(timestamp))
        )
    }

    private static func boundedText(_ data: Data, limits: HistoryMetadataLimits) -> CommitTextMetadata {
        let totalLines = countLines(data)
        var end = min(data.count, max(0, limits.maximumBodyBytes))
        if limits.maximumBodyLines == 0 {
            end = 0
        } else if totalLines > limits.maximumBodyLines {
            var lines = 0
            end = 0
            for index in 0..<data.count {
                if data[index] == 0x0A {
                    lines += 1
                    if lines == limits.maximumBodyLines {
                        end = index + 1
                        break
                    }
                }
            }
            end = min(end, max(0, limits.maximumBodyBytes))
        }
        let prefix = Data(data[..<end])
        guard end < data.count else {
            return CommitTextMetadata(
                bytes: prefix,
                totalByteCount: data.count,
                totalLineCount: totalLines,
                completeness: .complete
            )
        }
        return CommitTextMetadata(
            bytes: prefix,
            totalByteCount: data.count,
            totalLineCount: totalLines,
            completeness: .truncated(
                omittedBytes: data.count - end,
                omittedLines: max(0, totalLines - countLines(prefix))
            )
        )
    }

    private static func countLines(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    private static func splitFields(_ data: Data) -> [Data] {
        var fields: [Data] = []
        var start = 0
        for index in 0..<data.count where data[index] == 0x20 {
            fields.append(Data(data[start..<index]))
            start = index + 1
        }
        fields.append(Data(data[start..<data.count]))
        return fields
    }

    private static func splitLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = 0
        for index in 0..<data.count where data[index] == 0x0A {
            lines.append(Data(data[start..<index]))
            start = index + 1
        }
        if start < data.count { lines.append(Data(data[start..<data.count])) }
        return lines
    }
}
