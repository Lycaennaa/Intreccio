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

nonisolated struct RepoDescriptor: Sendable, Equatable, Identifiable {
    let id: UUID
    let source: RepositorySource
    let url: URL
    let canonicalURL: URL
    let resourceID: String?
    let relativePath: String?
    let availability: RepositoryAvailability

    var displayName: String { canonicalURL.lastPathComponent }
}
