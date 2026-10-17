import Foundation

extension GitService {
    func configuredSubmodulePaths(
        repository: URL,
        priority: ProcessPriority = .normal
    ) async throws -> [String] {
        let result = try await runner.run(
            repository: repository,
            arguments: [
                "config", "--file", ".gitmodules", "--no-includes", "--null",
                "--get-regexp", #"^submodule\..*\.path$"#
            ],
            environment: readEnvironment,
            acceptedExitCodes: [0, 1],
            outputLimit: 256 * 1_024,
            priority: priority
        )
        guard result.exitCode == 0 else { return [] }

        return result.standardOutput
            .split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { record in
                guard let separator = record.firstIndex(of: 10),
                      let key = String(data: Data(record[..<separator]), encoding: .utf8),
                      key.hasPrefix("submodule."),
                      key.hasSuffix(".path") else { return nil }
                let valueStart = record.index(after: separator)
                return String(data: Data(record[valueStart...]), encoding: .utf8)
            }
    }
}
