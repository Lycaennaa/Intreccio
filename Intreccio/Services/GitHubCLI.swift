import Foundation

nonisolated struct GitHubRepository: Codable, Equatable, Identifiable, Sendable {
    let nameWithOwner: String
    let description: String?
    let isPrivate: Bool
    let url: URL

    var id: String { nameWithOwner }

    var cloneURL: URL? {
        GitHubRepositoryURL.cloneURL(from: url.absoluteString)
    }
}

nonisolated enum GitHubRepositoryVisibility: Sendable {
    case privateRepository
    case publicRepository

    var commandLineFlag: String {
        switch self {
        case .privateRepository: "--private"
        case .publicRepository: "--public"
        }
    }
}

nonisolated struct GitHubRepositoryCreationOptions: Sendable {
    let visibility: GitHubRepositoryVisibility
    let description: String?
}

nonisolated enum GitHubCLIError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    case notAuthenticated
    case invalidRepositoryResponse
    case commandFailed(String)

    var description: String {
        switch self {
        case .notInstalled:
            "GitHub CLI (`gh`) is not installed. Install it, then run `gh auth login` in Terminal."
        case .notAuthenticated:
            "GitHub CLI is not signed in. Run `gh auth login` in Terminal, then retry."
        case .invalidRepositoryResponse:
            "GitHub CLI returned an invalid repository list."
        case .commandFailed(let message):
            message
        }
    }
}

nonisolated enum GitHubCLIExecutable {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        var searchPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        searchPaths.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin"
        ])
        var visited = Set<String>()
        for path in searchPaths where visited.insert(path).inserted {
            let candidate = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("gh")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func gitCredentialEnvironment(
        executableURL: URL?,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard let executableURL else { return [:] }
        let count = Int(inheritedEnvironment["GIT_CONFIG_COUNT"] ?? "0") ?? -1
        guard count >= 0 else { return [:] }
        let (nextCount, overflow) = count.addingReportingOverflow(1)
        guard !overflow else { return [:] }

        let quotedPath = "'" + executableURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var environment = [
            "GIT_CONFIG_COUNT": String(nextCount),
            "GIT_CONFIG_KEY_\(count)": "credential.helper",
            "GIT_CONFIG_VALUE_\(count)": "!\(quotedPath) auth git-credential"
        ]
        let parentPath = executableURL.deletingLastPathComponent().path
        var searchPaths = inheritedEnvironment["PATH"]?.components(separatedBy: ":") ?? []
        if !searchPaths.contains(parentPath) {
            searchPaths.insert(parentPath, at: 0)
            environment["PATH"] = searchPaths.joined(separator: ":")
        }
        return environment
    }
}

nonisolated struct GitHubCLI: Sendable {
    private static let repositoryFilter =
        ".[] | {nameWithOwner: .full_name, description: .description, "
            + "isPrivate: .private, url: .html_url} | @json"
    private static let commandEnvironment = [
        "GH_PROMPT_DISABLED": "1",
        "LC_ALL": "C"
    ]

    private let runner: (any ProcessRunning)?

    init(executableURL: URL? = GitHubCLIExecutable.resolve(), runner: (any ProcessRunning)? = nil) {
        if let runner {
            self.runner = runner
        } else if let executableURL {
            self.runner = ProcessRunner(executable: executableURL.path)
        } else {
            self.runner = nil
        }
    }

    func isAuthenticated() async throws -> Bool {
        let result = try await run(
            ["auth", "status", "--hostname", "github.com"],
            acceptedExitCodes: [0, 1]
        )
        return result.exitCode == 0
    }

    func repositories() async throws -> [GitHubRepository] {
        guard try await isAuthenticated() else { throw GitHubCLIError.notAuthenticated }
        let result = try await run([
            "api",
            "--paginate",
            "--jq",
            Self.repositoryFilter,
            "user/repos"
        ])
        do {
            let decoder = JSONDecoder()
            var repositories = [GitHubRepository]()
            for line in result.standardOutput.split(separator: 10, omittingEmptySubsequences: true) {
                let data = Data(line)
                let repository: GitHubRepository
                do {
                    repository = try decoder.decode(GitHubRepository.self, from: data)
                } catch {
                    let encodedRepository = try decoder.decode(String.self, from: data)
                    repository = try decoder.decode(GitHubRepository.self, from: Data(encodedRepository.utf8))
                }
                guard repository.cloneURL != nil else { throw GitHubCLIError.invalidRepositoryResponse }
                repositories.append(repository)
            }
            return repositories.sorted {
                $0.nameWithOwner.localizedCaseInsensitiveCompare($1.nameWithOwner) == .orderedAscending
            }
        } catch let error as GitHubCLIError {
            throw error
        } catch {
            throw GitHubCLIError.invalidRepositoryResponse
        }
    }

    func createRepository(
        named name: String,
        options: GitHubRepositoryCreationOptions,
        from sourceDirectory: URL
    ) async throws {
        guard try await isAuthenticated() else { throw GitHubCLIError.notAuthenticated }
        var arguments = [
            "repo",
            "create",
            options.visibility.commandLineFlag,
            "--source",
            sourceDirectory.path,
            "--remote",
            "origin"
        ]
        if let description = options.description {
            let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedDescription.isEmpty {
                arguments += ["--description", normalizedDescription]
            }
        }
        arguments += ["--", name]
        _ = try await run(arguments)
    }

    private func run(
        _ arguments: [String],
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> ProcessCommandResult {
        guard let runner else { throw GitHubCLIError.notInstalled }
        do {
            return try await runner.run(
                arguments: arguments,
                environment: Self.commandEnvironment,
                acceptedExitCodes: acceptedExitCodes,
                outputLimit: ProcessRunner.defaultOutputLimit,
                timeout: ProcessRunner.networkTimeout,
                priority: .normal
            )
        } catch {
            throw GitHubCLIError.commandFailed(String(describing: error))
        }
    }
}
