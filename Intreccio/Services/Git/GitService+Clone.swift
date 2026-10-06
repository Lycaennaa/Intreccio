import Foundation

nonisolated struct RepositoryCloneProgress: Sendable, Equatable {
    let detail: String
    let fractionCompleted: Double?
}

nonisolated private final class GitCloneProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ data: Data) -> [RepositoryCloneProgress] {
        lock.withLock {
            buffer.append(String(decoding: data, as: UTF8.self))
            return drainLines()
        }
    }

    func finish() -> [RepositoryCloneProgress] {
        lock.withLock {
            let line = buffer
            buffer.removeAll(keepingCapacity: false)
            guard let progress = parse(line) else { return [] }
            return [progress]
        }
    }

    private func drainLines() -> [RepositoryCloneProgress] {
        var updates = [RepositoryCloneProgress]()
        while let separator = buffer.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            let line = String(buffer[..<separator])
            buffer.removeSubrange(buffer.startIndex...separator)
            if let progress = parse(line) {
                updates.append(progress)
            }
        }
        return updates
    }

    private func parse(_ line: String) -> RepositoryCloneProgress? {
        let detail = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return nil }
        return RepositoryCloneProgress(detail: detail, fractionCompleted: percentage(in: detail))
    }

    private func percentage(in detail: String) -> Double? {
        guard let percentIndex = detail.firstIndex(of: "%") else { return nil }
        var start = percentIndex
        while start > detail.startIndex {
            let previous = detail.index(before: start)
            guard detail[previous].isNumber else { break }
            start = previous
        }
        guard start < percentIndex,
              let percentage = Double(detail[start..<percentIndex]),
              (0...100).contains(percentage) else {
            return nil
        }
        return percentage / 100
    }
}

nonisolated enum RepositoryCloneError: Error, Equatable, CustomStringConvertible {
    case invalidPublicRepositoryURL
    case invalidDestination(String)
    case destinationExists(String)
    case ownershipVerificationFailed(String)
    case cloneDidNotCreateRepository(String)
    case gitLFSMissing
    case moveFailed(String)
    case cleanupFailed(operation: String, cleanup: String)
    case cleanupRefused(String)

    var description: String {
        switch self {
        case .invalidPublicRepositoryURL:
            return "Enter a public GitHub repository URL, such as https://github.com/owner/repository."
        case .invalidDestination(let message):
            return message
        case .destinationExists(let path):
            return "A folder already exists at \(path). Choose a different destination."
        case .ownershipVerificationFailed(let path):
            return "Could not verify ownership of the cloned repository at \(path)."
        case .cloneDidNotCreateRepository(let path):
            return "Git did not create a repository at \(path)."
        case .gitLFSMissing:
            return "This repository uses Git LFS, but Git LFS is not installed. Install Git LFS and retry."
        case .moveFailed(let message):
            return "Could not finish cloning the repository: \(message)"
        case .cleanupFailed(let operation, let cleanup):
            return "\(operation)\n\nCleanup also failed: \(cleanup)"
        case .cleanupRefused(let path):
            return "Could not safely remove the temporary clone at \(path)."
        }
    }
}

extension GitService {
    func clonePublicRepository(
        from source: URL,
        into parentDirectory: URL,
        control: ProcessControl? = nil,
        progress: @escaping @Sendable (RepositoryCloneProgress) -> Void = { _ in }
    ) async throws -> RepositoryCreationReceipt {
        guard let cloneURL = GitHubRepositoryURL.publicCloneURL(from: source.absoluteString) else {
            throw RepositoryCloneError.invalidPublicRepositoryURL
        }
        defer { control?.finish() }

        let fileManager = FileManager.default
        let parent = RepositoryPathPolicy.canonicalURL(parentDirectory)
        guard RepositoryPathPolicy.isRealDirectory(parent) else {
            throw RepositoryCloneError.invalidDestination(
                "Choose an existing folder where the repository can be cloned."
            )
        }

        let repositoryName = cloneURL.deletingPathExtension().lastPathComponent
        guard !repositoryName.isEmpty else {
            throw RepositoryCloneError.invalidPublicRepositoryURL
        }
        let destination = parent.appendingPathComponent(repositoryName, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RepositoryCloneError.destinationExists(destination.path)
        }

        let temporary = parent.appendingPathComponent(
            ".intreccio-clone-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        } catch {
            throw RepositoryCloneError.invalidDestination(
                "Could not prepare the clone destination: \(error.localizedDescription)"
            )
        }
        guard let temporaryResourceID = ResourceIdentity.read(from: temporary) else {
            do {
                try fileManager.removeItem(at: temporary)
            } catch let cleanupError {
                throw RepositoryCloneError.cleanupFailed(
                    operation: "Could not verify ownership of the temporary clone at \(temporary.path).",
                    cleanup: String(describing: cleanupError)
                )
            }
            throw RepositoryCloneError.ownershipVerificationFailed(temporary.path)
        }

        do {
            progress(RepositoryCloneProgress(detail: "Cloning repository…", fractionCompleted: nil))
            try await runStreamingGit(
                arguments: ["clone", "--progress", "--recurse-submodules", "--", cloneURL.absoluteString, temporary.path],
                control: control,
                progress: progress
            )
            try Task.checkCancellation()

            let lfsAttributes = try await runner.run(
                repository: temporary,
                arguments: ["grep", "-I", "-n", "-e", "filter=lfs", "--", ":(glob)**/.gitattributes"],
                environment: networkEnvironment,
                acceptedExitCodes: [0, 1, 128],
                outputLimit: 64 * 1_024,
                timeout: ProcessRunner.readTimeout,
                priority: .normal
            )
            let lfsCheck = try await runner.run(
                repository: temporary,
                arguments: ["lfs", "version"],
                environment: networkEnvironment,
                acceptedExitCodes: [0, 1, 2, 127],
                outputLimit: 64 * 1_024,
                timeout: ProcessRunner.readTimeout,
                priority: .normal
            )
            if lfsAttributes.exitCode == 0, lfsCheck.exitCode != 0 {
                throw RepositoryCloneError.gitLFSMissing
            }
            if lfsCheck.exitCode == 0 {
                progress(RepositoryCloneProgress(detail: "Downloading Git LFS objects…", fractionCompleted: nil))
                try await runStreamingGit(
                    repository: temporary,
                    arguments: ["lfs", "pull"],
                    control: control,
                    progress: progress
                )
                try await runStreamingGit(
                    repository: temporary,
                    arguments: ["submodule", "foreach", "--recursive", "git", "lfs", "pull"],
                    control: control,
                    progress: progress
                )
            }

            guard RepositoryPathPolicy.isRealDirectory(temporary),
                  RepositoryPathPolicy.isRealDirectory(temporary.appendingPathComponent(".git", isDirectory: true)) else {
                throw RepositoryCloneError.cloneDidNotCreateRepository(temporary.path)
            }
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw RepositoryCloneError.destinationExists(destination.path)
            }
            do {
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                throw RepositoryCloneError.moveFailed(error.localizedDescription)
            }
            guard ResourceIdentity.read(from: destination) == temporaryResourceID else {
                throw RepositoryCloneError.ownershipVerificationFailed(destination.path)
            }
            return RepositoryCreationReceipt(
                url: RepositoryPathPolicy.canonicalURL(destination),
                resourceID: temporaryResourceID
            )
        } catch let operationError {
            do {
                let cleanupURL = fileManager.fileExists(atPath: temporary.path) ? temporary : destination
                try RepositoryPathPolicy.removeCreatedRepository(
                    at: cleanupURL,
                    expectedResourceID: temporaryResourceID
                )
            } catch let cleanupError {
                throw RepositoryCloneError.cleanupFailed(
                    operation: String(describing: operationError),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw operationError
        }
    }

    private func runStreamingGit(
        repository: URL? = nil,
        arguments: [String],
        control: ProcessControl?,
        progress: @escaping @Sendable (RepositoryCloneProgress) -> Void
    ) async throws {
        let parser = GitCloneProgressParser()
        let outputHandler: @Sendable (ProcessOutputStream, Data) -> Void = { stream, data in
            guard stream == .standardError else { return }
            parser.append(data).forEach(progress)
        }
        _ = try await runner.runStreaming(
            repository: repository,
            arguments: arguments,
            environment: networkEnvironment,
            outputLimit: ProcessRunner.defaultOutputLimit,
            timeout: ProcessRunner.mutationTimeout,
            priority: .normal,
            progress: outputHandler,
            control: control
        )
        parser.finish().forEach(progress)
    }

}