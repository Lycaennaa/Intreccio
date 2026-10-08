import Foundation

nonisolated enum RepositoryPathPolicyError: Error, Equatable, CustomStringConvertible {
    case cleanupRefused(String)

    var description: String {
        switch self {
        case .cleanupRefused(let path):
            "Could not safely remove the created repository at \(path)."
        }
    }
}

nonisolated struct RepositoryCreationReceipt: Sendable, Equatable {
    let url: URL
    let resourceID: String
}

nonisolated enum RepositoryPathPolicy {
    static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
    static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
    static func removeCreatedRepository(at url: URL, expectedResourceID: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard isRealDirectory(url),
              ResourceIdentity.read(from: url) == expectedResourceID else {
            throw RepositoryPathPolicyError.cleanupRefused(url.path)
        }
        try fileManager.removeItem(at: url)
    }

    static func standardizedURL(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    static func canonicalPath(_ path: String) -> String {
        canonicalURL(URL(fileURLWithPath: path)).path
    }

    static func relativePathComponents(_ path: String) -> [String]? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return components
    }

    static func relativePath(from root: URL, to child: URL) -> String? {
        let rootComponents = root.pathComponents
        let childComponents = child.pathComponents
        guard childComponents.starts(with: rootComponents) else { return nil }
        let components = childComponents.dropFirst(rootComponents.count)
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    static func normalizedRelativePath(_ path: String, caseSensitive: Bool = true) -> String {
        let normalized = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(into: [Substring]()) { components, component in
                if component == "." { return }
                if component == ".." { _ = components.popLast() } else { components.append(component) }
            }
            .joined(separator: "/")
        return caseSensitive ? normalized : normalized.lowercased()
    }

    static func isWithin(
        relativePath: String?,
        folder: String,
        caseSensitive: Bool = true
    ) -> Bool {
        guard let relativePath else { return false }
        let normalizedPath = normalizedRelativePath(relativePath, caseSensitive: caseSensitive)
        let normalizedFolder = normalizedRelativePath(folder, caseSensitive: caseSensitive)
        if normalizedFolder.isEmpty { return true }
        return normalizedPath == normalizedFolder
            || normalizedPath.hasPrefix(normalizedFolder + "/")
    }

    static func isExcluded(
        relativePath: String?,
        by exclusions: [String],
        root: URL
    ) -> Bool {
        let caseSensitive = isCaseSensitiveVolume(at: root)
        return exclusions.contains { exclusion in
            isWithin(relativePath: relativePath, folder: exclusion, caseSensitive: caseSensitive)
        }
    }

    static func isExactlyExcluded(
        _ relativePath: String,
        normalizedExclusions: Set<String>,
        caseSensitive: Bool
    ) -> Bool {
        normalizedExclusions.contains(
            normalizedRelativePath(relativePath, caseSensitive: caseSensitive)
        )
    }

    static func isCaseSensitiveVolume(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
    }

    static func contains(
        _ ancestor: URL,
        _ child: URL,
        caseSensitive: Bool = true
    ) -> Bool {
        let ancestorComponents = standardizedURL(ancestor).pathComponents
        let childComponents = standardizedURL(child).pathComponents
        guard ancestorComponents.count <= childComponents.count else { return false }
        return zip(ancestorComponents, childComponents).allSatisfy { ancestorComponent, childComponent in
            caseSensitive
                ? ancestorComponent == childComponent
                : ancestorComponent.caseInsensitiveCompare(childComponent) == .orderedSame
        }
    }

    static func containsResolvingSymlinks(_ ancestor: URL, _ child: URL) -> Bool {
        let ancestorPath = canonicalURL(ancestor).path
        let childPath = canonicalURL(child).path
        if ancestorPath == "/" { return childPath.hasPrefix("/") }
        return childPath == ancestorPath || childPath.hasPrefix(ancestorPath + "/")
    }
}
