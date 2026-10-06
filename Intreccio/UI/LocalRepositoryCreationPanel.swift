import AppKit

@MainActor
enum LocalRepositoryCreationPanel {
    static func present(
        on window: NSWindow,
        onCreate: @escaping @MainActor (String, URL) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Create Local Repository"
        alert.informativeText = "Choose a name and an existing folder. A new repository folder will be created there."
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        nameField.placeholderString = "Repository name"
        nameField.setAccessibilityLabel("Local repository name")
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            guard let name = LocalRepositoryNamePolicy.normalized(nameField.stringValue) else {
                presentInvalidName(on: window)
                return
            }
            presentDestinationPanel(on: window, repositoryName: name) { parentDirectory in
                onCreate(name, parentDirectory)
            }
        }
    }

    private static func presentDestinationPanel(
        on window: NSWindow,
        repositoryName: String,
        onDestinationSelected: @escaping @MainActor (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "Create Local Repository"
        panel.message = "Choose an existing folder for \(repositoryName)."
        panel.prompt = "Create"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let parentDirectory = panel.url else { return }
            onDestinationSelected(parentDirectory)
        }
    }

    private static func presentInvalidName(on window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Invalid Repository Name"
        alert.informativeText = "Use a non-empty name without path separators."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

}