import AppKit

@MainActor
enum RepositoryClonePanel {
    static func present(
        on window: NSWindow,
        loadRepositories: @escaping @MainActor () async throws -> [GitHubRepository],
        onClone: @escaping @MainActor ([URL], URL) -> Void
    ) {
        let controller = RepositoryCloneInputPanelController(
            hostWindow: window,
            loadRepositories: loadRepositories,
            onClone: onClone
        )
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
        let cloneURLs = lines.compactMap { GitHubRepositoryURL.cloneURL(from: $0) }
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
    private let loadRepositories: @MainActor () async throws -> [GitHubRepository]
    private let onClone: @MainActor ([URL], URL) -> Void
    weak var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var placeholderLabel: NSTextField?
    private var errorLabel: NSTextField?
    private var browseButton: NSButton?
    private var browseGeneration: UInt64 = 0
    private var browseTask: Task<Void, Never>?
    private var isShowingRepositoryPicker = false
    private(set) var textView: NSTextView!

    init(
        hostWindow: NSWindow,
        loadRepositories: @escaping @MainActor () async throws -> [GitHubRepository],
        onClone: @escaping @MainActor ([URL], URL) -> Void
    ) {
        self.hostWindow = hostWindow
        self.loadRepositories = loadRepositories
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

        let titleLabel = NSTextField(labelWithString: "Clone GitHub Repositories")
        titleLabel.font = .boldSystemFont(ofSize: 22)
        titleLabel.textColor = .white
        let descriptionLabel = makeDescriptionLabel()

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
            .font: NSFont.systemFont(ofSize: 16)
        ]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.delegate = self
        textView.setAccessibilityLabel("GitHub repository URLs")
        scrollView.documentView = textView
        inputContainer.addSubview(scrollView)

        let placeholderLabel = TransparentPlaceholderLabel(frame: .zero)
        placeholderLabel.stringValue = "One GitHub URL per line"
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = NSColor(white: 0.48, alpha: 1)
        placeholderLabel.font = .systemFont(ofSize: 16)
        placeholderLabel.isSelectable = false
        inputContainer.addSubview(placeholderLabel)

        let errorLabel = NSTextField(labelWithString: "Enter one or more valid GitHub repository URLs.")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = NSColor.systemRed
        errorLabel.maximumNumberOfLines = 3
        errorLabel.usesSingleLineMode = false
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.font = .systemFont(ofSize: 14)
        errorLabel.isHidden = true

        let buttons = makeButtonRow()

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
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        self.placeholderLabel = placeholderLabel
        placeholderLabel.isHidden = true
        self.errorLabel = errorLabel
        view = root
    }

    private func makeButtonRow() -> NSStackView {
        let browseButton = PaddedButton(
            title: "Browse My Repositories…",
            target: self,
            action: #selector(browseRepositories(_:))
        )
        let cancelButton = PaddedButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        let continueButton = PaddedButton(title: "Continue", target: self, action: #selector(`continue`(_:)))
        styleButton(browseButton)
        styleButton(cancelButton)
        styleButton(continueButton)
        continueButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [browseButton, cancelButton, continueButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        self.browseButton = browseButton
        return buttons
    }

    private func makeDescriptionLabel() -> NSTextField {
        let label = NSTextField(
            labelWithString: "Enter GitHub URLs or browse your repositories. "
                + "Private repositories require GitHub CLI (`gh`) signed in with `gh auth login` in Terminal."
        )
        label.font = .systemFont(ofSize: 14)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.maximumNumberOfLines = 4
        label.usesSingleLineMode = false
        label.lineBreakMode = .byWordWrapping
        return label
    }

    func startMonitoringOutsideClicks() {
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  !self.isShowingRepositoryPicker,
                  let panel = self.panel,
                  panel.isVisible,
                  event.window !== panel else { return event }
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
    @objc private func browseRepositories(_ sender: NSButton) {
        guard let panel, browseButton?.isEnabled != false else { return }
        browseGeneration &+= 1
        let generation = browseGeneration
        errorLabel?.isHidden = true
        browseButton?.isEnabled = false
        browseButton?.title = "Loading…"
        browseTask = Task { [weak self] in
            guard let self else { return }
            defer {
                browseTask = nil
                if generation == browseGeneration {
                    browseButton?.isEnabled = true
                    browseButton?.title = "Browse My Repositories…"
                }
            }
            do {
                let repositories = try await loadRepositories()
                guard generation == browseGeneration, panel.isVisible else { return }
                guard !repositories.isEmpty else {
                    errorLabel?.stringValue = "No repositories are available to this GitHub CLI account."
                    errorLabel?.isHidden = false
                    return
                }
                isShowingRepositoryPicker = true
                GitHubRepositoryPicker.present(on: panel, repositories: repositories) { [weak self] selected in
                    guard let self else { return }
                    isShowingRepositoryPicker = false
                    guard generation == browseGeneration, panel.isVisible, let selected else { return }
                    textView.string = selected.compactMap(\.cloneURL).map(\.absoluteString).joined(separator: "\n")
                    placeholderLabel?.isHidden = !textView.string.isEmpty
                    errorLabel?.isHidden = true
                }
            } catch {
                guard generation == browseGeneration, panel.isVisible else { return }
                errorLabel?.stringValue = String(describing: error)
                errorLabel?.isHidden = false
            }
        }
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
        browseTask?.cancel()
        browseTask = nil
        isShowingRepositoryPicker = false
        browseGeneration &+= 1
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
