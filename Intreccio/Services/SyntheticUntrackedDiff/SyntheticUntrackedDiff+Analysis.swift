import Darwin
import CryptoKit
import Foundation
nonisolated struct FileContentFingerprint: Sendable, Equatable {
    let digest: Data?
    let byteCount: Int64
}
nonisolated struct FileIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modificationSeconds: time_t
    let modificationNanoseconds: Int
    let changeSeconds: time_t
    let changeNanoseconds: Int

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        size = status.st_size
        modificationSeconds = status.st_mtimespec.tv_sec
        modificationNanoseconds = status.st_mtimespec.tv_nsec
        changeSeconds = status.st_ctimespec.tv_sec
        changeNanoseconds = status.st_ctimespec.tv_nsec
    }

    func refersToSameFile(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}
nonisolated enum UntrackedFileAnalysisKind: Sendable, Equatable {
    case text
    case binary
    case oversized
}
nonisolated struct UntrackedFileAnalysis: Sendable, Equatable {
    let fingerprint: FileContentFingerprint
    let identity: FileIdentity
    let lineStats: DiffLineStats?
    let hasFinalNewline: Bool
    let kind: UntrackedFileAnalysisKind
    let isComplete: Bool
    let content: Data?
    let oversizedReason: DiffFileOversizedReason?

    init(
        fingerprint: FileContentFingerprint,
        identity: FileIdentity,
        lineStats: DiffLineStats?,
        hasFinalNewline: Bool,
        kind: UntrackedFileAnalysisKind,
        isComplete: Bool,
        content: Data?,
        oversizedReason: DiffFileOversizedReason? = nil
    ) {
        self.fingerprint = fingerprint
        self.identity = identity
        self.lineStats = lineStats
        self.hasFinalNewline = hasFinalNewline
        self.kind = kind
        self.isComplete = isComplete
        self.content = content
        self.oversizedReason = oversizedReason
    }

    func withoutContent() -> UntrackedFileAnalysis {
        UntrackedFileAnalysis(
            fingerprint: fingerprint,
            identity: identity,
            lineStats: lineStats,
            hasFinalNewline: hasFinalNewline,
            kind: kind,
            isComplete: isComplete,
            content: nil,
            oversizedReason: oversizedReason
        )
    }
}
nonisolated struct UntrackedDiffAnalysisCache: Sendable {
    private struct Entry: Sendable {
        let analysis: UntrackedFileAnalysis
        let byteCost: Int64
        let orderToken: UInt64
    }

    private struct QueueEntry: Sendable {
        let path: GitPath
        let orderToken: UInt64
    }

    let maximumBytes: Int64
    private var values: [GitPath: Entry] = [:]
    private var order: [QueueEntry] = []
    private var orderHead = 0
    private var nextOrderToken: UInt64 = 0
    private(set) var storedByteCount: Int64 = 0

    init(maximumBytes: Int64 = Int64(DiffLimits.render.maximumBytes)) {
        self.maximumBytes = max(0, maximumBytes)
    }

    var count: Int { values.count }

    func value(for path: String) -> UntrackedFileAnalysis? {
        value(for: GitPath(path))
    }

    func value(for path: GitPath) -> UntrackedFileAnalysis? {
        values[path]?.analysis
    }

    mutating func store(_ analysis: UntrackedFileAnalysis, for path: String) {
        store(analysis, for: GitPath(path))
    }

    mutating func store(_ analysis: UntrackedFileAnalysis, for path: GitPath) {
        remove(path)
        compactQueueIfNeeded()
        let withContentCost = cost(of: analysis, path: path)
        let candidate = withContentCost <= maximumBytes ? analysis : analysis.withoutContent()
        let byteCost = cost(of: candidate, path: path)
        guard byteCost <= maximumBytes else {
            compactQueueIfNeeded()
            return
        }
        while storedByteCount + byteCost > maximumBytes {
            guard removeOldest() else { return }
        }
        let orderToken = nextOrderToken
        nextOrderToken &+= 1
        values[path] = Entry(analysis: candidate, byteCost: byteCost, orderToken: orderToken)
        order.append(QueueEntry(path: path, orderToken: orderToken))
        storedByteCount += byteCost
        compactQueueIfNeeded()
    }

    mutating func invalidate(path: String) {
        invalidate(path: GitPath(path))
    }

    mutating func invalidate(path: GitPath) {
        remove(path)
        compactQueueIfNeeded()
    }

    mutating func invalidateAll() {
        values.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        orderHead = 0
        nextOrderToken = 0
        storedByteCount = 0
    }

    private mutating func remove(_ path: GitPath) {
        guard let entry = values.removeValue(forKey: path) else { return }
        storedByteCount -= entry.byteCost
    }

    private mutating func removeOldest() -> Bool {
        while orderHead < order.count {
            let queued = order[orderHead]
            orderHead += 1
            guard let entry = values[queued.path], entry.orderToken == queued.orderToken else { continue }
            values.removeValue(forKey: queued.path)
            storedByteCount -= entry.byteCost
            return true
        }
        return false
    }

    private mutating func compactQueueIfNeeded() {
        guard !order.isEmpty else {
            orderHead = 0
            return
        }
        let staleCount = order.count - values.count
        let consumedHalf = orderHead > 0 && orderHead >= order.count - orderHead
        guard staleCount > max(64, values.count) || consumedHalf else { return }

        var compacted: [QueueEntry] = []
        compacted.reserveCapacity(values.count)
        for queued in order.dropFirst(orderHead) {
            guard let entry = values[queued.path], entry.orderToken == queued.orderToken else { continue }
            compacted.append(queued)
        }
        order = compacted
        orderHead = 0
    }

    private func cost(of analysis: UntrackedFileAnalysis, path: GitPath) -> Int64 {
        Int64(path.byteCount) + 128 + Int64(analysis.content?.count ?? 0)
    }
}
nonisolated extension SyntheticUntrackedDiff {
    static func analyze(
        repository: URL,
        relativePath: String,
        maximumBytes: Int,
        maximumLines: Int,
        verifyContent: Bool = true
    ) throws -> UntrackedFileAnalysis {
        try analyze(
            repository: repository,
            relativePath: GitPath(relativePath),
            maximumBytes: maximumBytes,
            maximumLines: maximumLines,
            verifyContent: verifyContent
        )
    }

    static func analyze(
        repository: URL,
        relativePath: GitPath,
        maximumBytes: Int,
        maximumLines: Int,
        verifyContent: Bool = true
    ) throws -> UntrackedFileAnalysis {
        let result = try readRegularFile(
            repository: repository,
            relativePath: relativePath,
            maximumBytes: maximumBytes,
            verifyContent: verifyContent
        )
        let hasFinalNewline = result.data.last == 0x0A
        guard result.data.count <= maximumBytes else {
            return UntrackedFileAnalysis(
                fingerprint: result.fingerprint,
                identity: result.identity,
                lineStats: nil,
                hasFinalNewline: false,
                kind: .oversized,
                isComplete: false,
                content: nil,
                oversizedReason: .byteLimit(maximumBytes: maximumBytes)
            )
        }

        var lineCount = 0
        var isBinary = false
        for (index, byte) in result.data.enumerated() {
            if index.isMultiple(of: 64 * 1_024) { try Task.checkCancellation() }
            if byte == 0 { isBinary = true }
            if byte == 0x0A { lineCount += 1 }
        }
        if !hasFinalNewline, !result.data.isEmpty { lineCount += 1 }
        let lineStats = isBinary ? nil : DiffLineStats(additions: lineCount, deletions: 0)
        let patchLineCount = 4 + lineCount + (hasFinalNewline ? 0 : 1)
        let kind: UntrackedFileAnalysisKind
        let oversizedReason: DiffFileOversizedReason?
        if isBinary {
            kind = .binary
            oversizedReason = nil
        } else if patchLineCount > maximumLines {
            kind = .oversized
            oversizedReason = .lineLimit(maximumLines: maximumLines)
        } else {
            kind = .text
            oversizedReason = nil
        }
        return UntrackedFileAnalysis(
            fingerprint: result.fingerprint,
            identity: result.identity,
            lineStats: lineStats,
            hasFinalNewline: hasFinalNewline,
            kind: kind,
            isComplete: true,
            content: kind == .text ? result.data : nil,
            oversizedReason: oversizedReason
        )
    }
    static func validateCachedAnalysis(
        repository: URL,
        relativePath: String,
        analysis: UntrackedFileAnalysis,
        verifyContent: Bool
    ) throws -> Bool {
        try validateCachedAnalysis(
            repository: repository,
            relativePath: GitPath(relativePath),
            analysis: analysis,
            verifyContent: verifyContent
        )
    }

    static func validateCachedAnalysis(
        repository: URL,
        relativePath: GitPath,
        analysis: UntrackedFileAnalysis,
        verifyContent: Bool
    ) throws -> Bool {
        try Task.checkCancellation()
        return try withRegularFile(repository: repository, relativePath: relativePath) { parent, descriptor, name, currentIdentity, _ in
            guard currentIdentity == analysis.identity else { return false }

            if verifyContent, let expectedDigest = analysis.fingerprint.digest {
                let result = try readFile(
                    descriptor: descriptor,
                    relativePath: relativePath,
                    maximumBytes: analysis.fingerprint.byteCount,
                    collectData: false
                )
                guard !result.exceededLimit,
                      result.byteCount == analysis.fingerprint.byteCount,
                      result.digest == expectedDigest else { return false }
            }

            switch validateRegularFile(
                parent: parent,
                descriptor: descriptor,
                name: name,
                expectedIdentity: analysis.identity
            ) {
            case .unchanged:
                return true
            case .descriptorInspectionFailed(let code):
                throw SyntheticUntrackedDiffError.readFailed(relativePath.displayString, code)
            case .changed:
                return false
            }
        }
    }
    static func contentFingerprint(
        repository: URL,
        relativePath: String,
        maximumBytes: Int64? = nil
    ) throws -> FileContentFingerprint? {
        try contentFingerprint(
            repository: repository,
            relativePath: GitPath(relativePath),
            maximumBytes: maximumBytes
        )
    }

    static func contentFingerprint(
        repository: URL,
        relativePath: GitPath,
        maximumBytes: Int64? = nil
    ) throws -> FileContentFingerprint? {
        do {
            return try withRegularFile(repository: repository, relativePath: relativePath) { parent, descriptor, name, initialIdentity, byteCount in
                if let maximumBytes, byteCount > maximumBytes { return nil }
                let result = try readFile(
                    descriptor: descriptor,
                    relativePath: relativePath,
                    maximumBytes: maximumBytes,
                    collectData: false
                )
                guard !result.exceededLimit else { return nil }
                guard case .unchanged = validateRegularFile(
                    parent: parent,
                    descriptor: descriptor,
                    name: name,
                    expectedIdentity: initialIdentity
                ) else { return nil }
                return FileContentFingerprint(digest: result.digest, byteCount: byteCount)
            }
        } catch let error as SyntheticUntrackedDiffError {
            if case .openFailed(_, let code) = error, code == ELOOP {
                return try symlinkFingerprint(repository: repository, relativePath: relativePath, maximumBytes: maximumBytes)
            }
            if case .openFailed(_, let code) = error, code == ENOENT || code == ENOTDIR {
                return FileContentFingerprint(digest: nil, byteCount: 0)
            }
            throw error
        }
    }
    private static func symlinkFingerprint(
        repository: URL,
        relativePath: String,
        maximumBytes: Int64?
    ) throws -> FileContentFingerprint? {
        try symlinkFingerprint(
            repository: repository,
            relativePath: GitPath(relativePath),
            maximumBytes: maximumBytes
        )
    }

    private static func symlinkFingerprint(
        repository: URL,
        relativePath: GitPath,
        maximumBytes: Int64?
    ) throws -> FileContentFingerprint? {
        guard let components = relativePath.relativeComponents,
              let name = components.last else {
            throw SyntheticUntrackedDiffError.invalidPath(relativePath.displayString)
        }

        var descriptor = open(repository.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SyntheticUntrackedDiffError.openFailed(relativePath.displayString, errno)
        }
        defer { close(descriptor) }
        for component in components.dropLast() {
            let next = withCStringBytes(component) {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                throw SyntheticUntrackedDiffError.openFailed(relativePath.displayString, errno)
            }
            close(descriptor)
            descriptor = next
        }

        var initialStatus = stat()
        let initialResult = withCStringBytes(name) {
            fstatat(descriptor, $0, &initialStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard initialResult == 0 else {
            throw SyntheticUntrackedDiffError.openFailed(relativePath.displayString, errno)
        }
        guard initialStatus.st_mode & S_IFMT == S_IFLNK else { return nil }
        var target = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let count = target.withUnsafeMutableBufferPointer { buffer in
            withCStringBytes(name) {
                readlinkat(
                    descriptor,
                    $0,
                    UnsafeMutableRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self),
                    buffer.count
                )
            }
        }
        guard count >= 0 else {
            throw SyntheticUntrackedDiffError.readFailed(relativePath.displayString, errno)
        }
        let byteCount = Int(count)
        guard byteCount < target.count else { return nil }
        if let maximumBytes, Int64(byteCount) > maximumBytes { return nil }
        var hasher = SHA256()
        hasher.update(data: Data(target[..<byteCount]))

        var finalStatus = stat()
        let finalResult = withCStringBytes(name) {
            fstatat(descriptor, $0, &finalStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard finalResult == 0,
              FileIdentity(finalStatus) == FileIdentity(initialStatus) else { return nil }
        return FileContentFingerprint(digest: Data(hasher.finalize()), byteCount: Int64(byteCount))
    }
}