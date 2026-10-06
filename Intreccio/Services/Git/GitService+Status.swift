import Foundation
import Darwin

extension GitService {
    func ignoredPaths(
        repository: URL,
        relativePaths: [String],
        priority: ProcessPriority = .normal
    ) async throws -> Set<String> {
        let paths = try await ignoredPaths(
            repository: repository,
            relativePaths: relativePaths.map(GitPath.init),
            priority: priority
        )
        return Set(paths.map(\.decodedString))
    }

    func ignoredPaths(
        repository: URL,
        relativePaths: [GitPath],
        priority: ProcessPriority = .normal
    ) async throws -> Set<GitPath> {
        guard !relativePaths.isEmpty else { return [] }

        var input = Data()
        var encodedToRelativePath: [Data: GitPath] = [:]
        for path in relativePaths {
            var encodedPath = Data("./".utf8)
            encodedPath.append(path.bytes)
            encodedToRelativePath[encodedPath] = path
            input.append(encodedPath)
            input.append(0)
        }
        let result = try await runner.run(
            repository: repository,
            arguments: ["check-ignore", "--stdin", "-z"],
            input: input,
            environment: statusEnvironment(for: repository),
            acceptedExitCodes: [0, 1],
            outputLimit: ProcessRunner.defaultOutputLimit,
            priority: priority
        )
        return Set(Self.nulRecords(result.standardOutput).compactMap { encodedToRelativePath[$0] })
    }

    func statusWithoutDiffStats(
        repository: URL,
        refreshUpstream: Bool = false,
        priority: ProcessPriority = .normal,
        expandUntrackedDirectories: Bool = true
    ) async throws -> RepoStatus {
        var status = try await repositoryStatus(
            repository: repository,
            priority: priority,
            expandUntrackedDirectories: expandUntrackedDirectories
        )
        guard refreshUpstream,
              status.branch.upstream != nil,
              let branch = status.branch.head else {
            return status
        }
        let upstreamResult = try await runner.run(
            repository: repository,
            arguments: [
                "for-each-ref",
                "--format=%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream)",
                "--count=1",
                "refs/heads/\(branch)",
            ],
            environment: readEnvironment,
            outputLimit: 12 * 1_024,
            priority: priority
        )
        let fields = upstreamResult.standardOutput.split(
            separator: 0,
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count == 3 else {
            return status
        }
        let remote = String(decoding: fields[0], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteRef = String(decoding: fields[1], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamRef = String(decoding: fields[2], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty, remote != ".", !remoteRef.isEmpty, !upstreamRef.isEmpty else {
            return status
        }
        guard upstreamRef.hasPrefix("refs/remotes/") else {
            throw GitServiceError.unsupportedUpstreamRef(upstreamRef)
        }
        let currentResult = try await runner.run(
            repository: repository,
            arguments: ["show-ref", "--verify", "--hash", upstreamRef],
            environment: readEnvironment,
            acceptedExitCodes: [0, 1, 128],
            outputLimit: 128,
            priority: priority
        )
        let currentObjectID = String(decoding: currentResult.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let advertisedResult = try await runner.run(
            repository: repository,
            arguments: ["ls-remote", "--refs", "--", remote, remoteRef],
            environment: networkEnvironment,
            outputLimit: 12 * 1_024,
            timeout: ProcessRunner.networkTimeout,
            priority: priority
        )
        let advertisedFields = advertisedResult.standardOutput
            .split(separator: 10, omittingEmptySubsequences: true)
            .flatMap { $0.split(separator: 9, maxSplits: 1, omittingEmptySubsequences: false) }
        guard advertisedFields.count == 2,
              String(decoding: advertisedFields[1], as: UTF8.self) == remoteRef else {
            throw GitServiceError.upstreamRefNotFound(remoteRef)
        }
        let remoteObjectID = String(decoding: advertisedFields[0], as: UTF8.self)
        guard (remoteObjectID.count == 40 || remoteObjectID.count == 64),
              remoteObjectID.allSatisfy({ $0.isHexDigit }) else {
            throw GitServiceError.invalidObjectID(remoteObjectID)
        }
        if currentObjectID.isEmpty {
            _ = try await runner.run(
                repository: repository,
                arguments: ["symbolic-ref", "--delete", "--quiet", upstreamRef],
                environment: networkEnvironment,
                acceptedExitCodes: [0, 1, 128],
                priority: priority
            )
        }
        _ = try await runner.run(
            repository: repository,
            arguments: [
                "fetch", "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no", "--",
                remote, remoteObjectID,
            ],
            environment: networkEnvironment,
            timeout: ProcessRunner.networkTimeout,
            priority: priority
        )
        let expectedObjectID = currentObjectID.isEmpty
            ? String(repeating: "0", count: remoteObjectID.count)
            : currentObjectID
        _ = try await runner.run(
            repository: repository,
            arguments: ["update-ref", "--no-deref", upstreamRef, remoteObjectID, expectedObjectID],
            environment: networkEnvironment,
            priority: priority
        )
        status = try await repositoryStatus(
            repository: repository,
            priority: priority,
            expandUntrackedDirectories: expandUntrackedDirectories
        )
        return status
    }



    func localStatus(
        repository: URL,
        priority: ProcessPriority,
        expandUntrackedDirectories: Bool = true
    ) async throws -> RepoStatus {
        let environment = statusEnvironment(for: repository)
        let initialResult = try await runner.run(
            repository: repository,
            arguments: [
                "status", "--porcelain=v2", "-z", "--branch", "--show-stash",
                "--untracked-files=normal",
            ],
            environment: environment,
            priority: priority
        )
        var status = try PorcelainV2Parser.parse(initialResult.standardOutput)
        guard expandUntrackedDirectories else { return status }

        let untrackedDirectories = status.changes
            .filter { $0.kind == .untracked && $0.gitPath.hasTrailingSlash }
            .map(\.gitPath)
        guard !untrackedDirectories.isEmpty else { return status }

        let expansionOutput: Data
        do {
            let result = try await runner.run(
                repository: repository,
                arguments: [
                    "status", "--porcelain=v2", "-z", "--untracked-files=all",
                    "--pathspec-from-file=-", "--pathspec-file-nul",
                ],
                input: Self.untrackedDirectoryPathspecInput(for: untrackedDirectories),
                environment: environment,
                outputLimit: ProcessRunner.defaultOutputLimit,
                priority: priority
            )
            expansionOutput = result.standardOutput
        } catch let error as ProcessRunnerError {
            guard Self.isUnsupportedPathspecFileOption(error) else { throw error }
            expansionOutput = try await expandedUntrackedDirectoryStatus(
                repository: repository,
                directories: untrackedDirectories,
                environment: environment,
                priority: priority
            )
        }
        let expanded = try PorcelainV2Parser.parse(expansionOutput)
        var expandedByDirectory: [GitPath: [FileChange]] = [:]
        let untrackedDirectorySet = Set(untrackedDirectories)
        for change in expanded.changes where change.kind == .untracked {
            guard let directory = Self.untrackedDirectory(
                containing: change.gitPath,
                in: untrackedDirectorySet
            ) else { continue }
            expandedByDirectory[directory, default: []].append(change)
        }
        let replacedDirectories = Set(expandedByDirectory.keys)
        let removedDirectoryBytes = replacedDirectories.reduce(into: 0) { total, directory in
            total += 3 + directory.byteCount
        }
        let statusOutputBytes = initialResult.standardOutput.count
            - removedDirectoryBytes
            + expansionOutput.count
        guard statusOutputBytes <= ProcessRunner.defaultOutputLimit else {
            throw ProcessRunnerError.outputLimitExceeded(
                stream: .standardOutput,
                limit: ProcessRunner.defaultOutputLimit,
                result: ProcessCommandResult(
                    exitCode: 0,
                    standardOutput: expansionOutput,
                    standardError: Data()
                )
            )
        }
        status.changes = status.changes.flatMap { change in
            guard change.kind == .untracked,
                  change.gitPath.hasTrailingSlash,
                  let replacements = expandedByDirectory[change.gitPath],
                  !replacements.isEmpty else { return [change] }
            return replacements
        }
        return status
    }

    // Keep headroom for spawn bookkeeping not represented by encoded strings.
    private static let statusArgumentSafetyMargin = 16 * 1_024

    private func expandedUntrackedDirectoryStatus(
        repository: URL,
        directories: [GitPath],
        environment: [String: String],
        priority: ProcessPriority
    ) async throws -> Data {
        let baseArguments = [
            "status", "--porcelain=v2", "-z", "--untracked-files=all", "--",
        ]
        let argumentByteLimit = Self.untrackedDirectoryPathspecArgumentByteLimit(
            repository: repository,
            arguments: baseArguments,
            environment: environment
        )
        var output = Data()
        for pathspecs in Self.untrackedDirectoryPathspecBatches(
            for: directories,
            argumentByteLimit: argumentByteLimit
        ) {
            try Task.checkCancellation()
            let remainingOutputLimit = ProcessRunner.defaultOutputLimit - output.count
            guard remainingOutputLimit > 0 else { break }
            let result = try await runner.run(
                repository: repository,
                arguments: baseArguments + pathspecs,
                environment: environment,
                outputLimit: remainingOutputLimit,
                priority: priority
            )
            output.append(result.standardOutput)
        }
        return output
    }

    private static func untrackedDirectoryPathspecArgumentByteLimit(
        repository: URL,
        arguments: [String],
        environment: [String: String]
    ) -> Int {
        let argumentMax = sysconf(_SC_ARG_MAX)
        guard argumentMax > 0 else { return 1 }

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.merge(environment) { _, new in new }
        let fixedArguments = ["/usr/bin/git", "-C", repository.path] + arguments
        let fixedBytes = fixedArguments.reduce(0) { total, argument in
            total + argument.utf8.count + 1
        }
        let environmentBytes = processEnvironment.reduce(0) { total, entry in
            total + entry.key.utf8.count + entry.value.utf8.count + 2
        }
        let pointerBytes = (fixedArguments.count + processEnvironment.count + 2)
            * MemoryLayout<UnsafeMutablePointer<CChar>?>.stride
        return max(
            1,
            Int(argumentMax) - fixedBytes - environmentBytes - pointerBytes - statusArgumentSafetyMargin
        )
    }

    private static func untrackedDirectoryPathspecBatches(
        for directories: [GitPath],
        argumentByteLimit: Int
    ) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var currentByteCount = 0
        for directory in directories where directory.isAddressable {
            let pathspec = ":(literal)\(directory.decodedString)"
            let pathspecByteCount = pathspec.utf8.count + 1
            if !current.isEmpty,
               currentByteCount + pathspecByteCount > argumentByteLimit {
                batches.append(current)
                current = []
                currentByteCount = 0
            }
            current.append(pathspec)
            currentByteCount += pathspecByteCount
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private static func isUnsupportedPathspecFileOption(_ error: ProcessRunnerError) -> Bool {
        guard case .nonZeroExit(let result) = error else { return false }
        let message = result.standardErrorText
        return message.contains("unknown option") && message.contains("pathspec-from-file")
    }

    private static func untrackedDirectoryPathspecInput(for directories: [GitPath]) -> Data {
        var input = Data()
        for directory in directories {
            input.append(directory.literalPathspecData)
            input.append(0)
        }
        return input
    }

    private static func untrackedDirectory(
        containing path: GitPath,
        in directories: Set<GitPath>
    ) -> GitPath? {
        if directories.contains(path) { return path }
        var end = path.bytes.count
        while end > 0 {
            var slash: Int?
            for index in stride(from: end - 1, through: 0, by: -1) where path.bytes[index] == 0x2F {
                slash = index
                break
            }
            guard let slash else { return nil }
            let candidate = GitPath(bytes: Data(path.bytes[..<(slash + 1)]))
            if directories.contains(candidate) { return candidate }
            end = slash
        }
        return nil
    }

    func repositoryStatus(
        repository: URL,
        priority: ProcessPriority,
        expandUntrackedDirectories: Bool = true
    ) async throws -> RepoStatus {
        var status = try await localStatus(
            repository: repository,
            priority: priority,
            expandUntrackedDirectories: expandUntrackedDirectories
        )
        status.isRebaseInProgress = try await rebaseIsInProgress(repository: repository, priority: priority)
        return status
    }


    func rebaseIsInProgress(repository: URL, priority: ProcessPriority) async throws -> Bool {
        let result = try await runner.run(
            repository: repository,
            arguments: [
                "rev-parse", "--path-format=absolute",
                "--git-path", "rebase-merge",
                "--git-path", "rebase-apply",
            ],
            environment: readEnvironment,
            outputLimit: 16 * 1_024,
            priority: priority
        )
        for line in String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n") {
            let path = String(line)
            var information = stat()
            if path.withCString({ lstat($0, &information) }) == 0 { return true }
            let code = errno
            guard code == ENOENT || code == ENOTDIR else {
                throw GitServiceError.operationStateInspectionFailed(path: path, code: code)
            }
        }
        return false
    }
    private nonisolated static func nulRecords(_ data: Data) -> [Data] {
        var records: [Data] = []
        var start = 0
        for index in 0..<data.count where data[index] == 0 {
            if index > start { records.append(Data(data[start..<index])) }
            start = index + 1
        }
        if start < data.count { records.append(Data(data[start..<data.count])) }
        return records
    }
}
