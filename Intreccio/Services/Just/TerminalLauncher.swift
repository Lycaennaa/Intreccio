import AppKit
import CryptoKit
import Foundation

@MainActor
enum TerminalLauncher {
    enum LaunchError: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "No application could open the just recipe script."
            case .failed(let message):
                return message
            }
        }
    }

    static func open(
        command: String,
        repositoryURL: URL,
        repositoryID: UUID,
        recipeName: String
    ) throws {
        let scriptURL: URL
        do {
            scriptURL = try writeScript(
                command: command,
                repositoryURL: repositoryURL,
                repositoryID: repositoryID,
                recipeName: recipeName
            )
        } catch {
            throw LaunchError.failed(error.localizedDescription)
        }

        guard LaunchServicesApplicationService.shared.open(scriptURL) else {
            throw LaunchError.unavailable
        }
    }

    static func writeScript(
        command: String,
        repositoryURL: URL,
        repositoryID: UUID,
        recipeName: String,
        scriptsDirectory: URL? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let directoryURL = scriptsDirectory ?? defaultScriptsDirectory
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        let scriptURL = directoryURL.appendingPathComponent(
            scriptFilename(
                repositoryName: repositoryURL.lastPathComponent,
                repositoryID: repositoryID,
                recipeName: recipeName
            )
        )
        let script = """
        #!/bin/zsh
        if ! command -v just >/dev/null 2>&1; then
            printf '%s\\n' 'The just command was not found on PATH.'
            exit 127
        fi
        \(command)
        """
        let existingScript = try? String(contentsOf: scriptURL, encoding: .utf8)
        let existingPermissions = (try? fileManager.attributesOfItem(atPath: scriptURL.path))?[.posixPermissions]
            as? NSNumber
        if existingScript != script || existingPermissions?.intValue != 0o700 {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
        }
        return scriptURL
    }

    private static var defaultScriptsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Intreccio", isDirectory: true)
            .appendingPathComponent("Just Recipes", isDirectory: true)
    }

    private static func scriptFilename(
        repositoryName: String,
        repositoryID: UUID,
        recipeName: String
    ) -> String {
        let identity = Data("\(repositoryID.uuidString)\u{0}\(recipeName)".utf8)
        let digest = SHA256.hash(data: identity)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(filenameComponent(repositoryName, fallback: "repository"))--\(filenameComponent(recipeName, fallback: "recipe"))-\(digest).command"
    }

    private static func filenameComponent(_ value: String, fallback: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics
        let sanitized = value.lowercased().unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let component = sanitized.split(separator: "-").joined(separator: "-")
        return String(component.prefix(40)).isEmpty ? fallback : String(component.prefix(40))
    }
}
