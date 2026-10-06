import XCTest
@testable import Intreccio

@MainActor
final class RepositoryCatalogRefactorTests: XCTestCase {




    func makeChange(message: String, effect: CatalogEffectPlan) -> CatalogChange {
        let repositoryID = UUID()
        return CatalogChange(
            state: PersistedState(),
            sourceScans: [:],
            standaloneURLs: [:],
            repositories: [],
            scanMessages: [repositoryID: message],
            effect: effect
        )
    }
}

func makeGitRepository(at url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try runGit(at: url, arguments: ["init", "-b", "main"])
}

@MainActor
final class CatalogCommitProbe: RepositoryCatalogDelegate {
    let stateFile: URL
    var repositoryCatalogState = PersistedState()
    var reconcileCount = 0
    var fileExistedWhenReconciled = false
    var commitStatuses: [CatalogPersistenceStatus] = []
    var reconciledState: PersistedState?

    init(stateFile: URL) {
        self.stateFile = stateFile
    }

    func repositoryCatalogWillBeginSourceCommand() {}

    func repositoryCatalog(didLoad result: StateLoadResult) -> PersistedState? {
        result.state
    }

    func repositoryCatalog(reconcile change: CatalogChange) -> PersistedState {
        reconcileCount += 1
        fileExistedWhenReconciled = FileManager.default.fileExists(atPath: stateFile.path)
        repositoryCatalogState = reconciledState ?? change.state
        return repositoryCatalogState
    }

    func repositoryCatalog(didCommit result: CatalogCommitResult) async {
        commitStatuses.append(result.persistenceStatus)
    }

    func repositoryCatalog(didFail failure: RepositoryCatalogFailure) {}
}