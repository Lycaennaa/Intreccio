import AppKit

@MainActor
enum RepositoryClonePanel {
    static func present(
        on window: NSWindow,
        onClone: @escaping @MainActor ([URL], URL) -> Void
    ) {
        let controller = RepositoryCloneInputPanelController(hostWindow: window, onClone: onClone)
        let panel = RepositoryCloneInputPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        controller.loadViewIfNeeded()
        panel.contentViewController = controller
        controller.panel = panel
        panel.delegate = controller
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace]
        window.addChildWindow(panel, ordered: .above)
        panel.setFrameOrigin(
            NSPoint(
                x: window.frame.midX - panel.frame.width / 2,
                y: window.frame.midY - panel.frame.height / 2
            )
        )
        panel.makeKeyAndOrderFront(nil)
        panel.initialFirstResponder = controller.textView
        controller.startMonitoringOutsideClicks()
        panel.makeFirstResponder(controller.textView)
    }

    nonisolated static func cloneURLs(from input: String) -> [URL]? {
        let lines = input
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let cloneURLs = lines.compactMap { GitHubRepositoryURL.publicCloneURL(from: $0) }
        return cloneURLs.count == lines.count ? cloneURLs : nil
    }
}

@MainActor
private final class TransparentPlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor
private final class RepositoryCloneInputPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class PaddedButton: NSButton {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 32, height: size.height + 12)
    }
}

@MainActor
private final class RepositoryCloneInputPanelController: NSViewController, NSTextViewDelegate, NSWindowDelegate {
    private weak let hostWindow: NSWindow?
    private let onClone: @MainActor ([URL], URL) -> Void
    weak var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var placeholderLabel: NSTextField?
    private var errorLabel: NSTextField?
    private(set) var textView: NSTextView!

    init(hostWindow: NSWindow, onClone: @escaping @MainActor ([URL], URL) -> Void) {
        self.hostWindow = hostWindow
        self.onClone = onClone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 410))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.layer?.cornerRadius = 18

        let titleLabel = NSTextField(labelWithString: "Clone Public Repositories")
        titleLabel.font = .boldSystemFont(ofSize: 22)
        titleLabel.textColor = .white
        let descriptionLabel = NSTextField(labelWithString: "Enter one public GitHub repository URL per line. Submodules are initialized automatically. Git LFS must be installed for repositories that use it. Private repositories and authentication are not supported yet.")
        descriptionLabel.font = .systemFont(ofSize: 14)
        descriptionLabel.textColor = NSColor(white: 0.92, alpha: 1)
        descriptionLabel.maximumNumberOfLines = 4
        descriptionLabel.usesSingleLineMode = false
        descriptionLabel.lineBreakMode = .byWordWrapping

        let inputContainer = NSView()
        inputContainer.wantsLayer = true
        inputContainer.layer?.backgroundColor = NSColor(white: 0.04, alpha: 1).cgColor
        inputContainer.layer?.borderColor = NSColor(white: 0.22, alpha: 1).cgColor
        inputContainer.layer?.borderWidth = 1
        inputContainer.layer?.cornerRadius = 2

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.04, alpha: 1)
        textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(white: 0.04, alpha: 1)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.font = .systemFont(ofSize: 16)
        textView.typingAttributes = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 16),
        ]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.delegate = self
        textView.setAccessibilityLabel("Public GitHub repository URLs")
        scrollView.documentView = textView
        inputContainer.addSubview(scrollView)

        let placeholderLabel = TransparentPlaceholderLabel(frame: .zero)
        placeholderLabel.stringValue = "One public GitHub URL per line"
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = NSColor(white: 0.48, alpha: 1)
        placeholderLabel.font = .systemFont(ofSize: 16)
        placeholderLabel.isSelectable = false
        inputContainer.addSubview(placeholderLabel)

        let errorLabel = NSTextField(labelWithString: "Enter one or more valid public GitHub URLs.")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = NSColor.systemRed
        errorLabel.font = .systemFont(ofSize: 14)
        errorLabel.isHidden = true

        let cancelButton = PaddedButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        let continueButton = PaddedButton(title: "Continue", target: self, action: #selector(`continue`(_:)))
        styleButton(cancelButton)
        styleButton(continueButton)
        continueButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, continueButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(titleLabel)
        root.addSubview(descriptionLabel)
        root.addSubview(inputContainer)
        root.addSubview(errorLabel)
        root.addSubview(buttons)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        inputContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            inputContainer.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            inputContainer.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            inputContainer.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 16),
            inputContainer.heightAnchor.constraint(equalToConstant: 100),
            scrollView.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: inputContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 12),
            placeholderLabel.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: 6),
            buttons.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        self.placeholderLabel = placeholderLabel
        placeholderLabel.isHidden = true
        self.errorLabel = errorLabel
        view = root
    }

    func startMonitoringOutsideClicks() {
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible, event.window !== panel else { return event }
            self.dismiss()
            return event
        }
    }

    func textDidBeginEditing(_ notification: Notification) {
        placeholderLabel?.isHidden = true
    }

    func textDidEndEditing(_ notification: Notification) {
        placeholderLabel?.isHidden = !textView.string.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        if !textView.string.isEmpty {
            placeholderLabel?.isHidden = true
        }
        errorLabel?.isHidden = true
    }

    @objc private func cancel(_ sender: NSButton) {
        dismiss()
    }

    @objc private func `continue`(_ sender: NSButton) {
        guard let cloneURLs = RepositoryClonePanel.cloneURLs(from: textView.string) else {
            errorLabel?.isHidden = false
            panel?.makeFirstResponder(textView)
            return
        }
        dismiss()
        presentDestinationPanel(repositoryCount: cloneURLs.count) { [onClone] destinationParent in
            onClone(cloneURLs, destinationParent)
        }
    }

    private func presentDestinationPanel(
        repositoryCount: Int,
        onDestinationSelected: @escaping @MainActor (URL) -> Void
    ) {
        guard let hostWindow else { return }
        let panel = NSOpenPanel()
        panel.title = "Clone Repositories"
        panel.message = repositoryCount == 1
            ? "Choose an existing folder for the repository."
            : "Choose an existing folder for the \(repositoryCount) repositories."
        panel.prompt = "Clone"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.beginSheetModal(for: hostWindow) { response in
            guard response == .OK, let destinationParent = panel.url else { return }
            onDestinationSelected(destinationParent)
        }
    }

    private func styleButton(_ button: NSButton) {
        button.isBordered = false
        button.bezelStyle = .rounded
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        button.layer?.cornerRadius = 14
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func dismiss() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }


    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}