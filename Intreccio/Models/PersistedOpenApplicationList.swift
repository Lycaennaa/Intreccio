import Foundation

nonisolated struct PersistedOpenApplicationList: Equatable, Sendable {
    static let maxSavedApplications = 32
    static let maxExcludedApplications = 128

    static let defaultFolderApplicationURLs: [URL] = [
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
        URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
        // Pre-Catalina layout fallback; dropped by normalization if absent.
        URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")
    ]

    private static let defaultFolderApplicationPaths = Set(
        defaultFolderApplicationURLs.compactMap(stableIdentity(for:))
    )

    var savedApplicationURLs: [URL]
    var excludedApplicationURLs: [URL]

    init(savedApplicationURLs: [URL] = [], excludedApplicationURLs: [URL] = []) {
        self.savedApplicationURLs = savedApplicationURLs
        self.excludedApplicationURLs = excludedApplicationURLs
    }

    static func normalizedApplicationURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let normalizedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard normalizedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
        return normalizedURL
    }

    static func stableIdentity(for applicationURL: URL) -> String? {
        normalizedApplicationURL(applicationURL)?.path
    }

    static func isDefaultFolderApplication(_ applicationURL: URL) -> Bool {
        guard let identity = stableIdentity(for: applicationURL) else { return false }
        return defaultFolderApplicationPaths.contains(identity)
    }

    static func normalizedSavedApplicationURLs(_ urls: [URL]) -> [URL] {
        normalizedApplicationURLs(urls, maximumCount: maxSavedApplications, requireExistingApplication: true)
    }

    static func normalizedExcludedApplicationURLs(_ urls: [URL]) -> [URL] {
        normalizedApplicationURLs(urls, maximumCount: maxExcludedApplications, requireExistingApplication: false)
    }

    static func decodeNormalizedSavedApplicationURLs(
        from values: inout UnkeyedDecodingContainer
    ) throws -> [URL] {
        try decodeNormalizedApplicationURLs(
            from: &values,
            maximumCount: maxSavedApplications,
            requireExistingApplication: true
        )
    }

    static func decodeNormalizedExcludedApplicationURLs(
        from values: inout UnkeyedDecodingContainer
    ) throws -> [URL] {
        try decodeNormalizedApplicationURLs(
            from: &values,
            maximumCount: maxExcludedApplications,
            requireExistingApplication: false
        )
    }

    mutating func seedDefaultFolderApplications() {
        let excludedIdentities = Set(
            Self.normalizedExcludedApplicationURLs(excludedApplicationURLs)
                .compactMap(Self.stableIdentity(for:))
        )
        let unhiddenSeeds = Self.defaultFolderApplicationURLs.filter {
            Self.stableIdentity(for: $0).map { !excludedIdentities.contains($0) } ?? true
        }
        savedApplicationURLs = Self.normalizedSavedApplicationURLs(
            unhiddenSeeds + savedApplicationURLs
        )
    }

    mutating func remember(_ applicationURL: URL) -> Bool {
        guard let normalizedURL = Self.normalizedSavedApplicationURLs([applicationURL]).first,
              let identity = Self.stableIdentity(for: normalizedURL) else { return false }
        var excludedURLs = Self.normalizedExcludedApplicationURLs(excludedApplicationURLs)
        excludedURLs.removeAll { Self.stableIdentity(for: $0) == identity }
        var savedURLs = Self.normalizedSavedApplicationURLs(savedApplicationURLs)
        savedURLs.removeAll { Self.stableIdentity(for: $0) == identity }
        savedURLs.insert(normalizedURL, at: 0)
        savedApplicationURLs = Array(savedURLs.prefix(Self.maxSavedApplications))
        excludedApplicationURLs = excludedURLs
        return true
    }

    mutating func remove(_ applicationURLs: [URL]) -> Bool {
        var excludedURLs = Self.normalizedExcludedApplicationURLs(excludedApplicationURLs)
        var savedURLs = Array(savedApplicationURLs.prefix(Self.maxSavedApplications))
        var didRemove = false
        for applicationURL in applicationURLs {
            guard let normalizedURL = Self.normalizedApplicationURL(applicationURL),
                  let identity = Self.stableIdentity(for: normalizedURL) else { continue }
            didRemove = true
            excludedURLs.removeAll { Self.stableIdentity(for: $0) == identity }
            excludedURLs.insert(normalizedURL, at: 0)
            if excludedURLs.count > Self.maxExcludedApplications {
                excludedURLs.removeLast(excludedURLs.count - Self.maxExcludedApplications)
            }
            savedURLs.removeAll { Self.stableIdentity(for: $0) == identity }
        }
        guard didRemove else { return false }
        savedApplicationURLs = savedURLs
        excludedApplicationURLs = excludedURLs
        return true
    }

    mutating func restore(_ applicationURLs: [URL]) -> Bool {
        let identities = Set(applicationURLs.compactMap(Self.stableIdentity(for:)))
        let remaining = excludedApplicationURLs.filter {
            Self.stableIdentity(for: $0).map { !identities.contains($0) } ?? true
        }
        guard remaining.count != excludedApplicationURLs.count else { return false }
        excludedApplicationURLs = remaining

        let restoredSeedURLs = Self.defaultFolderApplicationURLs.filter {
            Self.stableIdentity(for: $0).map(identities.contains) ?? false
        }
        if !restoredSeedURLs.isEmpty {
            savedApplicationURLs = Self.normalizedSavedApplicationURLs(
                savedApplicationURLs + restoredSeedURLs
            )
        }
        return true
    }

    private static func normalizedApplicationURLs(
        _ urls: [URL],
        maximumCount: Int,
        requireExistingApplication: Bool
    ) -> [URL] {
        var normalizedURLs = [URL]()
        var seenIdentities = Set<String>()
        for url in urls {
            if appendNormalizedApplicationURL(
                url,
                to: &normalizedURLs,
                seenIdentities: &seenIdentities,
                maximumCount: maximumCount,
                requireExistingApplication: requireExistingApplication
            ) {
                break
            }
        }
        return normalizedURLs
    }

    private static func decodeNormalizedApplicationURLs(
        from values: inout UnkeyedDecodingContainer,
        maximumCount: Int,
        requireExistingApplication: Bool
    ) throws -> [URL] {
        var normalizedURLs = [URL]()
        var seenIdentities = Set<String>()
        let maximumDecodedEntries = maximumCount * 4
        var decodedEntryCount = 0
        while !values.isAtEnd, decodedEntryCount < maximumDecodedEntries {
            decodedEntryCount += 1
            let url = try values.decode(URL.self)
            if appendNormalizedApplicationURL(
                url,
                to: &normalizedURLs,
                seenIdentities: &seenIdentities,
                maximumCount: maximumCount,
                requireExistingApplication: requireExistingApplication
            ) {
                break
            }
        }
        return normalizedURLs
    }

    private static func appendNormalizedApplicationURL(
        _ url: URL,
        to normalizedURLs: inout [URL],
        seenIdentities: inout Set<String>,
        maximumCount: Int,
        requireExistingApplication: Bool
    ) -> Bool {
        guard let normalizedURL = normalizedApplicationURL(url) else { return false }
        if requireExistingApplication {
            var executableIsDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: normalizedURL.path),
                  let bundle = Bundle(url: normalizedURL),
                  let executableURL = bundle.executableURL,
                  FileManager.default.fileExists(
                      atPath: executableURL.path,
                      isDirectory: &executableIsDirectory
                  ),
                  !executableIsDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: executableURL.path) else { return false }
        }
        guard seenIdentities.insert(normalizedURL.path).inserted else { return false }
        normalizedURLs.append(normalizedURL)
        return normalizedURLs.count >= maximumCount
    }
}
