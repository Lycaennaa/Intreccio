import Foundation

nonisolated struct Commit: Sendable, Equatable {
    let objectID: String
    let parentIDs: [String]
    let authorName: String
    let authorEmail: String
    let authoredAt: Date
    let subject: String
    let body: String
    let subjectMetadata: CommitTextMetadata
    let bodyMetadata: CommitTextMetadata

    init(
        objectID: String,
        parentIDs: [String],
        authorName: String,
        authorEmail: String,
        authoredAt: Date,
        subject: String,
        body: String
    ) {
        self.init(
            objectID: objectID,
            parentIDs: parentIDs,
            authorName: authorName,
            authorEmail: authorEmail,
            authoredAt: authoredAt,
            subject: subject,
            body: body,
            subjectMetadata: .complete(subject),
            bodyMetadata: .complete(body)
        )
    }

    init(
        objectID: String,
        parentIDs: [String],
        authorName: String,
        authorEmail: String,
        authoredAt: Date,
        subject: String,
        body: String,
        subjectMetadata: CommitTextMetadata,
        bodyMetadata: CommitTextMetadata
    ) {
        self.objectID = objectID
        self.parentIDs = parentIDs
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredAt = authoredAt
        self.subject = subject
        self.body = body
        self.subjectMetadata = subjectMetadata
        self.bodyMetadata = bodyMetadata
    }
}

nonisolated struct CommitDetails: Sendable, Equatable {
    let commit: Commit
    let rawPatch: GitRawOutput
    let diff: GitDiff
    let comparisonBasis: String
    let metadata: CommitDetailsMetadata

    var patch: Data {
        rawPatch.bytes
    }

    init(
        commit: Commit,
        patch: Data,
        diff: GitDiff,
        comparisonBasis: String,
        patchCompleteness: GitOutputCompleteness = .complete,
        metadata: CommitDetailsMetadata? = nil
    ) {
        let summaries = diff.fallback?.files ?? diff.files.map(\.diffSummary)
        self.init(
            commit: commit,
            rawPatch: GitRawOutput(bytes: patch, completeness: patchCompleteness),
            diff: diff,
            comparisonBasis: comparisonBasis,
            metadata: metadata ?? CommitDetailsMetadata(
                subject: commit.subjectMetadata,
                body: commit.bodyMetadata,
                changedFiles: DiffSummaryMetadata(files: summaries)
            )
        )
    }

    init(
        commit: Commit,
        rawPatch: GitRawOutput,
        diff: GitDiff,
        comparisonBasis: String,
        metadata: CommitDetailsMetadata
    ) {
        self.commit = commit
        self.rawPatch = rawPatch
        self.diff = diff
        self.comparisonBasis = comparisonBasis
        self.metadata = metadata
    }
}

nonisolated enum HistoryScope: Int, CaseIterable, Sendable, Equatable {
    case mixed
    case local
    case upstream
    case unmergedUpstream

    var title: String {
        switch self {
        case .mixed: "Mixed"
        case .local: "Local"
        case .upstream: "Upstream"
        case .unmergedUpstream: "Unmerged Upstream"
        }
    }

    var emptyMessage: String {
        switch self {
        case .mixed: "No commits"
        case .local: "No local-only commits"
        case .upstream: "No upstream commits"
        case .unmergedUpstream: "No unmerged upstream commits"
        }
    }
}

nonisolated struct HistoryTips: Sendable, Equatable {
    let localObjectID: String?
    let upstreamObjectID: String?
}

nonisolated enum HistoryLoadPhase: Sendable, Equatable {
    case idle
    case loading
    case failed(OperationFailure)
}

nonisolated struct SelectedHistoryState: Sendable, Equatable {
    static let maximumLoadedCommits = 1_500

    var scope: HistoryScope = .mixed
    var commits: [Commit] = []
    var tips: HistoryTips?
    var phase: HistoryLoadPhase = .idle
    var reachedEnd = false
    var reachedLimit = false
    var metadataCompleteness: MetadataCompleteness = .complete

    var headObjectID: String? { tips?.localObjectID }

    func filteredCommits(searchText: String) -> [Commit] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commits }
        return commits.filter { commit in
            commit.subject.localizedCaseInsensitiveContains(query)
                || commit.authorName.localizedCaseInsensitiveContains(query)
                || commit.authorEmail.localizedCaseInsensitiveContains(query)
                || commit.objectID.localizedCaseInsensitiveContains(query)
        }
    }
}

nonisolated enum SelectedCommitState: Sendable, Equatable {
    case idle
    case loading(Commit)
    case loaded(CommitDetails)
    case failed(Commit, OperationFailure)

    var commit: Commit? {
        switch self {
        case .idle: nil
        case .loading(let commit), .failed(let commit, _): commit
        case .loaded(let details): details.commit
        }
    }
}

nonisolated enum CommitParserError: Error, Equatable, CustomStringConvertible {
    case malformedFieldCount(Int)
    case invalidDate(String)

    var description: String {
        switch self {
        case .malformedFieldCount(let count):
            "Malformed Git history field count: \(count)"
        case .invalidDate(let value):
            "Invalid Git author date: \(value)"
        }
    }
}

nonisolated enum CommitParser {
    static let format = "%H%x00"
    static let legacyFormat = "%x00GDC-RECORD%x00%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%b%x00GDC-END%x00"
    private static let recordStart = Data("\0GDC-RECORD\0".utf8)
    private static let recordEnd = Data("\0GDC-END\0".utf8)

    static func parse(_ data: Data) throws -> [Commit] {
        guard data.starts(with: recordStart) else {
            let result = CommitBatchParser.parse(data)
            guard result.completeness != .unavailable else {
                throw CommitParserError.malformedFieldCount(0)
            }
            return result.commits
        }
        let dateParser = ISO8601DateFormatter()
        var commits: [Commit] = []
        var searchStart = data.startIndex
        while let startRange = data.range(of: recordStart, in: searchStart..<data.endIndex) {
            let fieldsStart = startRange.upperBound
            guard let endRange = data.range(of: recordEnd, in: fieldsStart..<data.endIndex) else {
                throw CommitParserError.malformedFieldCount(0)
            }
            let fields = data[fieldsStart..<endRange.lowerBound]
                .split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 7 else {
                throw CommitParserError.malformedFieldCount(fields.count)
            }
            let dateText = String(decoding: fields[4], as: UTF8.self)
            guard let date = dateParser.date(from: dateText) else {
                throw CommitParserError.invalidDate(dateText)
            }
            commits.append(Commit(
                objectID: String(decoding: fields[0], as: UTF8.self),
                parentIDs: String(decoding: fields[1], as: UTF8.self)
                    .split(separator: " ")
                    .map(String.init),
                authorName: String(decoding: fields[2], as: UTF8.self),
                authorEmail: String(decoding: fields[3], as: UTF8.self),
                authoredAt: date,
                subject: String(decoding: fields[5], as: UTF8.self),
                body: String(decoding: fields[6], as: UTF8.self)
            ))
            searchStart = endRange.upperBound
        }
        if commits.isEmpty, !data.isEmpty {
            throw CommitParserError.malformedFieldCount(0)
        }
        return commits
    }
}
