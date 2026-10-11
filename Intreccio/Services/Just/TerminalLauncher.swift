import AppKit
import CryptoKit
import Foundation

@MainActor
enum TerminalLauncher {
    enum RunMode: String, CaseIterable, Equatable {
        case normal
        case closeTerminalWhenFinished

        var menuTitle: String {
            switch self {
            case .normal: "Leave Open"
            case .closeTerminalWhenFinished: "Close When Done"
            }
        }

        func completionScript(for terminal: TerminalChoice) -> String {
            guard terminal == .appleTerminal else { return "" }
            return switch self {
            case .normal:
                "exec /bin/zsh -l"
            case .closeTerminalWhenFinished:
                """
                /usr/bin/osascript - "$(/usr/bin/tty)" <<'APPLESCRIPT'
                on run argv
                    set targetTTY to item 1 of argv
                    tell application "Terminal"
                        repeat with terminalWindow in windows
                            repeat with terminalTab in tabs of terminalWindow
                                if (tty of terminalTab as text) is targetTTY then
                                    close terminalTab saving no
                                    return
                                end if
                            end repeat
                        end repeat
                    end tell
                    error "No Terminal tab found for tty " & targetTTY
                end run
                APPLESCRIPT
                """
            }
        }
    }

    enum LaunchError: LocalizedError {
        case applicationNotInstalled(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .applicationNotInstalled(let applicationName): "\(applicationName) is not installed."
            case .failed(let message): message
            }
        }
    }

    static func open(
        command: String,
        repositoryURL: URL,
        repositoryID: UUID,
        recipeName: String,
        terminal: TerminalChoice,
        runMode: RunMode,
        onError: @escaping @MainActor (String) -> Void
    ) throws {
        guard let application = terminal.installedApplication else {
            throw LaunchError.applicationNotInstalled(terminal.menuTitle)
        }
        let scriptURL: URL
        do {
            scriptURL = try writeScript(
                command: command,
                repositoryURL: repositoryURL,
                repositoryID: repositoryID,
                recipeName: recipeName,
                terminal: terminal,
                runMode: runMode
            )
        } catch {
            throw LaunchError.failed(error.localizedDescription)
        }

        switch terminal {
        case .appleTerminal:
            LaunchServicesApplicationService.shared.open(
                [scriptURL],
                withApplicationAt: application.url,
                onError: onError
            )
        case .tern:
            let process = Process()
            process.executableURL = application.executableURL
            process.arguments = ternArguments(for: scriptURL, runMode: runMode)
            process.currentDirectoryURL = repositoryURL
            do {
                try process.run()
            } catch {
                throw LaunchError.failed(error.localizedDescription)
            }
        }
    }

    static func ternArguments(for scriptURL: URL, runMode: RunMode) -> [String] {
        let command = runMode == .normal ? "\"$1\"; exec /bin/zsh -l" : "\"$1\""
        return ["-e", "/bin/zsh", "-l", "-c", command, "intreccio-just", scriptURL.path]
    }

    static func writeScript(
        command: String,
        repositoryURL: URL,
        repositoryID: UUID,
        recipeName: String,
        terminal: TerminalChoice,
        runMode: RunMode,
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
                recipeName: recipeName,
                terminal: terminal,
                runMode: runMode
            )
        )
        let script = """
        #!/bin/zsh
        if ! command -v just >/dev/null 2>&1; then
            printf '%s\\n' 'The just command was not found on PATH.'
            recipe_exit_code=127
        else
            \(command)
            recipe_exit_code=$?
        fi
        \(runMode.completionScript(for: terminal))
        exit "$recipe_exit_code"
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
        recipeName: String,
        terminal: TerminalChoice,
        runMode: RunMode
    ) -> String {
        let identity = Data("\(repositoryID.uuidString)\u{0}\(recipeName)\u{0}\(terminal.rawValue)\u{0}\(runMode.rawValue)".utf8)
        let digest = SHA256.hash(data: identity)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        let repositoryComponent = filenameComponent(repositoryName, fallback: "repository")
        let recipeComponent = filenameComponent(recipeName, fallback: "recipe")
        return "\(repositoryComponent)--\(recipeComponent)-\(digest).command"
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
