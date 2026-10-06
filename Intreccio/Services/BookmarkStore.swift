import Foundation

nonisolated struct BookmarkResolution: Sendable {
    let url: URL
    let refreshedData: Data?
    let isAccessingSecurityScope: Bool
}

nonisolated enum BookmarkStoreError: Error, Sendable, CustomStringConvertible {
    case creationFailed(String)
    case resolutionFailed(String)

    var description: String {
        switch self {
        case .creationFailed(let message): "Could not create bookmark: \(message)"
        case .resolutionFailed(let message): "Could not resolve bookmark: \(message)"
        }
    }
}

actor BookmarkStore {
    func create(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: [.fileResourceIdentifierKey],
                relativeTo: nil
            )
        } catch {
            throw BookmarkStoreError.creationFailed(error.localizedDescription)
        }
    }

    func resolve(_ data: Data) throws -> BookmarkResolution {
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let accessing = url.startAccessingSecurityScopedResource()
            let refreshed: Data?
            do {
                refreshed = stale ? try create(for: url) : nil
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                throw error
            }
            return BookmarkResolution(url: url, refreshedData: refreshed, isAccessingSecurityScope: accessing)
        } catch {
            throw BookmarkStoreError.resolutionFailed(error.localizedDescription)
        }
    }

    func stopAccessing(_ resolution: BookmarkResolution) {
        if resolution.isAccessingSecurityScope {
            resolution.url.stopAccessingSecurityScopedResource()
        }
    }
}
