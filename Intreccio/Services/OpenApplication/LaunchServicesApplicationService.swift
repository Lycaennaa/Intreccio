import AppKit
import Foundation

struct ValidatedOpenApplication: Equatable, Sendable {
    let url: URL
    let referenceURL: URL
    let resourceID: String
}
enum OpenApplicationTarget: Equatable, Sendable {
    case defaultApplication
    case explicit(ValidatedOpenApplication)
}
struct ValidatedOpenApplicationCandidate: Equatable, Sendable {
    let url: URL
    let application: ValidatedOpenApplication
}

@MainActor
final class LaunchServicesApplicationService {
    static let shared = LaunchServicesApplicationService()
    private let applicationURLsForOpening: (URL) -> [URL]

    init(applicationURLsForOpening: @escaping (URL) -> [URL] = {
        NSWorkspace.shared.urlsForApplications(toOpen: $0)
    }) {
        self.applicationURLsForOpening = applicationURLsForOpening
    }

    func fileReferenceURL(for url: URL, expectedResourceID: String? = nil) -> URL? {
        guard let resourceID = expectedResourceID ?? ResourceIdentity.read(from: url),
              ResourceIdentity.read(from: url) == resourceID,
              let referenceURL = (url as NSURL).fileReferenceURL() as URL?,
              ResourceIdentity.read(from: referenceURL) == resourceID else { return nil }
        return referenceURL
    }

    func validatedFileReferenceURLs(
        for urls: [URL],
        expectedResourceIDs: [String]
    ) -> [URL]? {
        guard !urls.isEmpty, urls.count == expectedResourceIDs.count else { return nil }
        let referenceURLs = zip(urls, expectedResourceIDs).compactMap { url, resourceID in
            fileReferenceURL(for: url, expectedResourceID: resourceID)
        }
        guard referenceURLs.count == urls.count else { return nil }
        return referenceURLs
    }

    func validatedApplication(at applicationURL: URL) -> ValidatedOpenApplication? {
        guard let normalizedURL = PersistedOpenApplicationList.normalizedApplicationURL(applicationURL),
              isValidApplicationBundle(at: normalizedURL),
              let resourceID = ResourceIdentity.read(from: normalizedURL),
              let referenceURL = fileReferenceURL(
                  for: normalizedURL,
                  expectedResourceID: resourceID
              ) else { return nil }
        return ValidatedOpenApplication(
            url: normalizedURL,
            referenceURL: referenceURL,
            resourceID: resourceID
        )
    }

    func validatedApplication(_ application: ValidatedOpenApplication) -> ValidatedOpenApplication? {
        guard let currentApplication = validatedApplication(at: application.url),
              currentApplication.url == application.url,
              currentApplication.resourceID == application.resourceID,
              ResourceIdentity.read(from: application.referenceURL) == application.resourceID else {
            return nil
        }
        return application
    }

    func isValidApplication(_ applicationURL: URL) -> Bool {
        validatedApplication(at: applicationURL) != nil
    }

    private func isValidApplicationBundle(at normalizedURL: URL) -> Bool {
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
        return true
    }

    func applicationName(for applicationURL: URL) -> String {
        let bundle = Bundle(url: applicationURL)
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle?.object(forInfoDictionaryKey: key) as? String, !name.isEmpty {
                return name
            }
        }
        return applicationURL.deletingPathExtension().lastPathComponent
    }

    func open(
        _ fileURLs: [URL],
        withApplicationAt applicationReferenceURL: URL,
        onError: @escaping @MainActor (String) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.open(
            fileURLs,
            withApplicationAt: applicationReferenceURL,
            configuration: configuration
        ) { _, error in
            guard let error else { return }
            let description = error.localizedDescription
            Task { @MainActor in onError(description) }
        }
    }

    func open(_ fileURL: URL) -> Bool {
        NSWorkspace.shared.open(fileURL)
    }
    func applications(
        for url: URL,
        applicationList: PersistedOpenApplicationList
    ) -> [URL] {
        applicationCandidates(
            for: url,
            applicationList: applicationList
        ).map(\.url)
    }

    func validatedApplications(
        for url: URL,
        applicationList: PersistedOpenApplicationList
    ) -> [ValidatedOpenApplicationCandidate] {
        applicationCandidates(
            for: url,
            applicationList: applicationList
        )
    }

    func applications(
        for urls: [URL],
        applicationList: PersistedOpenApplicationList
    ) -> [URL] {
        applicationCandidates(
            for: urls,
            applicationList: applicationList
        ).map(\.url)
    }

    func validatedApplications(
        for urls: [URL],
        applicationList: PersistedOpenApplicationList
    ) -> [ValidatedOpenApplicationCandidate] {
        applicationCandidates(
            for: urls,
            applicationList: applicationList
        )
    }

    private func applicationCandidates(
        for url: URL,
        applicationList: PersistedOpenApplicationList
    ) -> [ValidatedOpenApplicationCandidate] {
        let inputs = candidateInputs(applicationList)
        let candidates = applicationURLsForOpening(url) + inputs.savedApplications
        return finalizedApplicationCandidates(candidates, excludedPaths: inputs.excludedPaths)
    }

    private func applicationCandidates(
        for urls: [URL],
        applicationList: PersistedOpenApplicationList
    ) -> [ValidatedOpenApplicationCandidate] {
        guard let firstURL = urls.first else { return [] }
        let inputs = candidateInputs(applicationList)
        let firstApplicationURLs = applicationURLsForOpening(firstURL)
        var supportedPaths = Set(
            firstApplicationURLs.compactMap(PersistedOpenApplicationList.stableIdentity(for:))
        )
        for url in urls.dropFirst() {
            let applicationURLs = url == firstURL
                ? firstApplicationURLs
                : applicationURLsForOpening(url)
            let applicationPaths = Set(
                applicationURLs.compactMap(PersistedOpenApplicationList.stableIdentity(for:))
            )
            supportedPaths.formIntersection(applicationPaths)
        }
        let compatibleSavedApplications = inputs.savedApplications.filter { applicationURL in
            guard let identity = PersistedOpenApplicationList.stableIdentity(for: applicationURL) else { return false }
            if PersistedOpenApplicationList.isDefaultFolderApplication(applicationURL) {
                return supportedPaths.contains(identity)
            }
            return urls.count == 1 || supportedPaths.contains(identity)
        }
        let candidates = firstApplicationURLs.filter {
            PersistedOpenApplicationList.stableIdentity(for: $0).map { supportedPaths.contains($0) } ?? false
        } + compatibleSavedApplications
        return finalizedApplicationCandidates(candidates, excludedPaths: inputs.excludedPaths)
    }

    private func candidateInputs(
        _ applicationList: PersistedOpenApplicationList
    ) -> (savedApplications: [URL], excludedPaths: Set<String>) {
        (
            PersistedOpenApplicationList.normalizedSavedApplicationURLs(applicationList.savedApplicationURLs),
            Set(
                PersistedOpenApplicationList.normalizedExcludedApplicationURLs(applicationList.excludedApplicationURLs)
                    .compactMap(PersistedOpenApplicationList.stableIdentity(for:))
            )
        )
    }

    private func finalizedApplicationCandidates(
        _ candidates: [URL],
        excludedPaths: Set<String>
    ) -> [ValidatedOpenApplicationCandidate] {
        var seenIdentities = Set<String>()
        return candidates
            .compactMap { candidate in
                guard let identity = PersistedOpenApplicationList.stableIdentity(for: candidate),
                      let application = validatedApplication(at: candidate),
                      !excludedPaths.contains(identity),
                      seenIdentities.insert(identity).inserted else { return nil }
                return ValidatedOpenApplicationCandidate(url: candidate, application: application)
            }
            .sorted { left, right in
                let nameOrder = applicationName(for: left.url).localizedStandardCompare(applicationName(for: right.url))
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return left.url.path.localizedStandardCompare(right.url.path) == .orderedAscending
            }
    }
}
