import Foundation

extension GitService {
    func diffComparisonArguments(for kind: DiffKind, repository: URL) async throws -> [String] {
        switch kind {
        case .unstaged: return []
        case .staged: return ["--cached"]
        case .uncommitted:
            if let head = try await headObjectID(repository: repository) { return [head] }
            return [try await emptyTreeObjectID(repository: repository)]
        }
    }

}