import AppKit
import Foundation

@MainActor
enum OMPLauncher {
    enum Terminal: String, CaseIterable, Equatable {
        case terminal
        case tern

        var menuTitle: String {
            switch self {
            case .terminal: "Apple Terminal"
            case .tern: "Tern"
            }
        }
    }

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
        using terminal: Terminal,
        onError: @escaping @MainActor (String) -> Void
    ) throws {
        switch terminal {
        case .terminal:
            guard let applicationURL = applicationURL(
                bundleIdentifier: "com.apple.Terminal",
                fallbackPath: "/System/Applications/Utilities/Terminal.app"
            ) else {
                throw LaunchError.applicationNotInstalled(terminal.menuTitle)
            }
            let scriptURL = try writeScript(
                in: directoryURL,
                expectedFileSystemID: expectedFileSystemID,
                repositoryID: repositoryID
            )
            LaunchServicesApplicationService.shared.open(
                [scriptURL],
                withApplicationAt: applicationURL,
                onError: onError
            )
        case .tern:
            guard let applicationURL = applicationURL(
                bundleIdentifier: "so.stencil.tern",
                fallbackPath: "/Applications/Tern.app"
            ), let executableURL = Bundle(url: applicationURL)?.executableURL else {
                throw LaunchError.applicationNotInstalled(terminal.menuTitle)
            }
            let process = Process()
            process.executableURL = executableURL
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

    private static func applicationURL(bundleIdentifier: String, fallbackPath: String) -> URL? {
        let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            ?? URL(fileURLWithPath: fallbackPath, isDirectory: true)
        guard let bundle = Bundle(url: applicationURL),
              bundle.bundleIdentifier == bundleIdentifier,
              let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }
        return applicationURL
    }
}
