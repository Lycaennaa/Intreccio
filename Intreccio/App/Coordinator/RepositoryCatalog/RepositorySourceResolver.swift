import Foundation

nonisolated enum RepositoryWatchRootScanOutcome: Sendable {
    case success(source: WatchRoot, result: RepoScanResult)
    case scanFailure(source: WatchRoot, message: String)
    case accessFailure(source: WatchRoot, message: String)
}

nonisolated struct RepositorySourceScanError: Error, Sendable, CustomStringConvertible {
    let message: String

    var description: String { message }
}

nonisolated enum RepositoryStandaloneResolution: Sendable {
    case resolved(source: StandaloneRepository, root: URL)
    case repositoryUnavailable(source: StandaloneRepository, message: String)
    case accessUnavailable(source: StandaloneRepository, message: String)
}

@MainActor
final class RepositorySourceResolver {
    let bookmarkStore: BookmarkStore
    let scanner: RepoScanner
    let gitService: GitService

    init(bookmarkStore: BookmarkStore, scanner: RepoScanner, gitService: GitService) {
        self.bookmarkStore = bookmarkStore
        self.scanner = scanner
        self.gitService = gitService
    }

    func scanWatchRoot(_ source: WatchRoot) async throws -> RepositoryWatchRootScanOutcome {
        let resolution: BookmarkResolution
        do {
            resolution = try await bookmarkStore.resolve(source.bookmarkData)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .accessFailure(source: source, message: String(describing: error))
        }

        var updated = source
        updated.lastResolvedPath = resolution.url.path
        updated.resourceID = ResourceIdentity.read(from: resolution.url)
        if let refreshedData = resolution.refreshedData {
            updated.bookmarkData = refreshedData
        }

        let result: RepoScanResult
        do {
            try Task.checkCancellation()
            result = try await scanner.scan(root: resolution.url, exclusions: source.exclusions)
        } catch {
            await bookmarkStore.stopAccessing(resolution)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .scanFailure(source: updated, message: String(describing: error))
        }

        await bookmarkStore.stopAccessing(resolution)
        try Task.checkCancellation()
        return .success(source: updated, result: result)
    }

    func resolveStandalone(_ source: StandaloneRepository) async throws -> RepositoryStandaloneResolution {
        let resolution: BookmarkResolution
        do {
            resolution = try await bookmarkStore.resolve(source.bookmarkData)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .accessUnavailable(source: source, message: String(describing: error))
        }

        var updated = source
        updated.lastResolvedPath = resolution.url.path
        updated.resourceID = ResourceIdentity.read(from: resolution.url)
        if let refreshedData = resolution.refreshedData {
            updated.bookmarkData = refreshedData
        }

        let repositoryRoot: URL
        do {
            try Task.checkCancellation()
            let root = try await gitService.repositoryRoot(at: resolution.url)
            guard root == RepositoryPathPolicy.canonicalURL(resolution.url) else {
                throw CoordinatorError.invalidRepository("Saved path is no longer the repository top level.")
            }
            updated.lastResolvedPath = root.path
            updated.resourceID = ResourceIdentity.read(from: root)
            repositoryRoot = root
        } catch {
            await bookmarkStore.stopAccessing(resolution)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .repositoryUnavailable(source: updated, message: String(describing: error))
        }

        await bookmarkStore.stopAccessing(resolution)
        try Task.checkCancellation()
        return .resolved(source: updated, root: repositoryRoot)
    }
}