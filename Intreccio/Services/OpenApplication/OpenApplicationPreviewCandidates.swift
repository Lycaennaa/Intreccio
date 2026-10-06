import Foundation

@MainActor
final class OpenApplicationPreviewCandidates {
    private let applicationService: LaunchServicesApplicationService
    private var cachedFolderApplications: [URL] = []
    private(set) var cachedFileApplications: [URL] = []
    private var folderCacheKey = ""
    private var fileCacheKey = ""
    private var folderCacheTime = Date.distantPast
    private var fileCacheTime = Date.distantPast
    private var sampleFilesDirectory: URL?
    private let cacheLifetime: TimeInterval = 5

    init(applicationService: LaunchServicesApplicationService = .shared) {
        self.applicationService = applicationService
    }

    func invalidate() {
        folderCacheKey = ""
        folderCacheTime = .distantPast
        fileCacheKey = ""
        fileCacheTime = .distantPast
    }

    func folderApplications(
        sourceID: UUID,
        path: String,
        applicationList: PersistedOpenApplicationList,
        force: Bool = false
    ) -> [URL] {
        let key = "\(sourceID.uuidString)|\(path)|\(listSignature(applicationList))"
        if !force, key == folderCacheKey,
           Date().timeIntervalSince(folderCacheTime) < cacheLifetime {
            return cachedFolderApplications
        }
        folderCacheKey = key
        folderCacheTime = Date()
        cachedFolderApplications = applicationService.applications(
            for: URL(fileURLWithPath: path, isDirectory: true),
            applicationList: applicationList
        )
        return cachedFolderApplications
    }

    func fileApplications(
        group: Int,
        extensions: [String],
        applicationList: PersistedOpenApplicationList,
        force: Bool = false
    ) -> [URL]? {
        let key = "\(group)|\(listSignature(applicationList))"
        if !force, key == fileCacheKey,
           Date().timeIntervalSince(fileCacheTime) < cacheLifetime {
            return cachedFileApplications
        }
        guard let candidates = groupedFileCandidates(extensions, applicationList: applicationList) else { return nil }
        fileCacheKey = key
        fileCacheTime = Date()
        cachedFileApplications = candidates
        return candidates
    }

    private func listSignature(_ applicationList: PersistedOpenApplicationList) -> String {
        (applicationList.savedApplicationURLs.compactMap(PersistedOpenApplicationList.stableIdentity(for:))
            + ["|"]
            + applicationList.excludedApplicationURLs.compactMap(PersistedOpenApplicationList.stableIdentity(for:)))
            .joined(separator: "\u{0}")
    }

    private func groupedFileCandidates(
        _ extensions: [String],
        applicationList: PersistedOpenApplicationList
    ) -> [URL]? {
        var identities = Set<String>()
        var ordered: [URL] = []
        guard let directory = ensureSampleFilesDirectory() else { return nil }
        for ext in extensions {
            let sampleURL = directory.appendingPathComponent("sample.\(ext)")
            if !FileManager.default.fileExists(atPath: sampleURL.path) {
                guard FileManager.default.createFile(atPath: sampleURL.path, contents: Data()) else { continue }
            }
            for applicationURL in applicationService.applications(
                for: [sampleURL],
                applicationList: applicationList
            ) {
                guard let identity = PersistedOpenApplicationList.stableIdentity(for: applicationURL),
                      identities.insert(identity).inserted else { continue }
                ordered.append(applicationURL)
            }
        }
        return ordered.sorted {
            applicationService.applicationName(for: $0).localizedStandardCompare(
                applicationService.applicationName(for: $1)
            ) == .orderedAscending
        }
    }

    private func ensureSampleFilesDirectory() -> URL? {
        if let directory = sampleFilesDirectory {
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return directory
            }
            sampleFilesDirectory = nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntreccioSettingsPreview", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
        }
        sampleFilesDirectory = directory
        return directory
    }
}