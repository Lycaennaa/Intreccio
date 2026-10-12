import AppKit
import Foundation

@MainActor
enum OMPLauncher {
    enum TernLaunchMode: CaseIterable, Equatable {
        case newWindow
        case appendToWindow
        case splitView

        var menuTitle: String {
            switch self {
            case .newWindow: "New Window"
            case .appendToWindow: "Append to Window"
            case .splitView: "Split View"
            }
        }
    }

    enum Destination: Equatable {
        case appleTerminal
        case tern(TernLaunchMode)

        var applicationName: String {
            "OMP in \(terminalChoice.menuTitle)"
        }

        var terminalChoice: TerminalChoice {
            switch self {
            case .appleTerminal: .appleTerminal
            case .tern: .tern
            }
        }
    }

    static let defaultOMPExecutableURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("Tern", isDirectory: true)
        .appendingPathComponent("omp", isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("omp")

    enum LaunchError: LocalizedError {
        case applicationNotInstalled(String)
        case ompExecutableNotInstalled(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .applicationNotInstalled(let applicationName): "\(applicationName) is not installed."
            case .ompExecutableNotInstalled(let path): "Tern's OMP executable was not found at \(path)."
            case .failed(let description): description
            }
        }
    }

    static func open(
        in directoryURL: URL,
        expectedFileSystemID: String,
        repositoryID: UUID,
        to destination: Destination,
        onError: @escaping @MainActor (String) -> Void
    ) throws {
        let terminal = destination.terminalChoice
        guard let application = terminal.installedApplication else {
            throw LaunchError.applicationNotInstalled(terminal.menuTitle)
        }
        let ompExecutableURL = defaultOMPExecutableURL
        guard FileManager.default.isExecutableFile(atPath: ompExecutableURL.path) else {
            throw LaunchError.ompExecutableNotInstalled(ompExecutableURL.path)
        }
        switch destination {
        case .appleTerminal:
            let scriptURL = try writeScript(
                in: directoryURL,
                expectedFileSystemID: expectedFileSystemID,
                repositoryID: repositoryID,
                ompExecutableURL: ompExecutableURL
            )
            LaunchServicesApplicationService.shared.open(
                [scriptURL],
                withApplicationAt: application.url,
                onError: onError
            )
        case .tern(let windowMode):
            let process = Process()
            process.executableURL = application.executableURL
            process.arguments = ternArguments(
                in: directoryURL,
                expectedFileSystemID: expectedFileSystemID,
                windowMode: windowMode,
                ompExecutableURL: ompExecutableURL
            )
            process.currentDirectoryURL = directoryURL
            if windowMode != .newWindow {
                let standardError = Pipe()
                process.standardError = standardError
                process.terminationHandler = { process in
                    guard process.terminationStatus != 0 else { return }
                    let output = standardError.fileHandleForReading.readDataToEndOfFile()
                    let diagnostic = String(data: output, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let description = diagnostic.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "Tern could not open OMP in an existing window (exit code \(process.terminationStatus))."
                    Task { @MainActor in onError(description) }
                }
            }
            do {
                try process.run()
            } catch {
                throw LaunchError.failed(error.localizedDescription)
            }
        }
    }

    static func ternArguments(
        in directoryURL: URL,
        expectedFileSystemID: String,
        windowMode: TernLaunchMode = .newWindow,
        ompExecutableURL: URL
    ) -> [String] {
        let command = ompCommand(
            in: directoryURL,
            expectedFileSystemID: expectedFileSystemID,
            ompExecutableURL: ompExecutableURL
        )
        switch windowMode {
        case .newWindow:
            return ["-e", "/bin/zsh", "-l", "-c", command]
        case .appendToWindow:
            return [
                "new",
                "tab",
                "--cwd",
                directoryURL.path,
                "--",
                "/bin/zsh",
                "-l",
                "-c",
                command
            ]
        case .splitView:
            return [
                "split",
                "@focused",
                "right",
                "--cwd",
                directoryURL.path,
                "--",
                "/bin/zsh",
                "-l",
                "-c",
                command
            ]
        }
    }

    static func writeScript(
        in directoryURL: URL,
        expectedFileSystemID: String,
        repositoryID: UUID,
        scriptsDirectory: URL? = nil,
        ompExecutableURL: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let directory = scriptsDirectory ?? defaultScriptsDirectory
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let scriptURL = directory.appendingPathComponent("\(repositoryID.uuidString.lowercased()).command")
        let script = """
        #!/bin/zsh -l
        \(ompCommand(
            in: directoryURL,
            expectedFileSystemID: expectedFileSystemID,
            ompExecutableURL: ompExecutableURL
        ))
        """ + "\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private static func ompCommand(
        in directoryURL: URL,
        expectedFileSystemID: String,
        ompExecutableURL: URL
    ) -> String {
        [
            "cd -- \(shellQuotedPath(directoryURL.path)) || exit",
            "if [ \"$(/usr/bin/stat -f '%d:%i' .)\" != \(shellQuotedPath(expectedFileSystemID)) ]; then",
            "  printf '%s\\n' 'Repository changed before OMP launch.' >&2",
            "  exit 1",
            "fi",
            "exec \(shellQuotedPath(ompExecutableURL.path))"
        ].joined(separator: "\n")
    }

    private static func shellQuotedPath(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static var defaultScriptsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Intreccio", isDirectory: true)
            .appendingPathComponent("OMP", isDirectory: true)
    }

}
