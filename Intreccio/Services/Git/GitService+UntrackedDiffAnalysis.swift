import Foundation
extension GitService {
    func beginUntrackedDiffAnalysisRefresh(for repository: URL) {
        untrackedDiffAnalysisCacheRepository = repository.standardizedFileURL
        untrackedDiffAnalysisCache.invalidateAll()
    }
    func untrackedFileAnalysis(
        repository: URL,
        path: String,
        maximumBytes: Int64,
        validateCached: Bool,
        verifyFreshContent: Bool = true,
        requiresContent: Bool = false
    ) throws -> UntrackedFileAnalysis? {
        try untrackedFileAnalysis(
            repository: repository,
            path: GitPath(path),
            maximumBytes: maximumBytes,
            validateCached: validateCached,
            verifyFreshContent: verifyFreshContent,
            requiresContent: requiresContent
        )
    }

    func untrackedFileAnalysis(
        repository: URL,
        path: GitPath,
        maximumBytes: Int64,
        validateCached: Bool,
        verifyFreshContent: Bool = true,
        requiresContent: Bool = false
    ) throws -> UntrackedFileAnalysis? {
        guard maximumBytes >= 0, maximumBytes <= Int64(Int.max) else { return nil }
        let repositoryKey = repository.standardizedFileURL
        if untrackedDiffAnalysisCacheRepository != repositoryKey {
            untrackedDiffAnalysisCacheRepository = repositoryKey
            untrackedDiffAnalysisCache.invalidateAll()
        }

        if let cached = untrackedDiffAnalysisCache.value(for: path) {
            let fitsRequestedBudget = cached.fingerprint.byteCount <= maximumBytes
            let hasUsableContent = !requiresContent
                || !fitsRequestedBudget
                || cached.kind != .text
                || cached.content != nil
            let isUsable = cached.isComplete || !fitsRequestedBudget
            if isUsable, hasUsableContent {
                if !validateCached {
                    try Task.checkCancellation()
                    return cached
                }
                do {
                    guard try SyntheticUntrackedDiff.validateCachedAnalysis(
                        repository: repository,
                        relativePath: path,
                        analysis: cached,
                        verifyContent: fitsRequestedBudget
                    ) else {
                        untrackedDiffAnalysisCache.invalidate(path: path)
                        return try untrackedFileAnalysis(
                            repository: repository,
                            path: path,
                            maximumBytes: maximumBytes,
                            validateCached: validateCached,
                            verifyFreshContent: verifyFreshContent,
                            requiresContent: requiresContent
                        )
                    }
                    try Task.checkCancellation()
                    return cached
                } catch {
                    untrackedDiffAnalysisCache.invalidate(path: path)
                    throw error
                }
            }
            untrackedDiffAnalysisCache.invalidate(path: path)
        }

        let analysis = try SyntheticUntrackedDiff.analyze(
            repository: repository,
            relativePath: path,
            maximumBytes: Int(maximumBytes),
            maximumLines: DiffLimits.render.maximumLines,
            verifyContent: verifyFreshContent
        )
        try Task.checkCancellation()
        untrackedDiffAnalysisCache.store(analysis, for: path)
        return analysis
    }
}
