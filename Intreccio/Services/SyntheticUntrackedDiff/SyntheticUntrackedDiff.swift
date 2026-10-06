import Darwin
import Foundation

nonisolated enum SyntheticUntrackedDiffError: Error, CustomStringConvertible {
    case invalidPath(String)
    case unsupportedFile(String)
    case openFailed(String, Int32)
    case readFailed(String, Int32)
    case changedDuringRead(String)

    var description: String {
        switch self {
        case .invalidPath(let path): "Invalid untracked path: \(path)"
        case .unsupportedFile(let path): "Untracked path is not a regular file: \(path)"
        case .openFailed(let path, let code): "Could not open untracked file \(path): \(String(cString: strerror(code)))"
        case .readFailed(let path, let code): "Could not read untracked file \(path): \(String(cString: strerror(code)))"
        case .changedDuringRead(let path): "Untracked file changed while loading: \(path)"
        }
    }
}

nonisolated enum SyntheticUntrackedDiff {
}
