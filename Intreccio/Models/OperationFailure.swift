import Foundation

nonisolated struct OperationFailure: Sendable, Equatable {
    let title: String
    let recoverySuggestion: String
    let details: String

    var copyText: String {
        [title, recoverySuggestion, details].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func git(_ error: Error, title: String) -> OperationFailure {
        let details: String
        switch error {
        case ProcessRunnerError.nonZeroExit(let result):
            details = result.standardErrorText.isEmpty
                ? "Git exited with status \(result.exitCode)."
                : "Git exited with status \(result.exitCode).\n\n\(result.standardErrorText)"
        case ProcessRunnerError.timedOut(let result):
            details = "Git timed out with status \(result.exitCode).\n\n\(result.standardErrorText)"
        case ProcessRunnerError.cancelled(let result):
            details = "Git was cancelled with status \(result.exitCode).\n\n\(result.standardErrorText)"
        case ProcessRunnerError.outputLimitExceeded(let stream, let limit, let result):
            details = "Git \(stream.rawValue) exceeded the \(limit)-byte limit.\n\n\(result.standardErrorText)"
        default:
            details = String(describing: error)
        }
        return OperationFailure(
            title: title,
            recoverySuggestion: recoverySuggestion(for: details),
            details: details
        )
    }

    static func message(_ message: String, title: String, recoverySuggestion: String) -> OperationFailure {
        OperationFailure(title: title, recoverySuggestion: recoverySuggestion, details: message)
    }

    private static func recoverySuggestion(for details: String) -> String {
        let message = details.lowercased()
        if message.contains("user.name") || message.contains("user.email") || message.contains("author identity unknown") {
            return "Configure your Git name and email, then retry."
        }
        if message.contains("signing") || message.contains("failed to sign") || message.contains("gpg") || message.contains("ssh key") {
            return "Check your Git signing configuration and key access, then retry."
        }
        if message.contains("hook") {
            return "Review the hook output below, correct the hook failure, then retry."
        }
        if message.contains("index.lock") {
            return "Wait for other Git processes to finish. Remove a stale index lock only after confirming no Git process is using it."
        }
        if message.contains("conflict") || message.contains("could not apply") {
            return "Resolve each conflicted file, stage the resolutions with Git, then continue or abort the rebase."
        }
        if message.contains("permission denied") || message.contains("operation not permitted") {
            return "Check folder permissions or re-authorize the source, then retry."
        }
        if message.contains("timed out") {
            return "Check for a blocked hook or locked repository, then retry."
        }
        return "Review the Git details below, correct the reported issue, then retry."
    }
}
