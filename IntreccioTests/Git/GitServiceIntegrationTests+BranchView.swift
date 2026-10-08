import Foundation
import XCTest

@testable import Intreccio

private struct SeparateGitDirectoryFixture {
  let directory: URL
  let repository: URL
  let gitDirectory: URL
  let worktree: URL
}

extension GitServiceIntegrationTests {
  func testBranchFilesAndHistoryCanBeReadWithoutChangingDirtyWorktree() async throws {
    let fixture = try GitFixture(testCase: self)
    try fixture.write("main\n", to: "tracked.txt")
    try fixture.git("add", "-A")
    try fixture.git("commit", "-m", "main")
    try fixture.git("checkout", "-b", "feature")
    try fixture.write("feature\n", to: "tracked.txt")
    try fixture.write("newline path\n", to: "folder/line\nbreak.txt")
    try fixture.write(Data([0, 1, 2, 0]), to: "image.bin")
    try fixture.write(
      Data(repeating: 0x61, count: GitService.branchBlobPreviewLimit + 1), to: "large.txt")
    try fixture.git("add", "-A")
    try fixture.git("commit", "-m", "feature")
    let featureObjectID = try fixture.git("rev-parse", "HEAD").standardOutputText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try fixture.git("update-ref", "refs/remotes/origin/feature", featureObjectID)
    try fixture.git("checkout", "main")
    try fixture.write("modified\n", to: "tracked.txt")
    try fixture.write("untracked\n", to: "untracked.txt")

    let service = GitService()
    let statusBefore = try await service.status(repository: fixture.url)
    let headBefore = try fixture.git("rev-parse", "HEAD").standardOutputText
    let branches = try await service.branchReferences(repository: fixture.url)
    let localFeature = try XCTUnwrap(branches.first { $0.refName == "refs/heads/feature" })
    let remoteFeature = try XCTUnwrap(
      branches.first { $0.refName == "refs/remotes/origin/feature" })
    XCTAssertEqual(localFeature.objectID, featureObjectID)
    XCTAssertFalse(localFeature.isCurrent)
    XCTAssertTrue(remoteFeature.isRemote)
    XCTAssertTrue(branches.first { $0.refName == "refs/heads/main" }?.isCurrent == true)

    let entries = try await service.branchTreeEntries(
      repository: fixture.url,
      commitObjectID: localFeature.objectID
    )
    let trackedFile = try XCTUnwrap(entries.first { $0.path == GitPath("tracked.txt") })
    let trackedPreview = try await service.branchBlobPreview(
      repository: fixture.url,
      objectID: trackedFile.objectID
    )
    XCTAssertEqual(trackedPreview, .text("feature\n"))
    let newlinePath = try XCTUnwrap(
      entries.first { $0.path.displayString == "folder/line\\nbreak.txt" })
    XCTAssertEqual(newlinePath.path.bytes, Data("folder/line\nbreak.txt".utf8))
    let binary = try XCTUnwrap(entries.first { $0.path == GitPath("image.bin") })
    let binaryPreview = try await service.branchBlobPreview(
      repository: fixture.url, objectID: binary.objectID)
    XCTAssertEqual(binaryPreview, .binary)
    let large = try XCTUnwrap(entries.first { $0.path == GitPath("large.txt") })
    let largePreview = try await service.branchBlobPreview(
      repository: fixture.url, objectID: large.objectID)
    XCTAssertEqual(largePreview, .tooLarge)

    XCTAssertEqual(try fixture.git("rev-parse", "HEAD").standardOutputText, headBefore)
    let statusAfter = try await service.status(repository: fixture.url)
    XCTAssertEqual(statusAfter, statusBefore)
    XCTAssertEqual(try fixture.read("tracked.txt"), "modified\n")
    XCTAssertEqual(try fixture.read("untracked.txt"), "untracked\n")
  }

  func testWorktreeBranchNamePreservesNestedBranchPath() {
    let worktree = GitWorktree(
      path: URL(fileURLWithPath: "/worktrees/feature"),
      branchReference: "refs/heads/team/feature"
    )

    XCTAssertEqual(worktree.branchName, "team/feature")
  }

  @MainActor
  func testLinkedWorktreeFindsMainRootWithSeparateGitDirectory() async throws {
    let fixture = try makeSeparateGitDirectoryFixture()
    let linkedInfo = try XCTUnwrap(GitDirectoryInfo.read(at: fixture.worktree))
    let mainInfo = try XCTUnwrap(GitDirectoryInfo.read(at: fixture.repository))
    XCTAssertTrue(linkedInfo.isLinkedWorktree)
    XCTAssertFalse(mainInfo.isLinkedWorktree)
    XCTAssertEqual(linkedInfo.commonGitDirectoryURL, fixture.gitDirectory.standardizedFileURL)
    XCTAssertEqual(mainInfo.commonGitDirectoryURL, fixture.gitDirectory.standardizedFileURL)
    let worktrees = try await GitService().worktrees(repository: fixture.worktree)
    XCTAssertTrue(
      worktrees.contains { $0.path.standardizedFileURL == fixture.worktree.standardizedFileURL }
    )

    let rebuilt = rebuildSeparateGitDirectoryRepositories(fixture)
    let linkedRepository = try XCTUnwrap(
      rebuilt.repositories.first { $0.canonicalURL == fixture.worktree }
    )
    let mainRepository = try XCTUnwrap(
      rebuilt.repositories.first { $0.canonicalURL == fixture.repository }
    )
    XCTAssertEqual(mainRepository.commonGitDirectoryURL, fixture.gitDirectory)
    XCTAssertFalse(mainRepository.isLinkedWorktree)
    XCTAssertEqual(linkedRepository.commonGitDirectoryURL, fixture.gitDirectory)
    XCTAssertTrue(linkedRepository.isLinkedWorktree)
    XCTAssertEqual(linkedRepository.mainRepositoryURL, fixture.repository)
    XCTAssertEqual(linkedRepository.displayName, "main (feature)")

    let coordinator = AppCoordinator(
      stateStore: StateStore(fileURL: fixture.directory.appendingPathComponent("state.json")),
      repositoryCatalogFixture: RepositoryCatalogFixture(repositories: rebuilt.repositories)
    )
    coordinator.setMode(.changes)
    coordinator.selectRepository(linkedRepository.id)
    let selector = ChangesWorktreeSelectorController(coordinator: coordinator)
    selector.reload(repository: linkedRepository)
    try await waitUntil(description: "separate Git-dir selector lists main and linked worktrees") {
      let listedPaths = selector.button.itemArray.compactMap { $0.representedObject as? URL }
        .map(\.standardizedFileURL)
      return listedPaths.contains(fixture.repository.standardizedFileURL)
        && listedPaths.contains(fixture.worktree.standardizedFileURL)
    }
    _ = await coordinator.shutdown()
  }
  func testLinkedWorktreeChangesRemainIsolatedAndAreDiscoverable() async throws {
    let fixture = try GitFixture(testCase: self)
    try fixture.write("main\n", to: "tracked.txt")
    try fixture.git("add", "-A")
    try fixture.git("commit", "-m", "main")
    try fixture.git("checkout", "-b", "feature")
    try fixture.write("feature\n", to: "tracked.txt")
    try fixture.git("add", "-A")
    try fixture.git("commit", "-m", "feature")
    try fixture.git("checkout", "main")
    let worktreeURL = fixture.url.deletingLastPathComponent().appendingPathComponent(
      "\(fixture.url.lastPathComponent)-feature",
      isDirectory: true
    )
    defer { _ = try? fixture.git("worktree", "remove", "--force", worktreeURL.path) }
    try fixture.git("worktree", "add", worktreeURL.path, "feature")
    try "dirty in worktree\n".write(
      to: worktreeURL.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "untracked in worktree\n".write(
      to: worktreeURL.appendingPathComponent("untracked.txt"),
      atomically: true,
      encoding: .utf8
    )

    let service = GitService()
    let linkedWorktree = try await service.linkedWorktreeURL(
      repository: fixture.url,
      branchReference: "refs/heads/feature"
    )
    let linkedURL = try XCTUnwrap(linkedWorktree)
    XCTAssertEqual(linkedURL.standardizedFileURL, worktreeURL.standardizedFileURL)
    let linkedStatus = try await service.status(repository: linkedURL)
    let mainStatus = try await service.status(repository: fixture.url)
    XCTAssertTrue(
      linkedStatus.changes.contains {
        $0.gitPath == GitPath("tracked.txt") && $0.hasUnstagedChange
      }
    )
    XCTAssertTrue(
      linkedStatus.changes.contains {
        $0.gitPath == GitPath("untracked.txt") && $0.kind == .untracked
      }
    )
    XCTAssertTrue(mainStatus.changes.isEmpty)
    XCTAssertEqual(try fixture.read("tracked.txt"), "main\n")
  }
  private func rebuildSeparateGitDirectoryRepositories(
    _ fixture: SeparateGitDirectoryFixture
  ) -> RepositoryCatalogRebuildResult {
    let mainID = UUID()
    let linkedID = UUID()
    let state = PersistedState(standaloneRepos: [
      StandaloneRepository(
        id: mainID,
        displayName: "Main",
        bookmarkData: Data(),
        lastResolvedPath: fixture.repository.path,
        resourceID: nil
      ),
      StandaloneRepository(
        id: linkedID,
        displayName: "Feature",
        bookmarkData: Data(),
        lastResolvedPath: fixture.worktree.path,
        resourceID: nil
      )
    ])
    return RepositoryCatalogRebuilder.rebuild(
      state: state,
      sourceScans: [:],
      standaloneRepositories: [
        mainID: StandaloneRepositoryLocation(
          url: fixture.repository,
          gitDirectoryInfo: GitDirectoryInfo.read(at: fixture.repository)
        ),
        linkedID: StandaloneRepositoryLocation(
          url: fixture.worktree,
          gitDirectoryInfo: GitDirectoryInfo.read(at: fixture.worktree)
        )
      ]
    )
  }

  private func makeSeparateGitDirectoryFixture() throws -> SeparateGitDirectoryFixture {
    let directory = try makeTestDirectory()
    let repository = directory.appendingPathComponent("main", isDirectory: true)
    let gitDirectory = directory.appendingPathComponent("git-data", isDirectory: true)
    let worktree = directory.appendingPathComponent("feature", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try runGit(
      at: directory,
      arguments: ["init", "--separate-git-dir", gitDirectory.path, repository.path]
    )
    try runGit(at: repository, arguments: ["config", "user.name", "Fixture User"])
    try runGit(at: repository, arguments: ["config", "user.email", "fixture@example.com"])
    try "main\n".write(
      to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    try runGit(at: repository, arguments: ["add", "-A"])
    try runGit(at: repository, arguments: ["commit", "-m", "main commit"])
    try runGit(at: repository, arguments: ["worktree", "add", "-b", "feature", worktree.path])
    return SeparateGitDirectoryFixture(
      directory: directory,
      repository: repository,
      gitDirectory: gitDirectory,
      worktree: worktree
    )
  }
}
