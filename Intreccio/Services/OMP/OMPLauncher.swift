import AppKit
import Foundation

@MainActor
enum OMPLauncher {

    enum LaunchError: LocalizedError {
        case applicationNotInstalled(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .applicationNotInstalled(let applicationName): "\(applicationName) is not installed."
            case .failed(let description): description
            }
        }
    }

    static func open(
        in directoryURL: URL,
        expectedFileSystemID: String,
        repositoryID: UUID,
        using terminal: TerminalChoice,
        onError: @escaping @MainActor (String) -> Void
    ) throws {
        guard let application = terminal.installedApplication else {
            throw LaunchError.applicationNotInstalled(terminal.menuTitle)
        }
        switch terminal {
        case .appleTerminal:
            let scriptURL = try writeScript(
                in: directoryURL,
                expectedFileSystemID: expectedFileSystemID,
                repositoryID: repositoryID
            )
            LaunchServicesApplicationService.shared.open(
                [scriptURL],
                withApplicationAt: application.url,
                onError: onError
            )
        case .tern:
            let process = Process()
            process.executableURL = application.executableURL
            process.arguments = ternArguments(in: directoryURL, expectedFileSystemID: expectedFileSystemID)
            process.currentDirectoryURL = directoryURL
            do {
                try process.run()
            } catch {
                throw LaunchError.failed(error.localizedDescription)
            }
        }
    }

    static func ternArguments(in directoryURL: URL, expectedFileSystemID: String) -> [String] {
        [
            "-e",
            "/bin/zsh",
            "-l",
            "-c",
            ompCommand(in: directoryURL, expectedFileSystemID: expectedFileSystemID)
        ]
    }

    static func writeScript(
        in directoryURL: URL,
        expectedFileSystemID: String,
        repositoryID: UUID,
        scriptsDirectory: URL? = nil
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
        \(ompCommand(in: directoryURL, expectedFileSystemID: expectedFileSystemID))
        """ + "\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private static func ompCommand(in directoryURL: URL, expectedFileSystemID: String) -> String {
        [
            "cd -- \(shellQuotedPath(directoryURL.path)) || exit",
            "if [ \"$(/usr/bin/stat -f '%d:%i' .)\" != \(shellQuotedPath(expectedFileSystemID)) ]; then",
            "  printf '%s\\n' 'Repository changed before OMP launch.' >&2",
            "  exit 1",
            "fi",
            "exec omp"
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
