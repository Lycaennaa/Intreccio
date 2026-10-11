import AppKit
import Foundation

@MainActor
enum TerminalChoice: String, CaseIterable, Equatable {
    case appleTerminal
    case tern

    var menuTitle: String {
        switch self {
        case .appleTerminal: "Apple Terminal"
        case .tern: "Tern"
        }
    }

    var installedApplication: (url: URL, executableURL: URL)? {
        let bundleIdentifier: String
        let fallbackPath: String
        switch self {
        case .appleTerminal:
            bundleIdentifier = "com.apple.Terminal"
            fallbackPath = "/System/Applications/Utilities/Terminal.app"
        case .tern:
            bundleIdentifier = "so.stencil.tern"
            fallbackPath = "/Applications/Tern.app"
        }

        let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            ?? URL(fileURLWithPath: fallbackPath, isDirectory: true)
        guard let bundle = Bundle(url: applicationURL),
              bundle.bundleIdentifier == bundleIdentifier,
              let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }
        return (applicationURL, executableURL)
    }
}
