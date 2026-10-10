import AppKit

@MainActor
enum LocalRepositoryCreationPanel {
    static func present(
        on window: NSWindow,
        onCreate: @escaping @MainActor (String, URL, GitHubRepositoryCreationOptions?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Create Local Repository"
        alert.informativeText = "Create a local repository in a new folder. "
            + "Enable a GitHub remote to set its visibility and optional description. "
            + "Public repositories are visible to everyone; no files are uploaded."
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        nameField.placeholderString = "Repository name"
        nameField.setAccessibilityLabel("Local repository name")
        let remoteOptions = GitHubRemoteOptionsController()
        for field in [nameField, remoteOptions.descriptionField] {
            field.isEnabled = true
            field.isEditable = true
            field.isSelectable = true
            field.drawsBackground = true
            field.backgroundColor = NSColor(white: 0.04, alpha: 1)
            field.textColor = .white
        }
        let accessoryView = NSStackView(views: [
            nameField,
            remoteOptions.enableRemoteCheckbox,
            remoteOptions.optionsView
        ])
        accessoryView.orientation = .vertical
        accessoryView.alignment = .leading
        accessoryView.spacing = 8
        accessoryView.wantsLayer = true
        accessoryView.layer?.backgroundColor = NSColor.black.cgColor
        accessoryView.setFrameSize(NSSize(width: 420, height: accessoryView.fittingSize.height))
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.window.backgroundColor = .black
        alert.window.isOpaque = true
        alert.window.contentView?.wantsLayer = true
        alert.window.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        alert.window.initialFirstResponder = nameField
        remoteOptions.attach(accessoryView: accessoryView, alertWindow: alert.window)
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            guard let name = LocalRepositoryNamePolicy.normalized(nameField.stringValue) else {
                presentInvalidName(on: window)
                return
            }
            let githubOptions = remoteOptions.creationOptions
            presentDestinationPanel(on: window, repositoryName: name) { parentDirectory in
                onCreate(name, parentDirectory, githubOptions)
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

@MainActor
private final class GitHubRemoteOptionsController: NSObject {
    let enableRemoteCheckbox: NSButton
    let descriptionField: NSTextField
    let optionsView: NSStackView
    private let publicSwitch: NSSwitch
    private let visibilityStatusLabel: NSTextField
    private weak var accessoryView: NSStackView?
    private weak var alertWindow: NSWindow?

    override init() {
        enableRemoteCheckbox = NSButton(checkboxWithTitle: "Enable GitHub remote", target: nil, action: nil)
        descriptionField = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        publicSwitch = NSSwitch()
        let visibilityLabel = NSTextField(labelWithString: "Visibility")
        let stateLabel = NSTextField(labelWithString: "Private")
        visibilityStatusLabel = stateLabel
        visibilityLabel.textColor = .white
        stateLabel.textColor = .white
        let visibilityRow = NSStackView(views: [visibilityLabel, publicSwitch, stateLabel])
        visibilityRow.orientation = .horizontal
        visibilityRow.alignment = .centerY
        visibilityRow.spacing = 8
        optionsView = NSStackView(views: [descriptionField, visibilityRow])
        optionsView.orientation = .vertical
        optionsView.alignment = .leading
        optionsView.spacing = 8
        optionsView.isHidden = true
        optionsView.wantsLayer = true
        optionsView.layer?.backgroundColor = NSColor.black.cgColor
        super.init()
        publicSwitch.isEnabled = true
        publicSwitch.target = self
        publicSwitch.action = #selector(updateVisibilityStatus(_:))
        enableRemoteCheckbox.setAccessibilityLabel("Enable GitHub remote")
        descriptionField.placeholderString = "GitHub description (optional)"
        descriptionField.setAccessibilityLabel("GitHub repository description")
        publicSwitch.state = .off
        publicSwitch.setAccessibilityLabel("Make GitHub repository public")
        enableRemoteCheckbox.target = self
        enableRemoteCheckbox.action = #selector(toggleRemoteOptions(_:))
    }

    var creationOptions: GitHubRepositoryCreationOptions? {
        guard enableRemoteCheckbox.state == .on else { return nil }
        let description = descriptionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitHubRepositoryCreationOptions(
            visibility: publicSwitch.state == .on ? .publicRepository : .privateRepository,
            description: description.isEmpty ? nil : description
        )
    }

    func attach(accessoryView: NSStackView, alertWindow: NSWindow) {
        self.accessoryView = accessoryView
        self.alertWindow = alertWindow
    }

    @objc private func toggleRemoteOptions(_ sender: NSButton) {
        optionsView.isHidden = sender.state != .on
        guard let accessoryView else { return }
        let newHeight = accessoryView.fittingSize.height
        let heightChange = newHeight - accessoryView.frame.height
        guard heightChange != 0 else { return }
        accessoryView.setFrameSize(NSSize(width: accessoryView.frame.width, height: newHeight))
        guard let alertWindow else { return }
        var windowFrame = alertWindow.frame
        windowFrame.size.height += heightChange
        windowFrame.origin.y -= heightChange
        alertWindow.setFrame(windowFrame, display: true, animate: false)
    }

    @objc private func updateVisibilityStatus(_ sender: NSSwitch) {
        visibilityStatusLabel.stringValue = sender.state == .on ? "Public" : "Private"
    }
}
