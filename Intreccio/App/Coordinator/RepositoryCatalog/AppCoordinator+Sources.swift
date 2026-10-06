import Foundation
nonisolated enum RepositoryCloneResult: Sendable, Equatable {
    case succeeded
    case failed(String)
    case cancelled
}

@MainActor
extension AppCoordinator {
    func addWatchRoot(_ selectedURL: URL) async {
        do {
            _ = try await catalog.addWatchRoot(selectedURL)
        } catch is CancellationError {
        } catch RepositoryCatalogCommandError.duplicateWatchRoot {
            guard !isShuttingDown else { return }
            errorMessage = "That folder is already watched."
            publish()
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            errorMessage = "Could not add folder: \(error)"
            publish()
        }
    }

    func addStandaloneRepository(_ selectedURL: URL) async {
        do {
            let outcome = try await catalog.addStandaloneRepository(selectedURL)
            if case .selectedRepository(let repositoryID) = outcome {
                selectRepository(repositoryID)
            }
        } catch is CancellationError {
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            errorMessage = "Could not add repository: \(error)"
            publish()
        }
    }
    @discardableResult
    func createLocalRepository(named name: String, in parentDirectory: URL) async -> Bool {
        do {
            let outcome = try await catalog.createLocalRepository(named: name, in: parentDirectory)
            switch outcome {
            case .selectedRepository(let repositoryID):
                selectRepository(repositoryID)
            case .createdRepository(let repositoryURL):
                selectRepository(at: repositoryURL)
            case .changed, .noChange:
                break
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return false }
            errorMessage = "Could not create repository: \(error)"
            publish()
            return false
        }
    }
    @discardableResult
    func clonePublicRepository(
        from sourceURL: URL,
        into destinationParent: URL,
        control: ProcessControl? = nil,
        progress: @escaping @Sendable (RepositoryCloneProgress) -> Void = { _ in }
    ) async -> RepositoryCloneResult {
        do {
            let outcome = try await catalog.clonePublicRepository(
                from: sourceURL,
                into: destinationParent,
                control: control,
                progress: progress
            )
            switch outcome {
            case .selectedRepository(let repositoryID):
                selectRepository(repositoryID)
            case .createdRepository(let repositoryURL):
                selectRepository(at: repositoryURL)
            case .changed, .noChange:
                break
            }

            return .succeeded
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return .cancelled }
            let message = "Could not clone repository: \(error)"
            errorMessage = message
            publish()
            return .failed(message)
        }
    }
    private func selectRepository(at url: URL) {
        let canonicalURL = RepositoryPathPolicy.canonicalURL(url)
        if let repositoryID = repositories.first(where: { $0.canonicalURL == canonicalURL })?.id {
            selectRepository(repositoryID)
        }
    }

    func rescanAll(refreshUpstream: Bool = true) {
        guard !isShuttingDown else { return }
        lastFullRescanAt = ContinuousClock.now
        catalog.rescanAll(refreshUpstream: refreshUpstream)
    }

    func rescanAllIfStale(at now: ContinuousClock.Instant = ContinuousClock.now) {
        guard hasLoadedState,
              !isShuttingDown,
              startupTask == nil,
              catalog.fullRescanTask == nil else { return }
        let isStale = lastFullRescanAt.map {
            $0.duration(to: now) >= Self.activationRescanStaleness
        } ?? true
        guard isStale || hasMissingFileEventCoverage else { return }
        rescanAll()
    }

    private var hasMissingFileEventCoverage: Bool {
        let expectedSourceIDs = Set(state.watchRoots.map(\.id))
        let expectedRepositoryIDs = Set(repositories.filter {
            $0.availability == .available
        }.map(\.id))
        let coverage = runtime.eventCoverageSnapshot
        return coverage.sourceWatcherIDs != expectedSourceIDs
            || coverage.coveredRepositoryIDs != expectedRepositoryIDs
            || coverage.liveSourceWatcherIDs != expectedSourceIDs
            || coverage.liveCoveredRepositoryIDs != expectedRepositoryIDs
    }

    func rescanSource(_ sourceID: UUID) {
        guard !isShuttingDown else { return }
        catalog.rescanSource(sourceID)
    }

    func removeSource(_ sourceID: UUID) async {
        do {
            _ = try await catalog.removeSource(sourceID)
        } catch is CancellationError {
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            errorMessage = "Could not remove source: \(error)"
            publish()
        }
    }

    func excludeRepository(_ repositoryID: UUID) async {
        do {
            _ = try await catalog.excludeRepository(repositoryID)
        } catch is CancellationError {
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            errorMessage = "Could not exclude repository: \(error)"
            publish()
        }
    }

    func excludeFolder(sourceID: UUID, path: String) async {
        do {
            _ = try await catalog.excludeFolder(sourceID: sourceID, path: path)
        } catch is CancellationError {
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            errorMessage = "Could not exclude folder: \(error)"
            publish()
        }
    }

    func restoreExclusion(sourceID: UUID, path: String) async {
        do {
            _ = try await catalog.restoreExclusion(sourceID: sourceID, path: path)
        } catch is CancellationError {
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            errorMessage = "Could not restore exclusion: \(error)"
            publish()
        }
    }
}
