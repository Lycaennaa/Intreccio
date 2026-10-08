import CryptoKit
import Darwin
import Foundation

nonisolated struct JustRecipe: Equatable, Sendable {
    let name: String
}

nonisolated struct JustfileDefinition: Equatable, Sendable {
    let fileURL: URL
    let recipes: [JustRecipe]
    let signature: JustfileSignature
}
nonisolated struct JustfileSignature: Equatable, Sendable {
    let size: Int64
    let modificationDate: Date
    let changeDate: Date
    let fileNumber: UInt64
    let contentDigest: Data
}

nonisolated struct JustfileFileMetadata: Equatable, Sendable {
    let size: Int64
    let modificationDate: Date
    let changeDate: Date
    let fileNumber: UInt64
    let isRegularFile: Bool
}

nonisolated enum JustfileDiscovery: Equatable, Sendable {
    case noJustfile(justInstalled: Bool)
    case justNotInstalled
    case unsupportedJustfile
    case justfileTooLarge
    case invalidJustfile(fileURL: URL?, signature: JustfileSignature?)
    case unreadableJustfile(fileURL: URL, metadata: JustfileFileMetadata?)
    case verificationUnavailable
    case changedDuringDiscovery
    case definition(JustfileDefinition)
}

nonisolated enum JustfileService {
    private static let justfileNames = ["justfile", "Justfile", ".justfile"]
    enum CreationError: LocalizedError {
        case alreadyExists(URL)
        case couldNotCreate(URL)

        var errorDescription: String? {
            switch self {
            case .alreadyExists(let fileURL):
                return "A justfile already exists at \(fileURL.lastPathComponent)."
            case .couldNotCreate(let fileURL):
                return "Could not create a justfile at \(fileURL.path)."
            }
        }
    }

    private static let exampleContents = """
    # Recipes for this repository.
    #
    # Run `just --summary` to see available recipes.

    hello:
        @echo "Hello from just"

    build:
        npm run build
    """

    static func discovery(in repositoryURL: URL) -> JustfileDiscovery {
        discovery(in: repositoryURL, justExecutableURL: justExecutableURL())
    }

    static func discovery(in repositoryURL: URL, justExecutableURL: URL?) -> JustfileDiscovery {
        discovery(in: repositoryURL, justExecutableURL: justExecutableURL, cancellation: nil)
    }

    static func discoveriesAsync(in repositoryURLs: [URL]) async -> [JustfileDiscovery] {
        let cancellation = JustProcessCancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                let justExecutableURL = locateJustExecutable(cancellation: cancellation)
                var discoveries = [JustfileDiscovery]()
                for repositoryURL in repositoryURLs {
                    guard !cancellation.wasCancelled else { break }
                    var result = discovery(
                        in: repositoryURL,
                        justExecutableURL: justExecutableURL,
                        cancellation: cancellation
                    )
                    for attempt in 0..<3 {
                        let isCurrent = isCurrent(result, in: repositoryURL, cancellation: cancellation)
                        guard !cancellation.wasCancelled else { break }
                        if isCurrent { break }
                        guard attempt < 2 else {
                            result = .changedDuringDiscovery
                            break
                        }
                        result = discovery(
                            in: repositoryURL,
                            justExecutableURL: justExecutableURL,
                            cancellation: cancellation
                        )
                    }
                    guard !cancellation.wasCancelled else { break }
                    discoveries.append(result)
                }
                return discoveries
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func discovery(
        in repositoryURL: URL,
        justExecutableURL: URL?,
        cancellation: JustProcessCancellation?
    ) -> JustfileDiscovery {
        guard let fileURL = justfileURL(in: repositoryURL) else {
            return hasJustfile(in: repositoryURL)
                ? .invalidJustfile(fileURL: nil, signature: nil)
                : .noJustfile(justInstalled: justExecutableURL != nil)
        }
        guard let justExecutableURL else { return .justNotInstalled }
        let signature: JustfileSignature
        switch fileSignature(for: fileURL, cancellation: cancellation) {
        case .signature(let value):
            signature = value
        case .unsupported:
            return .unsupportedJustfile
        case .tooLarge:
            return .justfileTooLarge
        case .unreadable(let metadata):
            return .unreadableJustfile(fileURL: fileURL, metadata: metadata)
        case .deferred:
            return .verificationUnavailable
        case .unavailable:
            return .invalidJustfile(fileURL: fileURL, signature: nil)
        }
        guard let summary = recipeSummary(
            using: justExecutableURL,
            in: repositoryURL,
            justfileURL: fileURL,
            cancellation: cancellation
        ) else {
            return .invalidJustfile(fileURL: fileURL, signature: signature)
        }
        let recipes = summary
            .split(whereSeparator: \.isWhitespace)
            .map { JustRecipe(name: String($0)) }
        return .definition(JustfileDefinition(fileURL: fileURL, recipes: recipes, signature: signature))
    }

    private static func recipeSummary(
        using executableURL: URL,
        in repositoryURL: URL,
        justfileURL: URL,
        cancellation: JustProcessCancellation?
    ) -> String? {
        let output = Pipe()
        guard let (outputData, status) = JustProcessRunner.run(
            executableURL: executableURL,
            arguments: ["--summary", "--justfile", justfileURL.path],
            currentDirectoryURL: repositoryURL,
            output: output,
            cancellation: cancellation
        ), status == 0 else { return nil }
        return String(data: outputData, encoding: .utf8)
    }

    static func justExecutableURL() -> URL? {
        locateJustExecutable(cancellation: nil)
    }

    private static func locateJustExecutable(cancellation: JustProcessCancellation?) -> URL? {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.path
        let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let knownDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(homeDirectory)/.cargo/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.nix-profile/bin",
            "/nix/var/nix/profiles/default/bin"
        ]
        var seenDirectories = Set<String>()
        for directory in pathDirectories + knownDirectories where directory.hasPrefix("/") {
            guard seenDirectories.insert(directory).inserted else { continue }
            let executableURL = URL(fileURLWithPath: directory).appendingPathComponent("just")
            if fileManager.isExecutableFile(atPath: executableURL.path) { return executableURL }
        }
        return loginShellJustExecutableURL(cancellation: cancellation)
    }

    private static func loginShellJustExecutableURL(cancellation: JustProcessCancellation?) -> URL? {
        let output = Pipe()
        guard let (outputData, status) = JustProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", "whence -p just"],
            currentDirectoryURL: nil,
            output: output,
            cancellation: cancellation
        ),
              status == 0,
              let outputText = String(data: outputData, encoding: .utf8) else { return nil }
        let fileManager = FileManager.default
        return outputText
            .split(whereSeparator: \.isNewline)
            .reversed()
            .compactMap { path -> URL? in
                guard path.hasPrefix("/") else { return nil }
                let url = URL(fileURLWithPath: String(path))
                return fileManager.isExecutableFile(atPath: url.path) ? url : nil
            }
            .first
    }

    static func commonRecipes(in definitions: [JustfileDefinition]) -> [JustRecipe] {
        guard let first = definitions.first else { return [] }
        var commonNames = Set(first.recipes.map(\.name))
        for definition in definitions.dropFirst() {
            commonNames.formIntersection(Set(definition.recipes.map(\.name)))
        }
        var emittedNames = Set<String>()
        return first.recipes.filter {
            commonNames.contains($0.name) && emittedNames.insert($0.name).inserted
        }
    }

    static func justfileURL(in repositoryURL: URL) -> URL? {
        let fileManager = FileManager.default
        for name in justfileNames {
            let fileURL = repositoryURL.appendingPathComponent(name)
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            return fileURL
        }
        return nil
    }
    static func hasJustfile(in repositoryURL: URL) -> Bool {
        let fileManager = FileManager.default
        return justfileNames.contains { name in
            fileManager.fileExists(
                atPath: repositoryURL.appendingPathComponent(name).path
            )
        }
    }
    static func isCurrent(
        _ definition: JustfileDefinition,
        in repositoryURL: URL,
        cancellation: JustProcessCancellation? = nil
    ) -> Bool {
        guard let fileURL = justfileURL(in: repositoryURL),
              fileURL.standardizedFileURL == definition.fileURL.standardizedFileURL,
              case .signature(let signature) = fileSignature(for: fileURL, cancellation: cancellation) else {
            return false
        }
        return signature == definition.signature
    }
    static func isCurrent(
        _ discovery: JustfileDiscovery,
        in repositoryURL: URL,
        cancellation: JustProcessCancellation? = nil
    ) -> Bool {
        switch discovery {
        case .noJustfile:
            return justfileURL(in: repositoryURL) == nil && !hasJustfile(in: repositoryURL)
        case .justNotInstalled:
            return hasJustfile(in: repositoryURL)
        case .unsupportedJustfile:
            guard let fileURL = justfileURL(in: repositoryURL),
                  let metadata = fileMetadata(for: fileURL) else { return false }
            return !metadata.isRegularFile
        case .justfileTooLarge:
            guard let fileURL = justfileURL(in: repositoryURL),
                  let metadata = fileMetadata(for: fileURL) else { return false }
            return metadata.isRegularFile && metadata.size > maximumJustfileSize
        case .unreadableJustfile(let discoveredURL, let metadata):
            guard let currentURL = justfileURL(in: repositoryURL),
                  currentURL.standardizedFileURL == discoveredURL.standardizedFileURL else { return false }
            guard let metadata else { return true }
            return fileMetadata(for: currentURL) == metadata
        case .invalidJustfile(let discoveredURL, let signature):
            guard hasJustfile(in: repositoryURL) else { return false }
            guard let discoveredURL else {
                return signature == nil && justfileURL(in: repositoryURL) == nil
            }
            guard let signature,
                  let currentURL = justfileURL(in: repositoryURL),
                  currentURL.standardizedFileURL == discoveredURL.standardizedFileURL else { return false }
            guard case .signature(let currentSignature) = fileSignature(
                for: currentURL,
                cancellation: cancellation
            ) else { return false }
            return currentSignature == signature
        case .verificationUnavailable:
            return false
        case .changedDuringDiscovery:
            return false
        case .definition(let definition):
            return isCurrent(definition, in: repositoryURL, cancellation: cancellation)
        }
    }

    static func isCurrentAsync(_ definition: JustfileDefinition, in repositoryURL: URL) async -> Bool {
        let cancellation = JustProcessCancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                isCurrent(definition, in: repositoryURL, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static let maximumJustfileSize = 16 * 1024 * 1024
    private static let fileSignatureQueue = DispatchQueue(
        label: "Intreccio.justfile-signature",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let maximumConcurrentFileSignatureReads = 2
    private static let fileSignatureSlots = DispatchSemaphore(value: maximumConcurrentFileSignatureReads)
    private static let fileSignatureWaiterSlot = DispatchSemaphore(value: 1)
    private static let fileSignatureTimeout: TimeInterval = 2
    private static func fileSignature(
        for fileURL: URL,
        cancellation: JustProcessCancellation? = nil
    ) -> FileSignatureResult {
        guard cancellation?.wasCancelled != true else { return .unavailable }
        if fileSignatureSlots.wait(timeout: .now()) != .success {
            guard fileSignatureWaiterSlot.wait(timeout: .now()) == .success else { return .deferred }
            let acquired = fileSignatureSlots.wait(timeout: .now() + 0.25) == .success
            fileSignatureWaiterSlot.signal()
            guard acquired else { return .deferred }
        }
        let resultBox = FileSignatureResultBox()
        let finished = DispatchSemaphore(value: 0)
        fileSignatureQueue.async {
            let result = computeFileSignature(for: fileURL, cancellation: cancellation)
            resultBox.store(result)
            fileSignatureSlots.signal()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + fileSignatureTimeout) == .success else {
            return .deferred
        }
        return resultBox.result ?? .unavailable
    }

    private static func computeFileSignature(
        for fileURL: URL,
        cancellation: JustProcessCancellation?
    ) -> FileSignatureResult {
        guard cancellation?.wasCancelled != true else { return .unavailable }
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            guard cancellation?.wasCancelled != true,
                  let metadata = fileMetadata(for: fileURL) else { return .unavailable }
            guard metadata.isRegularFile else { return .unsupported }
            guard metadata.size <= Int64(maximumJustfileSize) else { return .tooLarge }
            return .unreadable(metadata)
        }
        defer { _ = close(descriptor) }
        guard let before = fileMetadata(for: descriptor) else { return .unavailable }
        guard before.isRegularFile else { return .unsupported }
        guard before.size <= Int64(maximumJustfileSize) else { return .tooLarge }

        var hasher = SHA256()
        var bytesReadTotal: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard cancellation?.wasCancelled != true else { return .unavailable }
            let bytesRead = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if bytesRead > 0 {
                bytesReadTotal += Int64(bytesRead)
                guard bytesReadTotal <= Int64(maximumJustfileSize) else { return .tooLarge }
                hasher.update(data: Data(buffer.prefix(bytesRead)))
                continue
            }
            if bytesRead == 0 { break }
            if errno == EINTR { continue }
            guard let after = fileMetadata(for: descriptor),
                  after == before,
                  fileMetadata(for: fileURL) == before else { return .unavailable }
            return .unreadable(before)
        }
        guard bytesReadTotal == before.size,
              cancellation?.wasCancelled != true,
              let after = fileMetadata(for: descriptor),
              after == before,
              fileMetadata(for: fileURL) == before else { return .unavailable }
        return .signature(JustfileSignature(
            size: after.size,
            modificationDate: after.modificationDate,
            changeDate: after.changeDate,
            fileNumber: after.fileNumber,
            contentDigest: Data(hasher.finalize())
        ))
    }

    private enum FileSignatureResult {
        case signature(JustfileSignature)
        case unsupported
        case tooLarge
        case unreadable(JustfileFileMetadata?)
        case unavailable
        case deferred
    }

    private final class FileSignatureResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedResult: FileSignatureResult?

        func store(_ result: FileSignatureResult) {
            lock.lock()
            storedResult = result
            lock.unlock()
        }

        var result: FileSignatureResult? {
            lock.lock()
            defer { lock.unlock() }
            return storedResult
        }
    }

    private typealias FileMetadata = JustfileFileMetadata

    private static func fileMetadata(for descriptor: Int32) -> FileMetadata? {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return nil }
        return fileMetadata(from: metadata)
    }

    private static func fileMetadata(for fileURL: URL) -> FileMetadata? {
        var metadata = stat()
        guard fileURL.path.withCString({ stat($0, &metadata) }) == 0 else { return nil }
        return fileMetadata(from: metadata)
    }

    private static func fileMetadata(from metadata: stat) -> FileMetadata {
        FileMetadata(
            size: Int64(metadata.st_size),
            modificationDate: Date(
                timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                    + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            changeDate: Date(
                timeIntervalSince1970: TimeInterval(metadata.st_ctimespec.tv_sec)
                    + TimeInterval(metadata.st_ctimespec.tv_nsec) / 1_000_000_000
            ),
            fileNumber: UInt64(metadata.st_ino),
            isRegularFile: metadata.st_mode & S_IFMT == S_IFREG
        )
    }

    static func createExample(in repositoryURL: URL) throws -> URL {
        let fileURL = repositoryURL.appendingPathComponent("justfile")
        guard !hasJustfile(in: repositoryURL) else {
            throw CreationError.alreadyExists(justfileURL(in: repositoryURL) ?? fileURL)
        }

        var temporaryPath = Array(
            repositoryURL.appendingPathComponent(".intreccio-justfile.XXXXXX").path.utf8CString
        )
        let descriptor = temporaryPath.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw CreationError.couldNotCreate(fileURL) }
        let temporaryURL = temporaryPath.withUnsafeBufferPointer {
            URL(fileURLWithPath: String(cString: $0.baseAddress!))
        }
        defer {
            _ = close(descriptor)
            _ = unlink(temporaryURL.path)
        }

        guard fchmod(descriptor, mode_t(0o644)) == 0,
              writeAll(Data(exampleContents.utf8), to: descriptor),
              fsync(descriptor) == 0 else {
            throw CreationError.couldNotCreate(fileURL)
        }
        let installResult = temporaryURL.path.withCString { temporaryPath in
            fileURL.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    temporaryPath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        let installError = installResult == 0 ? 0 : errno
        guard installResult == 0 else {
            if installError == EEXIST || hasJustfile(in: repositoryURL) {
                throw CreationError.alreadyExists(justfileURL(in: repositoryURL) ?? fileURL)
            }
            throw CreationError.couldNotCreate(fileURL)
        }
        return fileURL
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    static func command(for recipeName: String, in repositoryURL: URL, justfileURL: URL) -> String {
        "cd -- \(shellQuote(repositoryURL.path)) && just --justfile \(shellQuote(justfileURL.path)) \(shellQuote(recipeName))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
