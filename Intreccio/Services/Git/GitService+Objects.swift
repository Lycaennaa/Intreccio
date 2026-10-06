import Foundation

extension GitService {
    func emptyTreeObjectID(repository: URL) async throws -> String {
        let result = try await runner.run(
            repository: repository,
            arguments: ["hash-object", "-t", "tree", "--stdin"],
            input: Data(),
            environment: readEnvironment,
            outputLimit: 128,
            priority: .selectedRepository
        )
        let objectID = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (objectID.count == 40 || objectID.count == 64), objectID.allSatisfy(\.isHexDigit) else {
            throw GitServiceError.invalidObjectID(objectID)
        }
        return objectID
    }
}