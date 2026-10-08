import Foundation
nonisolated struct PersistedQuickOpenFileAssignment: Codable, Sendable, Equatable {
    let repositoryID: UUID
    var paths: [String]
}

nonisolated enum QuickOpenFilePathValidationResult: Sendable, Equatable {
    case valid([String])
    case invalid
    case capacityExceeded
}

nonisolated struct PersistedUIState: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case selectedRepoID
        case mode
        case pinnedRepositoryIDs
        case searchText
        case sidebarWidth
        case changesListWidth
        case windowFrame
        case savedOpenApplicationURLs
        case excludedOpenApplicationURLs
        case diffFontSize
        case showWhitespaceInDiff
        case fileWatchDebounceMilliseconds
        case defaultOpenApplicationURL
        case seededDefaultFolderApplications
        case quickOpenFileAssignments

    }
    private enum QuickOpenFileAssignmentCodingKeys: String, CodingKey {
        case repositoryID
        case paths
    }

    /// Frames below this size are treated as corrupt (e.g. recorded mid-teardown)
    /// and dropped instead of collapsing the restored window.
    static let minimumValidWindowFrameSize = CGSize(width: 400, height: 300)

    static func sanitizedWindowFrame(_ frame: String?) -> String? {
        guard let frame else { return nil }
        let rect = NSRectFromString(frame)
        guard rect.size.width >= minimumValidWindowFrameSize.width,
              rect.size.height >= minimumValidWindowFrameSize.height else { return nil }
        return frame
    }

    static let maxQuickOpenFilesPerRepository = 32
    static let maxQuickOpenFileAssignments = 1_000
    static let maxQuickOpenFilePathBytes = 4 * 1_024
    static let maxQuickOpenFileBytes = 1 * 1_024 * 1_024

    static func normalizedQuickOpenFilePaths(_ paths: [String]) -> [String] {
        normalizedQuickOpenFilePaths(paths, maximumBytes: maxQuickOpenFileBytes).paths
    }
    static func validatedQuickOpenFilePathsForMutation(
        _ paths: [String]
    ) -> QuickOpenFilePathValidationResult {
        var seen = Set<String>()
        var validatedPaths = [String]()
        validatedPaths.reserveCapacity(min(paths.count, maxQuickOpenFilesPerRepository))
        for path in paths {
            guard isValidQuickOpenFilePath(path) else { return .invalid }
            guard seen.insert(path).inserted else { continue }
            guard validatedPaths.count < maxQuickOpenFilesPerRepository else {
                return .capacityExceeded
            }
            validatedPaths.append(path)
        }
        return .valid(validatedPaths)
    }

    static func normalizedQuickOpenFileAssignments(
        _ assignments: [PersistedQuickOpenFileAssignment]
    ) -> [PersistedQuickOpenFileAssignment] {
        var seenRepositoryIDs = Set<UUID>()
        var normalizedAssignments = [PersistedQuickOpenFileAssignment]()
        var remainingBytes = maxQuickOpenFileBytes
        normalizedAssignments.reserveCapacity(min(assignments.count, maxQuickOpenFileAssignments))

        for assignment in assignments {
            let normalizedPaths = normalizedQuickOpenFilePaths(
                assignment.paths,
                maximumBytes: remainingBytes
            )
            guard !normalizedPaths.paths.isEmpty,
                  seenRepositoryIDs.insert(assignment.repositoryID).inserted else { continue }
            normalizedAssignments.append(
                PersistedQuickOpenFileAssignment(
                    repositoryID: assignment.repositoryID,
                    paths: normalizedPaths.paths
                )
            )
            remainingBytes -= normalizedPaths.byteCount
            if normalizedAssignments.count == maxQuickOpenFileAssignments { break }
        }
        return normalizedAssignments
    }

    private static func normalizedQuickOpenFilePaths(
        _ paths: [String],
        maximumBytes: Int
    ) -> (paths: [String], byteCount: Int) {
        var seen = Set<String>()
        var normalizedPaths = [String]()
        var byteCount = 0
        normalizedPaths.reserveCapacity(min(paths.count, maxQuickOpenFilesPerRepository))
        for path in paths {
            let pathByteCount = path.utf8.count
            guard normalizedPaths.count < maxQuickOpenFilesPerRepository,
                  pathByteCount <= maxQuickOpenFilePathBytes,
                  byteCount <= maximumBytes,
                  pathByteCount <= maximumBytes - byteCount,
                  isValidQuickOpenFilePath(path),
                  seen.insert(path).inserted else { continue }
            normalizedPaths.append(path)
            byteCount += pathByteCount
        }
        return (normalizedPaths, byteCount)
    }

    private static func decodeQuickOpenFileAssignments(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [PersistedQuickOpenFileAssignment] {
        guard container.contains(.quickOpenFileAssignments),
              try !container.decodeNil(forKey: .quickOpenFileAssignments) else { return [] }
        var values = try container.nestedUnkeyedContainer(forKey: .quickOpenFileAssignments)
        var assignments = [PersistedQuickOpenFileAssignment]()
        let maximumDecodedEntries = maxQuickOpenFileAssignments * 4
        if let count = values.count {
            assignments.reserveCapacity(min(count, maxQuickOpenFileAssignments))
        }
        var decodedEntryCount = 0
        while !values.isAtEnd, decodedEntryCount < maximumDecodedEntries {
            decodedEntryCount += 1
            assignments.append(try decodeQuickOpenFileAssignment(from: &values))
        }
        return normalizedQuickOpenFileAssignments(assignments)
    }

    private static func decodeQuickOpenFileAssignment(
        from values: inout UnkeyedDecodingContainer
    ) throws -> PersistedQuickOpenFileAssignment {
        let container = try values.nestedContainer(keyedBy: QuickOpenFileAssignmentCodingKeys.self)
        let repositoryID = try container.decode(UUID.self, forKey: .repositoryID)
        var pathValues = try container.nestedUnkeyedContainer(forKey: .paths)
        var paths = [String]()
        paths.reserveCapacity(maxQuickOpenFilesPerRepository)
        let maximumDecodedPaths = maxQuickOpenFilesPerRepository * 4
        var decodedPathCount = 0
        while !pathValues.isAtEnd, decodedPathCount < maximumDecodedPaths {
            decodedPathCount += 1
            paths.append(try pathValues.decode(String.self))
        }
        return PersistedQuickOpenFileAssignment(repositoryID: repositoryID, paths: paths)
    }

    private static func isValidQuickOpenFilePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= maxQuickOpenFilePathBytes,
              RepositoryPathPolicy.relativePathComponents(path) != nil else { return false }
        return true
    }

    var selectedRepoID: UUID?
    var mode: AppMode = .changes
    var pinnedRepositoryIDs: Set<UUID> = []
    var searchText = ""
    var sidebarWidth: Double = 240
    var changesListWidth: Double?
    var windowFrame: String?
    var savedOpenApplicationURLs: [URL] = []
    var excludedOpenApplicationURLs: [URL] = []
    var diffFontSize: Double = 12
    var showWhitespaceInDiff = false
    var fileWatchDebounceMilliseconds = 500
    var defaultOpenApplicationURL: URL?
    var seededDefaultFolderApplications = false
    var quickOpenFileAssignments: [PersistedQuickOpenFileAssignment] = []

    var openApplicationList: PersistedOpenApplicationList {
        get {
            PersistedOpenApplicationList(
                savedApplicationURLs: savedOpenApplicationURLs,
                excludedApplicationURLs: excludedOpenApplicationURLs
            )
        }
        set {
            savedOpenApplicationURLs = newValue.savedApplicationURLs
            excludedOpenApplicationURLs = newValue.excludedApplicationURLs
        }
    }

    init(
        selectedRepoID: UUID? = nil,
        mode: AppMode = .changes,
        pinnedRepositoryIDs: Set<UUID> = [],
        searchText: String = "",
        sidebarWidth: Double = 240,
        changesListWidth: Double? = nil,
        windowFrame: String? = nil,
        savedOpenApplicationURLs: [URL] = [],
        excludedOpenApplicationURLs: [URL] = [],
        diffFontSize: Double = 12,
        showWhitespaceInDiff: Bool = false,
        fileWatchDebounceMilliseconds: Int = 500,
        defaultOpenApplicationURL: URL? = nil,
        quickOpenFileAssignments: [PersistedQuickOpenFileAssignment] = []

    ) {
        self.selectedRepoID = selectedRepoID
        self.mode = mode
        self.pinnedRepositoryIDs = pinnedRepositoryIDs
        self.searchText = searchText
        self.sidebarWidth = sidebarWidth
        self.changesListWidth = changesListWidth
        self.windowFrame = windowFrame
        self.savedOpenApplicationURLs = savedOpenApplicationURLs
        self.excludedOpenApplicationURLs = excludedOpenApplicationURLs
        self.diffFontSize = diffFontSize
        self.showWhitespaceInDiff = showWhitespaceInDiff
        self.fileWatchDebounceMilliseconds = fileWatchDebounceMilliseconds
        self.defaultOpenApplicationURL = defaultOpenApplicationURL
        self.quickOpenFileAssignments = Self.normalizedQuickOpenFileAssignments(quickOpenFileAssignments)

    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedRepoID = try container.decodeIfPresent(UUID.self, forKey: .selectedRepoID)
        mode = try container.decodeIfPresent(AppMode.self, forKey: .mode) ?? .changes
        pinnedRepositoryIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .pinnedRepositoryIDs) ?? []
        searchText = try container.decodeIfPresent(String.self, forKey: .searchText) ?? ""
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 240
        changesListWidth = try container.decodeIfPresent(Double.self, forKey: .changesListWidth)
        windowFrame = Self.sanitizedWindowFrame(try container.decodeIfPresent(String.self, forKey: .windowFrame))
        diffFontSize = min(max(try container.decodeIfPresent(Double.self, forKey: .diffFontSize) ?? 12, 9), 24)
        showWhitespaceInDiff = try container.decodeIfPresent(Bool.self, forKey: .showWhitespaceInDiff) ?? false
        fileWatchDebounceMilliseconds = min(max(try container.decodeIfPresent(Int.self, forKey: .fileWatchDebounceMilliseconds) ?? 500, 50), 2_000)
        if let url = try container.decodeIfPresent(URL.self, forKey: .defaultOpenApplicationURL) {
            defaultOpenApplicationURL = PersistedOpenApplicationList.normalizedSavedApplicationURLs([url]).first
        }
        seededDefaultFolderApplications = try container.decodeIfPresent(Bool.self, forKey: .seededDefaultFolderApplications) ?? false
        quickOpenFileAssignments = try Self.decodeQuickOpenFileAssignments(from: container)
        if container.contains(.savedOpenApplicationURLs),
           try !container.decodeNil(forKey: .savedOpenApplicationURLs) {
            var values = try container.nestedUnkeyedContainer(forKey: .savedOpenApplicationURLs)
            savedOpenApplicationURLs = try PersistedOpenApplicationList.decodeNormalizedSavedApplicationURLs(from: &values)
        }
        if container.contains(.excludedOpenApplicationURLs),
           try !container.decodeNil(forKey: .excludedOpenApplicationURLs) {
            var values = try container.nestedUnkeyedContainer(forKey: .excludedOpenApplicationURLs)
            excludedOpenApplicationURLs = try PersistedOpenApplicationList.decodeNormalizedExcludedApplicationURLs(from: &values)
        }

    }
}

nonisolated enum PersistedUIStateBudgetError: Error, Sendable, CustomStringConvertible {
    case encodedSizeExceeded

    var description: String {
        "encoded UI state size exceeds \(PersistedUIStateBudget.maxEncodedBytes) bytes"
    }
}

nonisolated enum PersistedUIStateBudget {
    static let maxEncodedBytes = 4 * 1024 * 1024

    static func validateEncodedSize(_ byteCount: Int) throws {
        guard byteCount <= maxEncodedBytes else {
            throw PersistedUIStateBudgetError.encodedSizeExceeded
        }
    }
}
