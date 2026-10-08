import CryptoKit
import Darwin
import Foundation
nonisolated extension SyntheticUntrackedDiff {
    enum RegularFileValidation {
        case unchanged
        case descriptorInspectionFailed(Int32)
        case changed
    }
    static func validateRegularFile(
        parent: Int32,
        descriptor: Int32,
        name: String,
        expectedIdentity: FileIdentity
    ) -> RegularFileValidation {
        validateRegularFile(
            parent: parent,
            descriptor: descriptor,
            name: Data(name.utf8),
            expectedIdentity: expectedIdentity
        )
    }

    static func validateRegularFile(
        parent: Int32,
        descriptor: Int32,
        name: Data,
        expectedIdentity: FileIdentity
    ) -> RegularFileValidation {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else {
            return .descriptorInspectionFailed(errno)
        }
        guard FileIdentity(descriptorStatus) == expectedIdentity else { return .changed }

        var pathStatus = stat()
        let pathResult = withCStringBytes(name) {
            fstatat(parent, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard pathResult == 0,
              pathStatus.st_mode & S_IFMT == S_IFREG,
              FileIdentity(pathStatus) == expectedIdentity else { return .changed }
        return .unchanged
    }

    static func withRegularFile<Value>(
        repository: URL,
        relativePath: String,
        _ body: (Int32, Int32, String, FileIdentity, Int64) throws -> Value
    ) throws -> Value {
        try withRegularFile(repository: repository, relativePath: GitPath(relativePath)) { parent, descriptor, name, identity, byteCount in
            try body(parent, descriptor, String(decoding: name, as: UTF8.self), identity, byteCount)
        }
    }

    static func withRegularFile<Value>(
        repository: URL,
        relativePath: GitPath,
        _ body: (Int32, Int32, Data, FileIdentity, Int64) throws -> Value
    ) throws -> Value {
        guard let components = relativePath.relativeComponents,
              let finalName = components.last else {
            throw SyntheticUntrackedDiffError.invalidPath(relativePath.displayString)
        }

        var descriptor = open(repository.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SyntheticUntrackedDiffError.openFailed(relativePath.displayString, errno)
        }
        defer { close(descriptor) }

        for component in components.dropLast() {
            let next = withCStringBytes(component) {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                throw SyntheticUntrackedDiffError.openFailed(relativePath.displayString, errno)
            }
            close(descriptor)
            descriptor = next
        }

        let final = withCStringBytes(finalName) {
            openat(descriptor, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard final >= 0 else {
            throw SyntheticUntrackedDiffError.openFailed(relativePath.displayString, errno)
        }
        defer { close(final) }

        var status = stat()
        guard fstat(final, &status) == 0 else {
            throw SyntheticUntrackedDiffError.readFailed(relativePath.displayString, errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw SyntheticUntrackedDiffError.unsupportedFile(relativePath.displayString)
        }
        return try body(
            descriptor,
            final,
            finalName,
            FileIdentity(status),
            Int64(status.st_size)
        )
    }

    static func withCStringBytes<Value>(
        _ data: Data,
        _ body: (UnsafePointer<CChar>) -> Value
    ) -> Value {
        var bytes = Array(data)
        bytes.append(0)
        return bytes.withUnsafeBufferPointer { buffer in
            body(UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self))
        }
    }
    static func readRegularFile(
        repository: URL,
        relativePath: String,
        maximumBytes: Int,
        verifyContent: Bool
    ) throws -> (
        data: Data,
        byteCount: Int64,
        identity: FileIdentity,
        fingerprint: FileContentFingerprint
    ) {
        try readRegularFile(
            repository: repository,
            relativePath: GitPath(relativePath),
            maximumBytes: maximumBytes,
            verifyContent: verifyContent
        )
    }

    static func readRegularFile(
        repository: URL,
        relativePath: GitPath,
        maximumBytes: Int,
        verifyContent: Bool
    ) throws -> (
        data: Data,
        byteCount: Int64,
        identity: FileIdentity,
        fingerprint: FileContentFingerprint
    ) {
        try withRegularFile(repository: repository, relativePath: relativePath) { parent, final, name, initialIdentity, byteCount in
            var data = Data()
            data.reserveCapacity(min(maximumBytes + 1, max(0, Int(byteCount))))
            let result = try readFile(
                descriptor: final,
                relativePath: relativePath,
                maximumBytes: Int64(maximumBytes),
                collectData: true
            )
            data = result.data
            switch validateRegularFile(
                parent: parent,
                descriptor: final,
                name: name,
                expectedIdentity: initialIdentity
            ) {
            case .unchanged:
                break
            case .descriptorInspectionFailed(let code):
                throw SyntheticUntrackedDiffError.readFailed(relativePath.displayString, code)
            case .changed:
                throw SyntheticUntrackedDiffError.changedDuringRead(relativePath.displayString)
            }
            let currentPathIdentity = try withRegularFile(
                repository: repository,
                relativePath: relativePath
            ) { _, _, _, currentIdentity, _ in
                currentIdentity
            }
            guard currentPathIdentity == initialIdentity else {
                throw SyntheticUntrackedDiffError.changedDuringRead(relativePath.displayString)
            }

            let fingerprint: FileContentFingerprint
            if byteCount <= Int64(maximumBytes) {
                let expectedDigest = result.digest
                if verifyContent {
                    guard let current = try contentFingerprint(
                        repository: repository,
                        relativePath: relativePath,
                        maximumBytes: Int64(maximumBytes)
                    ), current.byteCount == byteCount, current.digest == expectedDigest else {
                        throw SyntheticUntrackedDiffError.changedDuringRead(relativePath.displayString)
                    }
                }
                fingerprint = FileContentFingerprint(digest: expectedDigest, byteCount: byteCount)
            } else {
                fingerprint = FileContentFingerprint(digest: nil, byteCount: byteCount)
            }
            return (data, byteCount, initialIdentity, fingerprint)
        }
    }
    static func readFile(
        descriptor: Int32,
        relativePath: String,
        maximumBytes: Int64?,
        collectData: Bool
    ) throws -> (
        data: Data,
        byteCount: Int64,
        digest: Data,
        exceededLimit: Bool
    ) {
        try readFile(
            descriptor: descriptor,
            relativePath: GitPath(relativePath),
            maximumBytes: maximumBytes,
            collectData: collectData
        )
    }

    static func readFile(
        descriptor: Int32,
        relativePath: GitPath,
        maximumBytes: Int64?,
        collectData: Bool
    ) throws -> (
        data: Data,
        byteCount: Int64,
        digest: Data,
        exceededLimit: Bool
    ) {
        var data = Data()
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var bytesRead: Int64 = 0
        let readLimit = maximumBytes.map { $0 == Int64.max ? Int64.max : $0 + 1 }
        while true {
            try Task.checkCancellation()
            let requested: Int
            if let readLimit {
                let remaining = readLimit - bytesRead
                guard remaining > 0 else { break }
                requested = min(buffer.count, Int(min(remaining, Int64(buffer.count))))
            } else {
                requested = buffer.count
            }
            let count = read(descriptor, &buffer, requested)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SyntheticUntrackedDiffError.readFailed(relativePath.displayString, errno)
            }
            bytesRead += Int64(count)
            if collectData { data.append(buffer, count: count) }
            hasher.update(data: Data(buffer[..<count]))
            if let maximumBytes, bytesRead > maximumBytes { break }
        }
        return (
            data,
            bytesRead,
            Data(hasher.finalize()),
            maximumBytes.map { bytesRead > $0 } ?? false
        )
    }
}
