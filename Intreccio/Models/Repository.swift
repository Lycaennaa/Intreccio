import Foundation

nonisolated enum RepositoryAvailability: Codable, Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

nonisolated struct RepositorySnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var sourceID: UUID
    var relativePath: String?
    var canonicalPath: String
    var resourceID: String?
    var availability: RepositoryAvailability
    var submoduleParentRepositoryID: UUID?
    var submodulePath: String?
}
nonisolated enum GitHubRepositoryURL {
    static func webURL(from remote: String) -> URL? {
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else { return nil }

        let repositoryPath: String
        if !remote.contains("://"),
           let separator = remote.firstIndex(of: ":"),
           !remote[..<separator].contains("/") {
            let host = remote[..<separator]
                .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
                .last
                .map(String.init)
            guard host.map(isGitHubHost) == true else { return nil }
            repositoryPath = String(remote[remote.index(after: separator)...])
        } else {
            guard let components = URLComponents(string: remote),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https", "git", "ssh", "git+ssh"].contains(scheme),
                  components.host.map(isGitHubHost) == true,
                  components.query == nil,
                  components.fragment == nil else { return nil }
            repositoryPath = components.path
        }

        let pathComponents = repositoryPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pathComponents.count == 2 else { return nil }
        let owner = pathComponents[0]
        var repository = pathComponents[1]
        if repository.hasSuffix(".git") { repository.removeLast(4) }
        guard isValidPathComponent(owner), isValidPathComponent(repository) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(owner)/\(repository)"
        return components.url
    }
    static func cloneURL(from remote: String) -> URL? {
        guard let webURL = webURL(from: remote),
              var components = URLComponents(url: webURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path += ".git"
        return components.url
    }

    private static func isGitHubHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "github.com" || normalized == "www.github.com"
    }

    private static func isValidPathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

nonisolated struct GitDirectoryInfo: Sendable, Equatable {
    private enum MetadataFileRead {
        case text(String)
        case unavailable
        case tooLarge
    }

    private static let maximumMetadataFileBytes = 4_096

    let commonGitDirectoryURL: URL
    let isLinkedWorktree: Bool

    static func read(at workingDirectoryURL: URL) -> GitDirectoryInfo? {
        let gitMarker = workingDirectoryURL.appendingPathComponent(".git")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: gitMarker.path),
              let type = attributes[.type] as? FileAttributeType else { return nil }
        if type == .typeDirectory {
            return GitDirectoryInfo(
                commonGitDirectoryURL: gitMarker.standardizedFileURL,
                isLinkedWorktree: false
            )
        }
        guard type == .typeRegular,
              case .text(let markerContents) = readMetadataFile(at: gitMarker),
              markerContents.hasPrefix("gitdir: ") else { return nil }
        let gitDirectoryPath = String(markerContents.dropFirst("gitdir: ".count))
            .trimmingCharacters(in: .newlines)
        let gitDirectoryURL = URL(fileURLWithPath: gitDirectoryPath, relativeTo: workingDirectoryURL)
            .standardizedFileURL
        let commonDirectoryMarker = gitDirectoryURL.appendingPathComponent("commondir")
        let commonDirectoryPath: String
        switch readMetadataFile(at: commonDirectoryMarker) {
        case .text(let path):
            commonDirectoryPath = path
        case .unavailable:
            return GitDirectoryInfo(commonGitDirectoryURL: gitDirectoryURL, isLinkedWorktree: false)
        case .tooLarge:
            return nil
        }
        let commonGitDirectoryURL = URL(
            fileURLWithPath: commonDirectoryPath.trimmingCharacters(in: .newlines),
            relativeTo: gitDirectoryURL
        ).standardizedFileURL
        return GitDirectoryInfo(
            commonGitDirectoryURL: commonGitDirectoryURL,
            isLinkedWorktree: commonGitDirectoryURL != gitDirectoryURL
        )
    }

    private static func readMetadataFile(at url: URL) -> MetadataFileRead {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unavailable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumMetadataFileBytes + 1) else {
            return .unavailable
        }
        guard data.count <= maximumMetadataFileBytes else { return .tooLarge }
        guard let contents = String(data: data, encoding: .utf8) else { return .unavailable }
        return .text(contents)
    }
}

nonisolated struct StandaloneRepositoryLocation: Sendable, Equatable {
    let url: URL
    let gitDirectoryInfo: GitDirectoryInfo?
    let submoduleRepositories: [ScannedRepository]
    let hasSubmodules: Bool
    let submoduleScanIncomplete: Bool

    init(
        url: URL,
        gitDirectoryInfo: GitDirectoryInfo?,
        submoduleRepositories: [ScannedRepository] = [],
        hasSubmodules: Bool = false,
        submoduleScanIncomplete: Bool = false
    ) {
        self.url = url
        self.gitDirectoryInfo = gitDirectoryInfo
        self.submoduleRepositories = submoduleRepositories
        self.hasSubmodules = hasSubmodules
        self.submoduleScanIncomplete = submoduleScanIncomplete
    }
}

nonisolated struct RepoDescriptor: Sendable, Equatable, Identifiable {
    let id: UUID
    let source: RepositorySource
    let url: URL
    let canonicalURL: URL
    let resourceID: String?
    let relativePath: String?
    let availability: RepositoryAvailability
    let gitDirectoryInfo: GitDirectoryInfo?
    let mainRepositoryURL: URL?
    let submoduleParentRepositoryID: UUID?
    let submodulePath: String?
    let hasSubmodules: Bool

    init(
        id: UUID,
        source: RepositorySource,
        url: URL,
        canonicalURL: URL,
        resourceID: String?,
        relativePath: String?,
        availability: RepositoryAvailability,
        gitDirectoryInfo: GitDirectoryInfo? = nil,
        mainRepositoryURL: URL? = nil,
        submoduleParentRepositoryID: UUID? = nil,
        submodulePath: String? = nil,
        hasSubmodules: Bool = false
    ) {
        self.id = id
        self.source = source
        self.url = url
        self.canonicalURL = canonicalURL
        self.resourceID = resourceID
        self.relativePath = relativePath
        self.availability = availability
        self.gitDirectoryInfo = gitDirectoryInfo
        self.mainRepositoryURL = mainRepositoryURL
        self.submoduleParentRepositoryID = submoduleParentRepositoryID
        self.submodulePath = submodulePath
        self.hasSubmodules = hasSubmodules
    }

    var commonGitDirectoryURL: URL? { gitDirectoryInfo?.commonGitDirectoryURL }
    var isLinkedWorktree: Bool { gitDirectoryInfo?.isLinkedWorktree == true }
    var baseDisplayName: String {
        (mainRepositoryURL ?? canonicalURL).lastPathComponent
    }
    var displayName: String {
        guard isLinkedWorktree else { return canonicalURL.lastPathComponent }
        guard let mainRepositoryURL else { return canonicalURL.lastPathComponent }
        return "\(mainRepositoryURL.lastPathComponent) (\(canonicalURL.lastPathComponent))"
    }
    static func disambiguatedDisplayNames(for repositories: [RepoDescriptor]) -> [UUID: String] {
        let repositoriesByDisplayName = Dictionary(grouping: repositories, by: \.displayName)
        var displayNames = [UUID: String]()
        displayNames.reserveCapacity(repositories.count)
        for repository in repositories {
            let name = repository.displayName
            let label = (repositoriesByDisplayName[name]?.count ?? 0) > 1
                ? "\(name) — \(repository.canonicalURL.path)"
                : name
            displayNames[repository.id] = label
        }
        return displayNames
    }

    func withMainRepositoryURL(_ repositoryURL: URL) -> RepoDescriptor {
        RepoDescriptor(
            id: id,
            source: source,
            url: url,
            canonicalURL: canonicalURL,
            resourceID: resourceID,
            relativePath: relativePath,
            availability: availability,
            gitDirectoryInfo: gitDirectoryInfo,
            mainRepositoryURL: repositoryURL,
            submoduleParentRepositoryID: submoduleParentRepositoryID,
            submodulePath: submodulePath,
            hasSubmodules: hasSubmodules
        )
    }

    func withSubmoduleParentRepository(id parentID: UUID, path: String) -> RepoDescriptor {
        RepoDescriptor(
            id: id,
            source: source,
            url: url,
            canonicalURL: canonicalURL,
            resourceID: resourceID,
            relativePath: relativePath,
            availability: availability,
            gitDirectoryInfo: gitDirectoryInfo,
            mainRepositoryURL: mainRepositoryURL,
            submoduleParentRepositoryID: parentID,
            submodulePath: path,
            hasSubmodules: hasSubmodules
        )
    }
}

