import Foundation
nonisolated enum LocalRepositoryNamePolicy {
    static func normalized(_ name: String) -> String? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized != ".",
              normalized != "..",
              !normalized.contains("/"),
              !normalized.contains("\0") else {
            return nil
        }
        return normalized
    }
}

nonisolated enum LocalRepositoryCreationError: Error, Equatable, CustomStringConvertible {
    case invalidName
    case invalidDestination
    case destinationExists(String)
    case ownershipVerificationFailed(String)
    case initializationFailed(String)
    case cleanupFailed(operation: String, cleanup: String)

    var description: String {
        switch self {
        case .invalidName:
            return "Enter a repository name without path separators."
        case .invalidDestination:
            return "Choose an existing folder where the repository can be created."
        case .destinationExists(let path):
            return "A folder already exists at \(path). Choose a different name or destination."
        case .ownershipVerificationFailed(let path):
            return "Could not verify ownership of the created repository at \(path)."
        case .initializationFailed(let message):
            return "Could not initialize the repository: \(message)"
        case .cleanupFailed(let operation, let cleanup):
            return "\(operation)\n\nCleanup also failed: \(cleanup)"
        }
    }
}

extension GitService {
    func createLocalRepository(named name: String, in parentDirectory: URL) async throws -> RepositoryCreationReceipt {
        guard let repositoryName = LocalRepositoryNamePolicy.normalized(name) else {
            throw LocalRepositoryCreationError.invalidName
        }

        let fileManager = FileManager.default
        let parent = RepositoryPathPolicy.canonicalURL(parentDirectory)
        guard RepositoryPathPolicy.isRealDirectory(parent) else {
            throw LocalRepositoryCreationError.invalidDestination
        }
        let destination = parent.appendingPathComponent(repositoryName, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw LocalRepositoryCreationError.destinationExists(destination.path)
        }

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            throw LocalRepositoryCreationError.invalidDestination
        }
        guard let resourceID = ResourceIdentity.read(from: destination) else {
            do {
                try fileManager.removeItem(at: destination)
            } catch let cleanupError {
                throw LocalRepositoryCreationError.cleanupFailed(
                    operation: "Could not verify ownership of the created repository at \(destination.path).",
                    cleanup: String(describing: cleanupError)
                )
            }
            throw LocalRepositoryCreationError.ownershipVerificationFailed(destination.path)
        }

        do {
            _ = try await runner.run(
                arguments: ["init", "-b", "main", destination.path],
                environment: mutationEnvironment,
                timeout: ProcessRunner.mutationTimeout
            )
            try Task.checkCancellation()
            guard RepositoryPathPolicy.isRealDirectory(destination.appendingPathComponent(".git", isDirectory: true)) else {
                throw LocalRepositoryCreationError.initializationFailed(
                    "Git did not create repository metadata at \(destination.path)."
                )
            }
            guard ResourceIdentity.read(from: destination) == resourceID else {
                throw LocalRepositoryCreationError.ownershipVerificationFailed(destination.path)
            }
            return RepositoryCreationReceipt(
                url: RepositoryPathPolicy.canonicalURL(destination),
                resourceID: resourceID
            )
        } catch let operationError {
            do {
                try RepositoryPathPolicy.removeCreatedRepository(
                    at: destination,
                    expectedResourceID: resourceID
                )
            } catch let cleanupError {
                throw LocalRepositoryCreationError.cleanupFailed(
                    operation: String(describing: operationError),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw operationError
        }
    }

}
