import Foundation

nonisolated enum DiffFileOversizedReason: Sendable, Equatable {
    case byteLimit(maximumBytes: Int)
    case lineLimit(maximumLines: Int)
    case estimatedRenderSizeLimit(maximumBytes: Int)
}

nonisolated enum DiffFileUnavailableReason: Sendable, Equatable {
    case invalidPath
    case unsupportedFile
    case permissionDenied
    case changedDuringRead
    case readFailed(String)
}

extension DiffFileUnavailableReason {
    nonisolated var isRetryable: Bool {
        switch self {
        case .invalidPath: false
        case .unsupportedFile, .permissionDenied, .changedDuringRead, .readFailed: true
        }
    }
}

nonisolated enum GitOutputCompleteness: Sendable, Equatable {
    case complete
    case truncated(limit: Int)
    case unavailable

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}

nonisolated struct GitRawOutput: Sendable, Equatable {
    let bytes: Data
    let completeness: GitOutputCompleteness

    init(bytes: Data, completeness: GitOutputCompleteness = .complete) {
        self.bytes = bytes
        self.completeness = completeness
    }

    var isComplete: Bool {
        completeness.isComplete
    }
}

nonisolated enum DiffRawOrigin: Sendable, Equatable {
    case git
    case synthetic
    case mixed
    case unavailable
}

nonisolated enum DiffRawPatchCoverage: Sendable, Equatable {
    case entireSelection
    case trackedFilesOnly
    case unavailable
}

nonisolated enum DiffRawPatch: Sendable, Equatable {
    case git(GitRawOutput)
    case synthetic
    case mixed(GitRawOutput)
    case unavailable

    var gitOutput: GitRawOutput? {
        switch self {
        case .git(let output), .mixed(let output): return output
        case .synthetic, .unavailable: return nil
        }
    }

    var origin: DiffRawOrigin {
        switch self {
        case .git: return .git
        case .synthetic: return .synthetic
        case .mixed: return .mixed
        case .unavailable: return .unavailable
        }
    }

    var coverage: DiffRawPatchCoverage {
        switch self {
        case .git: return .entireSelection
        case .mixed: return .trackedFilesOnly
        case .synthetic, .unavailable: return .unavailable
        }
    }

    var exactGitBytes: Data? {
        guard case .git(let output) = self, output.isComplete else { return nil }
        return output.bytes
    }

    var isExactGitOutput: Bool {
        exactGitBytes != nil
    }
}
