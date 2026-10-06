import Foundation

extension GitService {
    var readEnvironment: [String: String] {
        [
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0"
        ]
    }

    func statusEnvironment(for repository: URL) -> [String: String] {
        var environment = readEnvironment
        environment["GIT_CEILING_DIRECTORIES"] = RepositoryPathPolicy.canonicalURL(repository)
            .deletingLastPathComponent().path
        return environment
    }

    var mutationEnvironment: [String: String] {
        [
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
        ]
    }

    var rebaseEnvironment: [String: String] {
        var environment = mutationEnvironment
        environment["GIT_EDITOR"] = "/usr/bin/true"
        return environment
    }

    var networkEnvironment: [String: String] {
        [
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false",
        ]
    }
}
