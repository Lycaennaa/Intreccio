import Darwin
import Foundation

private nonisolated struct PendingSubmoduleParent: Sendable {
    let url: URL
    let relativePath: String?
    let repositoryIndex: Int?
}

private nonisolated struct SubmodulePathRead: Sendable {
    let paths: [String]
    let warning: String?
}

private nonisolated struct SubmoduleCandidateScan: Sendable {
    let repository: ScannedRepository?
    let warning: String?
}

private nonisolated struct SubmoduleCandidateBatch: Sendable {
    let repositories: [ScannedRepository]
    let warnings: [String]
    let seenPaths: Set<String>
    let reachedRepositoryLimit: Bool
    let reachedTimeLimit: Bool
}

private nonisolated struct SubmodulePathScanContext: Sendable {
    let parent: PendingSubmoduleParent
    let maximumRepositories: Int
    let existingPaths: Set<String>
    let normalizedExclusions: Set<String>
    let caseSensitive: Bool
    let deadline: Date
}

nonisolated struct RepositorySubmoduleScanner: Sendable {
    let gitService: GitService
    let repositoryLimit: Int
    let timeLimit: TimeInterval

    func scan(
        of parentURL: URL,
        relativePathPrefix: String? = nil,
        maximumRepositories: Int? = nil,
        normalizedExclusions: Set<String> = [],
        caseSensitive: Bool = true,
        deadline: Date? = nil
    ) async throws -> ScannedSubmodules {
        try Task.checkCancellation()
        let repositoryLimit = max(0, maximumRepositories ?? self.repositoryLimit - 1)
        let scanDeadline = deadline ?? Date().addingTimeInterval(timeLimit)
        var repositories: [ScannedRepository] = []
        var warnings: [String] = []
        var hasConfiguredSubmodules = false
        var reachedRepositoryLimit = false
        var reachedTimeLimit = false
        var seenPaths = Set([RepositoryPathPolicy.canonicalURL(parentURL).path])
        var parents = [PendingSubmoduleParent(
            url: RepositoryPathPolicy.canonicalURL(parentURL),
            relativePath: relativePathPrefix,
            repositoryIndex: nil
        )]
        var parentIndex = 0

        while parentIndex < parents.count {
            try Task.checkCancellation()
            guard Date() < scanDeadline else {
                reachedTimeLimit = true
                break
            }
            let parent = parents[parentIndex]
            parentIndex += 1
            let pathRead = try await configuredSubmodulePaths(of: parent.url)
            if let warning = pathRead.warning { warnings.append(warning) }
            guard !pathRead.paths.isEmpty else { continue }
            if let repositoryIndex = parent.repositoryIndex {
                markSubmoduleParent(at: repositoryIndex, in: &repositories)
            } else {
                hasConfiguredSubmodules = true
            }

            let batch = try await scanSubmodulePaths(
                pathRead.paths,
                context: SubmodulePathScanContext(
                    parent: parent,
                    maximumRepositories: repositoryLimit - repositories.count,
                    existingPaths: seenPaths,
                    normalizedExclusions: normalizedExclusions,
                    caseSensitive: caseSensitive,
                    deadline: scanDeadline
                )
            )
            warnings.append(contentsOf: batch.warnings)
            seenPaths = batch.seenPaths
            appendSubmoduleRepositories(batch.repositories, to: &repositories, pending: &parents)
            reachedRepositoryLimit = batch.reachedRepositoryLimit
            reachedTimeLimit = batch.reachedTimeLimit
            if reachedRepositoryLimit || reachedTimeLimit { break }
        }

        return ScannedSubmodules(
            repositories: repositories,
            hasConfiguredSubmodules: hasConfiguredSubmodules,
            warnings: warnings,
            reachedRepositoryLimit: reachedRepositoryLimit,
            reachedTimeLimit: reachedTimeLimit
        )
    }
    private func scanSubmodulePaths(
        _ paths: [String],
        context: SubmodulePathScanContext
    ) async throws -> SubmoduleCandidateBatch {
        var repositories: [ScannedRepository] = []
        var warnings: [String] = []
        var seenPaths = context.existingPaths
        var reachedRepositoryLimit = false
        var reachedTimeLimit = false
        for path in paths {
            try Task.checkCancellation()
            guard Date() < context.deadline else {
                reachedTimeLimit = true
                break
            }
            let candidate = try await scanSubmoduleCandidate(
                path,
                under: context.parent,
                normalizedExclusions: context.normalizedExclusions,
                caseSensitive: context.caseSensitive
            )
            if let warning = candidate.warning { warnings.append(warning) }
            if Date() >= context.deadline {
                reachedTimeLimit = true
                break
            }
            guard let repository = candidate.repository,
                  seenPaths.insert(repository.canonicalURL.path).inserted else { continue }
            guard repositories.count < context.maximumRepositories else {
                reachedRepositoryLimit = true
                break
            }
            repositories.append(repository)
        }
        return SubmoduleCandidateBatch(
            repositories: repositories,
            warnings: warnings,
            seenPaths: seenPaths,
            reachedRepositoryLimit: reachedRepositoryLimit,
            reachedTimeLimit: reachedTimeLimit
        )
    }

    private func appendSubmoduleRepositories(
        _ candidates: [ScannedRepository],
        to repositories: inout [ScannedRepository],
        pending: inout [PendingSubmoduleParent]
    ) {
        for repository in candidates {
            let index = repositories.count
            repositories.append(repository)
            pending.append(PendingSubmoduleParent(
                url: repository.canonicalURL,
                relativePath: repository.relativePath,
                repositoryIndex: index
            ))
        }
    }

    private func configuredSubmodulePaths(of parentURL: URL) async throws -> SubmodulePathRead {
        let gitModules = parentURL.appendingPathComponent(".gitmodules")
        do {
            guard let values = try resourceValuesIfPresent(
                gitModules,
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) else {
                return SubmodulePathRead(paths: [], warning: nil)
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return SubmodulePathRead(
                    paths: [],
                    warning: "Could not inspect submodules in \(parentURL.path): .gitmodules is not a regular file."
                )
            }
            let paths = try await gitService.configuredSubmodulePaths(repository: parentURL)
            return SubmodulePathRead(paths: paths, warning: nil)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return SubmodulePathRead(
                paths: [],
                warning: "Could not inspect submodules in \(parentURL.path): \(error)"
            )
        }
    }

    private func markSubmoduleParent(at index: Int, in repositories: inout [ScannedRepository]) {
        let repository = repositories[index]
        repositories[index] = ScannedRepository(
            url: repository.url,
            canonicalURL: repository.canonicalURL,
            relativePath: repository.relativePath,
            resourceID: repository.resourceID,
            gitDirectoryInfo: repository.gitDirectoryInfo,
            submoduleParentCanonicalURL: repository.submoduleParentCanonicalURL,
            submodulePath: repository.submodulePath,
            hasSubmodules: true
        )
    }

    private func scanSubmoduleCandidate(
        _ path: String,
        under parent: PendingSubmoduleParent,
        normalizedExclusions: Set<String>,
        caseSensitive: Bool
    ) async throws -> SubmoduleCandidateScan {
        guard RepositoryPathPolicy.relativePathComponents(path) != nil else {
            return SubmoduleCandidateScan(
                repository: nil,
                warning: "Ignored invalid configured submodule path in \(parent.url.path)."
            )
        }
        let relativePath: String
        if let prefix = parent.relativePath, !prefix.isEmpty, prefix != "." {
            relativePath = "\(prefix)/\(path)"
        } else {
            relativePath = path
        }
        let isExcluded = normalizedExclusions.contains {
            RepositoryPathPolicy.isWithin(
                relativePath: relativePath,
                folder: $0,
                caseSensitive: caseSensitive
            )
        }
        guard !isExcluded else {
            return SubmoduleCandidateScan(repository: nil, warning: nil)
        }
        let childURL: URL?
        do {
            childURL = try initializedSubmoduleDirectory(path, under: parent.url)
        } catch {
            return SubmoduleCandidateScan(
                repository: nil,
                warning: "Could not inspect configured submodule path \(relativePath) "
                    + "under \(parent.url.path): \(error)"
            )
        }
        guard let childURL else {
            return SubmoduleCandidateScan(repository: nil, warning: nil)
        }
        guard let gitInfo = GitDirectoryInfo.read(at: childURL) else {
            return SubmoduleCandidateScan(
                repository: nil,
                warning: "Could not inspect Git metadata for initialized submodule at \(childURL.path)."
            )
        }

        return try await resolveInitializedSubmoduleRepository(
            childURL,
            configuredPath: path,
            relativePath: relativePath,
            parent: parent,
            gitInfo: gitInfo
        )
    }

    private func resolveInitializedSubmoduleRepository(
        _ childURL: URL,
        configuredPath: String,
        relativePath: String,
        parent: PendingSubmoduleParent,
        gitInfo: GitDirectoryInfo
    ) async throws -> SubmoduleCandidateScan {
        let canonicalChildURL = RepositoryPathPolicy.canonicalURL(childURL)
        let childRoot: URL
        do {
            childRoot = try await gitService.repositoryRoot(at: childURL)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return SubmoduleCandidateScan(
                repository: nil,
                warning: "Ignored invalid initialized submodule at \(childURL.path): \(error)"
            )
        }
        guard childRoot == canonicalChildURL else {
            return SubmoduleCandidateScan(
                repository: nil,
                warning: "Ignored submodule whose Git root differs from its configured path: \(childURL.path)"
            )
        }
        return SubmoduleCandidateScan(
            repository: ScannedRepository(
                url: childURL,
                canonicalURL: childRoot,
                relativePath: relativePath,
                resourceID: ResourceIdentity.read(from: childRoot),
                gitDirectoryInfo: gitInfo,
                submoduleParentCanonicalURL: parent.url,
                submodulePath: configuredPath
            ),
            warning: nil
        )
    }

    private func initializedSubmoduleDirectory(_ path: String, under parentURL: URL) throws -> URL? {
        guard let components = RepositoryPathPolicy.relativePathComponents(path) else { return nil }
        var directoryURL = parentURL
        for component in components {
            directoryURL.appendPathComponent(component, isDirectory: true)
            guard let values = try resourceValuesIfPresent(
                directoryURL,
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ), values.isDirectory == true, values.isSymbolicLink != true else {
                return nil
            }
        }
        guard RepositoryPathPolicy.containsResolvingSymlinks(parentURL, directoryURL),
              let markerValues = try resourceValuesIfPresent(
                directoryURL.appendingPathComponent(".git"),
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
              ),
              markerValues.isSymbolicLink != true,
              markerValues.isRegularFile == true || markerValues.isDirectory == true else {
            return nil
        }
        return directoryURL
    }

    private func resourceValuesIfPresent(
        _ url: URL,
        forKeys keys: Set<URLResourceKey>
    ) throws -> URLResourceValues? {
        do {
            return try url.resourceValues(forKeys: keys)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return nil
            }
            if error.domain == NSPOSIXErrorDomain,
               [Int(ENOENT), Int(ENOTDIR)].contains(error.code) {
                return nil
            }
            throw error
        }
    }

}
