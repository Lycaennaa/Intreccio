import Darwin
import Foundation

nonisolated enum GitIgnoreWriterError: Error, Equatable, CustomStringConvertible {
    case invalidPath(String)
    case invalidTarget(String)
    case openFailed(String, Int32)
    case readFailed(String, Int32)
    case unsupportedFile(String)
    case lockFailed(String, Int32)
    case writeFailed(String, Int32)
    case rollbackFailed(String, Int32, Int32)
    case rollbackConflict(String)

    var description: String {
        switch self {
        case .invalidPath(let path):
            "Cannot represent path in .gitignore: \(path)"
        case .invalidTarget(let path):
            "Ignore target is not the selected file or one of its parent folders: \(path)"
        case .openFailed(let path, let code):
            "Could not open \(path): \(String(cString: strerror(code)))"
        case .readFailed(let path, let code):
            "Could not read \(path): \(String(cString: strerror(code)))"
        case .unsupportedFile(let path):
            "\(path) is not a regular file"
        case .lockFailed(let path, let code):
            "Could not lock \(path): \(String(cString: strerror(code)))"
        case .writeFailed(let path, let code):
            "Could not update \(path): \(String(cString: strerror(code)))"
        case .rollbackFailed(let path, let writeCode, let rollbackCode):
            "Could not update or restore \(path): \(String(cString: strerror(writeCode))); rollback: \(String(cString: strerror(rollbackCode)))"
        case .rollbackConflict(let path):
            "Could not restore \(path) because it changed after the ignore rule was added"
        }
    }
}

nonisolated enum GitIgnoreWriter {
    struct AppendReceipt: Sendable, Equatable {
        let originalSize: Int64
        let payload: Data
        let expectedContent: Data
        let created: Bool
        let device: UInt64
        let inode: UInt64
        let backupName: String?
        let backupDevice: UInt64?
        let backupInode: UInt64?
    }

    static func ancestorFolders(for path: String) -> [String] {
        guard let components = statusPathComponents(path), components.count > 1 else { return [] }
        return stride(from: components.count - 1, through: 1, by: -1).map {
            components.prefix($0).joined(separator: "/")
        }
    }

    static func contains(_ path: String, inFolder folder: String) -> Bool {
        guard let pathComponents = statusPathComponents(path),
              let folderComponents = relativePathComponents(folder),
              pathComponents.count > folderComponents.count else { return false }
        return pathComponents.starts(with: folderComponents)
    }

    static func fileURL(repository: URL, relativePath: String) -> URL? {
        fileURL(repository: repository, relativePath: GitPath(relativePath))
    }

    static func fileURL(repository: URL, relativePath: GitPath) -> URL? {
        guard relativePath.isFileActionAddressable,
              let components = relativePath.relativeComponents else { return nil }
        return components.reduce(repository) { url, component in
            url.appendingPathComponent(String(decoding: component, as: UTF8.self))
        }
    }

    static func pattern(
        selectedPath: GitPath,
        targetPath: GitPath,
        isDirectory: Bool
    ) throws -> String {
        guard selectedPath.isIgnoreAddressable,
              targetPath.isIgnoreAddressable else {
            throw GitIgnoreWriterError.invalidPath(targetPath.displayString)
        }
        return try pattern(
            selectedPath: selectedPath.decodedString,
            targetPath: targetPath.decodedString,
            isDirectory: isDirectory
        )
    }

    static func pattern(selectedPath: String, targetPath: String, isDirectory: Bool) throws -> String {
        let normalizedSelectedPath = directoryTarget(for: selectedPath) ?? selectedPath
        guard let selectedComponents = relativePathComponents(normalizedSelectedPath),
              relativePathComponents(targetPath) != nil else {
            throw GitIgnoreWriterError.invalidPath(targetPath)
        }
        if isDirectory {
            guard normalizedSelectedPath == targetPath
                    || contains(normalizedSelectedPath, inFolder: targetPath) else {
                throw GitIgnoreWriterError.invalidTarget(targetPath)
            }
        } else if selectedPath != targetPath || directoryTarget(for: selectedPath) != nil {
            throw GitIgnoreWriterError.invalidTarget(targetPath)
        }
        guard !selectedComponents.isEmpty else { throw GitIgnoreWriterError.invalidPath(selectedPath) }

        var escaped = ""
        escaped.reserveCapacity(targetPath.utf8.count + 2)
        for character in targetPath {
            switch character {
            case "\\", "*", "?", "[", " ":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return "/" + escaped + (isDirectory ? "/" : "")
    }

    @discardableResult
    static func append(pattern: String, repository: URL) throws -> AppendReceipt {
        guard !pattern.isEmpty,
              pattern.utf8.count <= 64 * 1_024,
              !pattern.contains("\0"),
              !pattern.contains("\n"),
              !pattern.contains("\r") else {
            throw GitIgnoreWriterError.invalidPath(pattern)
        }
        try Task.checkCancellation()

        let repositoryDescriptor = open(repository.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard repositoryDescriptor >= 0 else {
            throw GitIgnoreWriterError.openFailed(repository.path, errno)
        }
        defer { close(repositoryDescriptor) }

        let ignorePath = repository.appendingPathComponent(".gitignore").path
        let existingFlags = O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        for _ in 0..<3 {
            let descriptor = openat(repositoryDescriptor, ".gitignore", existingFlags)
            if descriptor >= 0 {
                return try append(
                    pattern: pattern,
                    to: descriptor,
                    repositoryDescriptor: repositoryDescriptor,
                    ignorePath: ignorePath
                )
            }
            guard errno == ENOENT else { throw GitIgnoreWriterError.openFailed(ignorePath, errno) }
            if let receipt = try create(pattern: pattern, repositoryDescriptor: repositoryDescriptor, ignorePath: ignorePath) {
                return receipt
            }
        }
        throw GitIgnoreWriterError.openFailed(ignorePath, EAGAIN)
    }

    static func rollback(_ receipt: AppendReceipt, repository: URL) throws {
        let repositoryDescriptor = open(repository.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard repositoryDescriptor >= 0 else {
            throw GitIgnoreWriterError.openFailed(repository.path, errno)
        }
        defer { close(repositoryDescriptor) }

        let ignorePath = repository.appendingPathComponent(".gitignore").path
        let rollbackName = ".gitignore.Intreccio.rollback.\(UUID().uuidString).tmp"
        guard renameatx_np(
            repositoryDescriptor,
            ".gitignore",
            repositoryDescriptor,
            rollbackName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw GitIgnoreWriterError.writeFailed(ignorePath, errno)
        }

        var movedStatus = stat()
        guard fstatat(repositoryDescriptor, rollbackName, &movedStatus, AT_SYMLINK_NOFOLLOW) == 0,
              UInt64(movedStatus.st_dev) == receipt.device,
              UInt64(movedStatus.st_ino) == receipt.inode,
              validateContent(
                named: rollbackName,
                expected: receipt.expectedContent,
                repositoryDescriptor: repositoryDescriptor
              ) else {
            _ = renameatx_np(
                repositoryDescriptor,
                rollbackName,
                repositoryDescriptor,
                ".gitignore",
                UInt32(RENAME_EXCL)
            )
            throw GitIgnoreWriterError.rollbackConflict(ignorePath)
        }

        if receipt.created {
            guard unlinkat(repositoryDescriptor, rollbackName, 0) == 0 else {
                throw GitIgnoreWriterError.writeFailed(ignorePath, errno)
            }
            return
        }

        guard let backupName = receipt.backupName,
              renameatx_np(
                repositoryDescriptor,
                backupName,
                repositoryDescriptor,
                ".gitignore",
                UInt32(RENAME_EXCL)
              ) == 0 else {
            throw GitIgnoreWriterError.rollbackConflict(ignorePath)
        }
        guard unlinkat(repositoryDescriptor, rollbackName, 0) == 0 else {
            throw GitIgnoreWriterError.writeFailed(ignorePath, errno)
        }
    }

    static func commit(_ receipt: AppendReceipt, repository: URL) throws {
        guard let backupName = receipt.backupName,
              let backupDevice = receipt.backupDevice,
              let backupInode = receipt.backupInode else { return }
        let repositoryDescriptor = open(repository.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard repositoryDescriptor >= 0 else {
            throw GitIgnoreWriterError.openFailed(repository.path, errno)
        }
        defer { close(repositoryDescriptor) }

        let ignorePath = repository.appendingPathComponent(".gitignore").path
        var status = stat()
        guard fstatat(repositoryDescriptor, backupName, &status, AT_SYMLINK_NOFOLLOW) == 0,
              UInt64(status.st_dev) == backupDevice,
              UInt64(status.st_ino) == backupInode else {
            throw GitIgnoreWriterError.rollbackConflict(ignorePath)
        }
        guard unlinkat(repositoryDescriptor, backupName, 0) == 0 else {
            throw GitIgnoreWriterError.writeFailed(ignorePath, errno)
        }
    }

    private static func append(
        pattern: String,
        to descriptor: Int32,
        repositoryDescriptor: Int32,
        ignorePath: String
    ) throws -> AppendReceipt {
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw GitIgnoreWriterError.openFailed(ignorePath, errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw GitIgnoreWriterError.unsupportedFile(ignorePath)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw GitIgnoreWriterError.lockFailed(ignorePath, errno)
        }
        defer { flock(descriptor, LOCK_UN) }

        guard fstat(descriptor, &status) == 0 else {
            throw GitIgnoreWriterError.openFailed(ignorePath, errno)
        }
        guard status.st_size <= 8 * 1_024 * 1_024 else {
            throw GitIgnoreWriterError.unsupportedFile(ignorePath)
        }
        let original = try readAll(descriptor: descriptor, size: Int(status.st_size), path: ignorePath)
        let needsNewline = original.last.map { $0 != 0x0A } ?? false
        let payload = Data(((needsNewline ? "\n" : "") + pattern + "\n").utf8)
        var replacement = original
        replacement.append(payload)
        let replacementFile = try writeTemporary(
            replacement,
            mode: mode_t(status.st_mode & 0o7777),
            repositoryDescriptor: repositoryDescriptor,
            ignorePath: ignorePath
        )
        let backupName = ".gitignore.Intreccio.backup.\(UUID().uuidString).tmp"
        guard renameatx_np(
            repositoryDescriptor,
            ".gitignore",
            repositoryDescriptor,
            backupName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            _ = unlinkat(repositoryDescriptor, replacementFile.name, 0)
            throw GitIgnoreWriterError.writeFailed(ignorePath, errno)
        }
        var backupStatus = stat()
        guard fstatat(repositoryDescriptor, backupName, &backupStatus, AT_SYMLINK_NOFOLLOW) == 0,
              UInt64(backupStatus.st_dev) == UInt64(status.st_dev),
              UInt64(backupStatus.st_ino) == UInt64(status.st_ino) else {
            _ = renameatx_np(repositoryDescriptor, backupName, repositoryDescriptor, ".gitignore", UInt32(RENAME_EXCL))
            _ = unlinkat(repositoryDescriptor, replacementFile.name, 0)
            throw GitIgnoreWriterError.rollbackConflict(ignorePath)
        }
        guard renameatx_np(
            repositoryDescriptor,
            replacementFile.name,
            repositoryDescriptor,
            ".gitignore",
            UInt32(RENAME_EXCL)
        ) == 0 else {
            let code = errno
            _ = renameatx_np(repositoryDescriptor, backupName, repositoryDescriptor, ".gitignore", UInt32(RENAME_EXCL))
            _ = unlinkat(repositoryDescriptor, replacementFile.name, 0)
            throw GitIgnoreWriterError.writeFailed(ignorePath, code)
        }
        return AppendReceipt(
            originalSize: Int64(status.st_size),
            payload: payload,
            expectedContent: replacement,
            created: false,
            device: replacementFile.device,
            inode: replacementFile.inode,
            backupName: backupName,
            backupDevice: UInt64(status.st_dev),
            backupInode: UInt64(status.st_ino)
        )
    }

    private static func create(
        pattern: String,
        repositoryDescriptor: Int32,
        ignorePath: String
    ) throws -> AppendReceipt? {
        let temporaryName = ".gitignore.Intreccio.\(UUID().uuidString).tmp"
        let descriptor = openat(
            repositoryDescriptor,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(0o666)
        )
        guard descriptor >= 0 else { throw GitIgnoreWriterError.openFailed(ignorePath, errno) }
        defer {
            close(descriptor)
            _ = unlinkat(repositoryDescriptor, temporaryName, 0)
        }

        let payload = Data((pattern + "\n").utf8)
        do {
            try writeAll(payload, to: descriptor)
            guard fsync(descriptor) == 0 else { throw POSIXWriteError(code: errno) }
        } catch let error as POSIXWriteError {
            throw GitIgnoreWriterError.writeFailed(ignorePath, error.code)
        }

        if renameatx_np(
            repositoryDescriptor,
            temporaryName,
            repositoryDescriptor,
            ".gitignore",
            UInt32(RENAME_EXCL)
        ) == 0 {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw GitIgnoreWriterError.openFailed(ignorePath, errno)
            }
            return AppendReceipt(
                originalSize: 0,
                payload: payload,
                expectedContent: payload,
                created: true,
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                backupName: nil,
                backupDevice: nil,
                backupInode: nil
            )
        }
        if errno == EEXIST { return nil }
        throw GitIgnoreWriterError.writeFailed(ignorePath, errno)
    }

    private static func readAll(descriptor: Int32, size: Int, path: String) throws -> Data {
        var data = Data(count: size)
        var offset = 0
        while offset < size {
            let count = data.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress?.advanced(by: offset), size - offset, off_t(offset))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw GitIgnoreWriterError.readFailed(path, errno)
            }
            guard count > 0 else { throw GitIgnoreWriterError.readFailed(path, EIO) }
            offset += count
        }
        return data
    }

    private static func validateContent(
        named name: String,
        expected: Data,
        repositoryDescriptor: Int32
    ) -> Bool {
        let descriptor = openat(repositoryDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size == expected.count,
              let data = try? readAll(descriptor: descriptor, size: expected.count, path: name) else { return false }
        return data == expected
    }

    private static func writeTemporary(
        _ data: Data,
        mode: mode_t,
        repositoryDescriptor: Int32,
        ignorePath: String
    ) throws -> TemporaryFile {
        let name = ".gitignore.Intreccio.\(UUID().uuidString).tmp"
        let descriptor = openat(
            repositoryDescriptor,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw GitIgnoreWriterError.openFailed(ignorePath, errno) }
        var keep = false
        defer {
            close(descriptor)
            if !keep { _ = unlinkat(repositoryDescriptor, name, 0) }
        }
        do {
            try writeAll(data, to: descriptor)
            guard fchmod(descriptor, mode) == 0,
                  fsync(descriptor) == 0 else { throw POSIXWriteError(code: errno) }
        } catch let error as POSIXWriteError {
            throw GitIgnoreWriterError.writeFailed(ignorePath, error.code)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw GitIgnoreWriterError.openFailed(ignorePath, errno)
        }
        keep = true
        return TemporaryFile(name: name, device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    static func directoryTarget(for path: String) -> String? {
        guard path.hasSuffix("/") else { return nil }
        let target = String(path.dropLast())
        return relativePathComponents(target) == nil ? nil : target
    }

    private static func statusPathComponents(_ path: String) -> [String]? {
        relativePathComponents(directoryTarget(for: path) ?? path)
    }

    private static func relativePathComponents(_ path: String) -> [String]? {
        RepositoryPathPolicy.relativePathComponents(path)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXWriteError(code: errno)
                }
                guard count > 0 else { throw POSIXWriteError(code: EIO) }
                offset += count
            }
        }
    }

    private struct TemporaryFile {
        let name: String
        let device: UInt64
        let inode: UInt64
    }

    private struct POSIXWriteError: Error {
        let code: Int32
    }
}
