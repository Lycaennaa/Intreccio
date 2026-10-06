import Foundation

nonisolated enum MetadataCompleteness: Sendable, Equatable {
    case complete
    case truncated(omittedBytes: Int, omittedLines: Int?)
    case unavailable

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}

nonisolated struct CommitTextMetadata: Sendable, Equatable {
    let bytes: Data
    let totalByteCount: Int
    let totalLineCount: Int?
    let completeness: MetadataCompleteness
    let omittedByteCount: Int

    var text: String {
        String(decoding: bytes, as: UTF8.self)
    }

    init(
        bytes: Data,
        totalByteCount: Int? = nil,
        totalLineCount: Int? = nil,
        completeness: MetadataCompleteness = .complete
    ) {
        let totalByteCount = totalByteCount ?? bytes.count
        self.bytes = bytes
        self.totalByteCount = totalByteCount
        self.totalLineCount = totalLineCount
        self.completeness = completeness
        switch completeness {
        case .truncated(let omittedBytes, _):
            self.omittedByteCount = omittedBytes
        case .complete, .unavailable:
            self.omittedByteCount = max(0, totalByteCount - bytes.count)
        }
    }

    static func complete(_ text: String) -> CommitTextMetadata {
        let bytes = Data(text.utf8)
        return CommitTextMetadata(
            bytes: bytes,
            totalByteCount: bytes.count,
            totalLineCount: lineCount(in: bytes),
            completeness: .complete
        )
    }

    private static func lineCount(in bytes: Data) -> Int {
        guard !bytes.isEmpty else { return 0 }
        let newlineCount = bytes.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        return bytes.last == 0x0A ? newlineCount : newlineCount + 1
    }
}

nonisolated struct DiffSummaryMetadata: Sendable, Equatable {
    let files: [DiffFileSummary]
    let completeness: MetadataCompleteness
    let omittedFileCount: Int?

    init(
        files: [DiffFileSummary],
        completeness: MetadataCompleteness = .complete,
        omittedFileCount: Int? = 0
    ) {
        self.files = files
        self.completeness = completeness
        self.omittedFileCount = omittedFileCount
    }

    static let empty = DiffSummaryMetadata(files: [])
}

nonisolated struct CommitDetailsMetadata: Sendable, Equatable {
    let subject: CommitTextMetadata
    let body: CommitTextMetadata
    let changedFiles: DiffSummaryMetadata

    init(
        subject: CommitTextMetadata = .complete(""),
        body: CommitTextMetadata,
        changedFiles: DiffSummaryMetadata
    ) {
        self.subject = subject
        self.body = body
        self.changedFiles = changedFiles
    }
    var completeness: MetadataCompleteness {
        let completeness = [subject.completeness, body.completeness, changedFiles.completeness]
        if completeness.contains(where: {
            if case .unavailable = $0 { return true }
            return false
        }) {
            return .unavailable
        }
        guard completeness.allSatisfy(\.isComplete) else {
            var omittedBytes = 0
            var omittedLines: Int? = 0
            for value in completeness {
                guard case .truncated(let bytes, let lines) = value else { continue }
                omittedBytes += bytes
                if let lines {
                    omittedLines = (omittedLines ?? 0) + lines
                } else {
                    omittedLines = nil
                }
            }
            return .truncated(omittedBytes: omittedBytes, omittedLines: omittedLines)
        }
        return .complete
    }
}

nonisolated struct HistoryMetadataLimits: Sendable, Equatable {
    let maximumBodyBytes: Int
    let maximumBodyLines: Int
    let maximumTransportBytes: Int
    let maximumSummaryFiles: Int
    let maximumSummaryBytes: Int

    init(
        maximumBodyBytes: Int,
        maximumBodyLines: Int,
        maximumTransportBytes: Int,
        maximumSummaryFiles: Int = 4_096,
        maximumSummaryBytes: Int = 512 * 1_024
    ) {
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumBodyLines = maximumBodyLines
        self.maximumTransportBytes = maximumTransportBytes
        self.maximumSummaryFiles = maximumSummaryFiles
        self.maximumSummaryBytes = maximumSummaryBytes
    }

    static let `default` = HistoryMetadataLimits(
        maximumBodyBytes: 256 * 1_024,
        maximumBodyLines: 4_096,
        maximumTransportBytes: 2 * 1_024 * 1_024
    )
}