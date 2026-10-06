import CryptoKit
import Foundation

nonisolated struct SCCSourceFile: Sendable, Hashable {
    let fileName: String
    let contents: Data
    let baselineContents: Data?

    init(fileName: String, contents: Data, baselineContents: Data? = nil) {
        self.fileName = fileName
        self.contents = contents
        self.baselineContents = baselineContents
    }
}

nonisolated struct SCCLineCounts: Sendable, Equatable {
    let additions: Int
    let deletions: Int
    let hasNonCodeFiles: Bool
    let hasCodeFiles: Bool
}

nonisolated protocol SLOCCounter: Sendable {
    func count(
        additions: [SCCSourceFile],
        deletions: [SCCSourceFile]
    ) async throws -> SCCLineCounts?
}

private final class SCCBundleMarker: NSObject {}

actor SCCLineCounter: SLOCCounter {
    nonisolated static let maximumInputBytes = 2 * 1_024 * 1_024

    private let runner: ProcessRunner
    private static let cacheCapacity = 8

    private var cache: [CacheKey: SCCLineCounts] = [:]
    private var cacheOrder: [CacheKey] = []

    init(executableURL: URL) {
        runner = ProcessRunner(executable: executableURL.path)
    }

    nonisolated static func bundled() -> SCCLineCounter? {
        var bundles = [Bundle.main, Bundle(for: SCCBundleMarker.self)]
        let siblingAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Intreccio.app", isDirectory: true)
        if let siblingApp = Bundle(url: siblingAppURL) {
            bundles.append(siblingApp)
        }
        guard let executableURL = bundles.lazy.compactMap({ bundle in
            bundle.url(forResource: "scc", withExtension: nil)
        }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return nil
        }
        return SCCLineCounter(executableURL: executableURL)
    }

    func count(
        additions: [SCCSourceFile],
        deletions: [SCCSourceFile]
    ) async throws -> SCCLineCounts? {
        guard totalByteCount(additions, includingBaseline: true)
                + totalByteCount(deletions, includingBaseline: true) <= Self.maximumInputBytes else {
            return nil
        }
        try Task.checkCancellation()
        let key = Self.cacheKey(additions: additions, deletions: deletions)
        if let cached = cache[key] {
            return cached
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.lycaennaa.intreccio.scc.\(UUID().uuidString)", isDirectory: true)
        let additionsDirectory = root.appendingPathComponent("additions", isDirectory: true)
        let additionsBaselineDirectory = root.appendingPathComponent("additions-baseline", isDirectory: true)
        let deletionsDirectory = root.appendingPathComponent("deletions", isDirectory: true)
        let deletionsBaselineDirectory = root.appendingPathComponent("deletions-baseline", isDirectory: true)
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: root) }
        do {
            try fileManager.createDirectory(at: additionsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: additionsBaselineDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: deletionsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: deletionsBaselineDirectory, withIntermediateDirectories: true)
            try write(additions, to: additionsDirectory, prefix: "added", baseline: false)
            try write(additions, to: additionsBaselineDirectory, prefix: "added", baseline: true)
            try write(deletions, to: deletionsDirectory, prefix: "deleted", baseline: false)
            try write(deletions, to: deletionsBaselineDirectory, prefix: "deleted", baseline: true)
        } catch {
            return nil
        }

        async let additionCount = codeCount(in: additionsDirectory)
        async let additionBaselineCount = codeCount(in: additionsBaselineDirectory)
        async let deletionCount = codeCount(in: deletionsDirectory)
        async let deletionBaselineCount = codeCount(in: deletionsBaselineDirectory)
        guard let additions = try await additionCount,
              let additionBaseline = try await additionBaselineCount,
              let deletions = try await deletionCount,
              let deletionBaseline = try await deletionBaselineCount else {
            return nil
        }
        let counts = SCCLineCounts(
            additions: max(0, additions.code - additionBaseline.code),
            deletions: max(0, deletions.code - deletionBaseline.code),
            hasNonCodeFiles: additions.hasNonCodeFiles || deletions.hasNonCodeFiles,
            hasCodeFiles: additions.hasCodeFiles || deletions.hasCodeFiles
        )
        cache[key] = counts
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheCapacity, let evicted = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return counts
    }

    nonisolated private static func cacheKey(
        additions: [SCCSourceFile],
        deletions: [SCCSourceFile]
    ) -> CacheKey {
        func digest(_ files: [SCCSourceFile]) -> Data {
            var hasher = SHA256()
            for file in files {
                hasher.update(data: Data(file.fileName.utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: file.contents)
                if let baselineContents = file.baselineContents {
                    hasher.update(data: Data([1]))
                    hasher.update(data: baselineContents)
                } else {
                    hasher.update(data: Data([0]))
                }
                hasher.update(data: Data([0]))
            }
            return Data(hasher.finalize())
        }
        return CacheKey(additions: digest(additions), deletions: digest(deletions))
    }

    private func codeCount(in directory: URL) async throws -> FileCounts? {
        let result: ProcessCommandResult
        do {
            result = try await runner.run(
                arguments: [
                    "--format", "json", "--by-file",
                    "--no-complexity", "--no-size", "--no-cocomo",
                    "--no-gitignore", "--no-gitmodule", "--no-scc-ignore",
                    "--no-gen", "--no-min",
                    directory.path,
                ],
                outputLimit: 256 * 1_024,
                timeout: .seconds(15),
                priority: .normal
            )
        } catch ProcessRunnerError.cancelled {
            throw CancellationError()
        } catch {
            return nil
        }

        guard let summaries = try? JSONDecoder().decode([Summary].self, from: result.standardOutput) else {
            return nil
        }
        var code = 0
        var hasNonCodeFiles = false
        var hasCodeFiles = false
        for summary in summaries {
            for file in summary.files {
                if SourceCodeFileClassifier.isExcludedSCCLanguage(file.language) {
                    hasNonCodeFiles = true
                    continue
                }
                hasCodeFiles = true
                let result = code.addingReportingOverflow(file.code)
                guard !result.overflow else { return nil }
                code = result.partialValue
            }
        }
        return FileCounts(
            code: code,
            hasNonCodeFiles: hasNonCodeFiles,
            hasCodeFiles: hasCodeFiles
        )
    }

    private func totalByteCount(_ files: [SCCSourceFile], includingBaseline: Bool) -> Int {
        files.reduce(0) { total, file in
            total + file.contents.count + (includingBaseline ? file.baselineContents?.count ?? 0 : 0)
        }
    }

    private func write(
        _ files: [SCCSourceFile],
        to directory: URL,
        prefix: String,
        baseline: Bool
    ) throws {
        let fileManager = FileManager.default
        for (index, file) in files.enumerated() {
            let fileDirectory = directory.appendingPathComponent("\(prefix)-\(index)", isDirectory: true)
            try fileManager.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
            let url = fileDirectory.appendingPathComponent(file.fileName)
            let contents = baseline ? file.baselineContents ?? Data() : file.contents
            try contents.write(to: url, options: .atomic)
        }
    }

}

nonisolated private struct CacheKey: Hashable {
    let additions: Data
    let deletions: Data
}

private struct FileCounts {
    let code: Int
    let hasNonCodeFiles: Bool
    let hasCodeFiles: Bool
}

private struct Summary: Decodable {
    let files: [FileSummary]

    enum CodingKeys: String, CodingKey {
        case files = "Files"
    }
}

private struct FileSummary: Decodable {
    let language: String
    let code: Int

    enum CodingKeys: String, CodingKey {
        case language = "Language"
        case code = "Code"
    }
}
