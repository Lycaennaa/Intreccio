import Darwin
import Foundation

nonisolated struct UntrackedDiffStats {
    let fingerprints: [String: FileContentFingerprint]
    let stats: DiffLineStats
    let sccSourceFiles: [SCCSourceFile]
    let sccSourceFilesComplete: Bool
    let hasNonCodeFiles: Bool
    let hasCodeFiles: Bool
}

extension GitService {
    static let untrackedStatsMaximumBytesPerFile: Int64 = 2 * 1_024 * 1_024

    func untrackedDiffStatsForDiffStats(
        repository: URL,
        changes: [FileChange],
        validateCached: Bool
    ) throws -> UntrackedDiffStats? {
        var fingerprints: [String: FileContentFingerprint] = [:]
        var additions = 0
        var deletions = 0
        var sccSourceFiles: [SCCSourceFile] = []
        var sccSourceFilesComplete = true
        var hasNonCodeFiles = false
        var hasCodeFiles = false
        var sccSourceByteCount = 0
        for change in changes {
            guard change.isGitAddressable else { continue }
            hasNonCodeFiles = hasNonCodeFiles || SourceCodeFileClassifier.sccFileName(for: change.gitPath) == nil
            try Task.checkCancellation()
            let analysis: UntrackedFileAnalysis?
            do {
                analysis = try untrackedFileAnalysis(
                    repository: repository,
                    path: change.gitPath,
                    maximumBytes: Self.untrackedStatsMaximumBytesPerFile,
                    validateCached: validateCached,
                    verifyFreshContent: validateCached,
                    requiresContent: SourceCodeFileClassifier.sccFileName(for: change.gitPath) != nil
                )
            } catch let error as SyntheticUntrackedDiffError {
                switch error {
                case .unsupportedFile,
                     .openFailed(_, ELOOP),
                     .openFailed(_, ENOENT),
                     .openFailed(_, ENOTDIR):
                    continue
                default:
                    throw error
                }
            }
            guard let analysis else { continue }
            fingerprints[change.path] = analysis.fingerprint
            guard let stats = analysis.lineStats else {
                hasNonCodeFiles = true
                continue
            }
            hasCodeFiles = hasCodeFiles || SourceCodeFileClassifier.sccFileName(for: change.gitPath) != nil
            guard Self.add(stats.additions, to: &additions),
                  Self.add(stats.deletions, to: &deletions) else { return nil }
            if let fileName = SourceCodeFileClassifier.sccFileName(for: change.gitPath),
               sccSourceFilesComplete {
                guard let content = analysis.content else {
                    sccSourceFilesComplete = false
                    continue
                }
                let result = sccSourceByteCount.addingReportingOverflow(content.count)
                guard !result.overflow, result.partialValue <= SCCLineCounter.maximumInputBytes else {
                    sccSourceFilesComplete = false
                    continue
                }
                sccSourceFiles.append(SCCSourceFile(fileName: fileName, contents: content))
                sccSourceByteCount = result.partialValue
            }
        }
        return UntrackedDiffStats(
            fingerprints: fingerprints,
            stats: DiffLineStats(additions: additions, deletions: deletions),
            sccSourceFiles: sccSourceFiles,
            sccSourceFilesComplete: sccSourceFilesComplete,
            hasNonCodeFiles: hasNonCodeFiles,
            hasCodeFiles: hasCodeFiles
        )
    }

    static func add(_ value: Int, to total: inout Int) -> Bool {
        let result = total.addingReportingOverflow(value)
        guard !result.overflow else { return false }
        total = result.partialValue
        return true
    }
}
