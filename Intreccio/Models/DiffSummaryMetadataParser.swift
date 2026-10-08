import Foundation

nonisolated enum DiffSummaryMetadataParser {
    static func parse(
        _ data: Data,
        limits: HistoryMetadataLimits = .default,
        transportCompleteness: GitOutputCompleteness = .complete
    ) -> DiffSummaryMetadata {
        let boundedData: Data
        let wasByteLimited = data.count > limits.maximumSummaryBytes
        if wasByteLimited {
            boundedData = Data(data.prefix(max(0, limits.maximumSummaryBytes)))
        } else {
            boundedData = data
        }
        var fields = splitNULRecords(boundedData)
        if !boundedData.isEmpty, boundedData.last != 0 { fields.removeLast() }
        var summaries: [DiffFileSummary] = []
        var index = 0
        var totalCount = 0
        var hasPartialRecord = wasByteLimited || !transportCompleteness.isComplete || (boundedData.last != 0 && !boundedData.isEmpty)
        while index < fields.count {
            let status = String(decoding: fields[index], as: UTF8.self)
            index += 1
            guard let code = status.first else {
                hasPartialRecord = true
                break
            }
            let change: DiffFileChange = switch code {
            case "A": .added
            case "D": .deleted
            case "R": .renamed
            case "C": .copied
            case "U": .conflicted
            default: .modified
            }
            if code == "R" || code == "C" {
                guard index + 1 < fields.count else {
                    hasPartialRecord = true
                    break
                }
                let originalPath = GitPath(bytes: fields[index])
                let path = GitPath(bytes: fields[index + 1])
                if totalCount < max(0, limits.maximumSummaryFiles) {
                    summaries.append(DiffFileSummary(
                        gitPath: path,
                        originalGitPath: originalPath,
                        change: change
                    ))
                }
                totalCount += 1
                index += 2
            } else {
                guard index < fields.count else {
                    hasPartialRecord = true
                    break
                }
                let path = GitPath(bytes: fields[index])
                if totalCount < max(0, limits.maximumSummaryFiles) {
                    summaries.append(DiffFileSummary(
                        gitPath: path,
                        originalGitPath: nil,
                        change: change
                    ))
                }
                totalCount += 1
                index += 1
            }
        }

        if hasPartialRecord {
            return DiffSummaryMetadata(
                files: summaries,
                completeness: .truncated(omittedBytes: 0, omittedLines: nil),
                omittedFileCount: nil
            )
        }
        let omittedCount = max(0, totalCount - summaries.count)
        guard omittedCount > 0 else { return DiffSummaryMetadata(files: summaries) }
        return DiffSummaryMetadata(
            files: summaries,
            completeness: .truncated(omittedBytes: 0, omittedLines: nil),
            omittedFileCount: omittedCount
        )
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
}
