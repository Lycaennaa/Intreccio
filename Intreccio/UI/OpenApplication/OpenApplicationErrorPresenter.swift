import AppKit

@MainActor
enum OpenApplicationErrorPresenter {
    static func present(
        window: NSWindow?,
        applicationName: String,
        paths: [String],
        description: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Open in \(applicationName)"
        alert.informativeText = paths.joined(separator: ", ") + "\n\n" + description
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
