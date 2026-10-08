import AppKit
final class DiffInspectorViewController: NSViewController, NSSearchFieldDelegate {
    let filePicker = DiffFilePickerButton(frame: .zero, pullsDown: false)
    let searchField = NSSearchField()
    let previousMatchButton = NSButton(title: "Previous Match", target: nil, action: nil)
    let nextMatchButton = NSButton(title: "Next Match", target: nil, action: nil)
    let searchResultsLabel = NSTextField(labelWithString: "")
    let previousHunkButton = NSButton(title: "Previous Hunk", target: nil, action: nil)
    let nextHunkButton = NSButton(title: "Next Hunk", target: nil, action: nil)
    let hunkStatusLabel = NSTextField(labelWithString: "")
    let wrapButton = NSButton(checkboxWithTitle: "Word wrap", target: nil, action: nil)
    let whitespaceButton = NSButton(checkboxWithTitle: "Show whitespace", target: nil, action: nil)
    let foldContextButton = NSButton(checkboxWithTitle: "Fold context", target: nil, action: nil)
    let showAllContextButton = NSButton(title: "Show All Context", target: nil, action: nil)
    let copyDisplayedButton = NSButton(title: "Copy Displayed Diff", target: nil, action: nil)
    let copyRawButton = NSButton(title: "Copy Raw Patch", target: nil, action: nil)
    let openFileButton = NSButton(title: "Open File", target: nil, action: nil)
    let revealFileButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    let retryFileButton = NSButton(title: "Retry File", target: nil, action: nil)
    let copyStatusLabel = NSTextField(labelWithString: "")
    let disclosureButton = NSButton(title: "Show Error Details", target: nil, action: nil)
    let copyErrorButton = NSButton(title: "Copy Error", target: nil, action: nil)
    let stateLabel = NSTextField(labelWithString: "Select a repository")
    let summaryBar = DiffSummaryBar()
    var summaryBarHeightConstraint: NSLayoutConstraint?
    let textView = DiffTextView()
    let scrollView = NSScrollView()
    let accessibilityProxy = NSView()
    var whitespaceGeneration: UInt64 = 0
    var renderTask: Task<Void, Never>?
    var selectedFileID: DiffFileID?
    var preferredFilePath: GitPath?
    var filePickerEntries: [DiffFilePickerEntry] = []
    var filePickerMode: AppMode?
    var filePickerGeneration: UInt64 = .max
    var commitPrefixGeneration: UInt64 = .max
    var commitPrefix: String?
    var lastMode: AppMode = .changes
    var presentationSnapshotID: DiffSnapshotID?
    var currentPresentationModel: DiffPresentationModel?
    var navigation = DiffTextNavigation.empty
    var currentHunkIndex = -1
    var presentationIsRetained = false
    var lastRenderedScope: DiffPresentationScope?
    var searchMatches: [NSRange] = []
    var currentSearchMatchIndex = -1
    var lastHasRepository = false
    var lastHasSelection = false
    var lastState: SelectedDiffState = .idle
    var lastCommitState: SelectedCommitState = .idle
    var lastDiffGeneration: UInt64 = .max
    var lastCommitGeneration: UInt64 = .max
    var lastDiffPhase: DiffRenderPhase = .idle
    var lastCommitPhase: DiffRenderPhase = .idle
    var lastContentIdentity: DiffContentIdentity?
    var lastRepositoryID: UUID?
    var lastSelectedPaths: [GitPath] = []
    var hasRendered = false
    var displayedFailure: OperationFailure?
    var diffFontSize: CGFloat = 12

    var onWhitespaceChange: ((Bool) -> Void)?
    var onFileAction: ((DiffFileAction) -> Void)?
    var onRetryUnavailableFile: ((DiffFileID) -> Void)?
    var kind: DiffKind { .uncommitted }

    deinit {
        renderTask?.cancel()
    }

    func cancelRendering() -> Task<Void, Never>? {
        whitespaceGeneration &+= 1
        let activeRender = renderTask
        activeRender?.cancel()
        renderTask = nil
        return activeRender
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.setAccessibilityLabel("Diff inspector")
        container.setAccessibilityRole(.group)

        filePicker.target = self
        let filePickerMenu = DiffFilePickerMenu()
        filePickerMenu.delegate = filePickerMenu
        filePicker.menu = filePickerMenu
        filePicker.action = #selector(changeFile(_:))
        filePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filePicker.setAccessibilityLabel("Diff file")
        filePicker.isHidden = true

        searchField.placeholderString = "Find in displayed diff"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityLabel("Search displayed diff")
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.isHidden = true
        previousMatchButton.target = self
        previousMatchButton.action = #selector(previousSearchMatch(_:))
        previousMatchButton.setAccessibilityLabel("Previous diff match")
        previousMatchButton.isEnabled = false
        nextMatchButton.target = self
        nextMatchButton.action = #selector(nextSearchMatch(_:))
        nextMatchButton.setAccessibilityLabel("Next diff match")
        nextMatchButton.isEnabled = false
        searchResultsLabel.setAccessibilityLabel("Diff search results")

        previousHunkButton.target = self
        previousHunkButton.action = #selector(previousHunk(_:))
        previousHunkButton.setAccessibilityLabel("Previous diff hunk")
        previousHunkButton.isEnabled = false
        nextHunkButton.target = self
        nextHunkButton.action = #selector(nextHunk(_:))
        nextHunkButton.setAccessibilityLabel("Next diff hunk")
        nextHunkButton.isEnabled = false
        hunkStatusLabel.setAccessibilityLabel("Diff hunk position")

        wrapButton.state = .on
        wrapButton.target = self
        wrapButton.action = #selector(toggleWordWrap(_:))
        whitespaceButton.target = self
        whitespaceButton.action = #selector(toggleWhitespace(_:))
        foldContextButton.target = self
        foldContextButton.action = #selector(toggleContextFolding(_:))
        foldContextButton.setAccessibilityLabel("Fold unchanged context")
        foldContextButton.isHidden = true
        showAllContextButton.target = self
        showAllContextButton.action = #selector(showAllContext(_:))
        showAllContextButton.setAccessibilityLabel("Show all unchanged context")
        showAllContextButton.isHidden = true

        copyDisplayedButton.target = self
        copyDisplayedButton.action = #selector(copyDisplayedDiff(_:))
        copyDisplayedButton.setAccessibilityLabel("Copy displayed diff")
        copyDisplayedButton.setAccessibilityHelp("Copies exactly the currently displayed text, including folds and metadata.")
        copyDisplayedButton.isHidden = true
        copyRawButton.target = self
        copyRawButton.action = #selector(copyRawPatch(_:))
        copyRawButton.setAccessibilityLabel("Copy raw patch")
        copyRawButton.setAccessibilityHelp("Copies complete Git output only when it is available and complete.")
        copyRawButton.isHidden = true

        openFileButton.target = self
        openFileButton.action = #selector(openSelectedFile(_:))
        openFileButton.setAccessibilityLabel("Open selected diff file")
        openFileButton.isHidden = true
        revealFileButton.target = self
        revealFileButton.action = #selector(revealSelectedFile(_:))
        revealFileButton.setAccessibilityLabel("Reveal selected diff file in Finder")
        revealFileButton.isHidden = true
        retryFileButton.target = self
        retryFileButton.action = #selector(retrySelectedFile(_:))
        retryFileButton.setAccessibilityLabel("Retry unavailable diff file")
        retryFileButton.isHidden = true
        copyStatusLabel.setAccessibilityLabel("Diff copy status")
        copyStatusLabel.isHidden = true

        disclosureButton.target = self
        disclosureButton.action = #selector(toggleErrorDetails(_:))
        disclosureButton.isHidden = true
        copyErrorButton.target = self
        copyErrorButton.action = #selector(copyError(_:))
        copyErrorButton.isHidden = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .black
        textView.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        textView.font = .monospacedSystemFont(ofSize: diffFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.setAccessibilityLabel("Unified diff text")
        textView.setAccessibilityHelp("Use Command-Option-Up and Command-Option-Down to navigate hunks. Search covers displayed text only.")
        textView.menu = makeDiffContextMenu()
        textView.onNextHunk = { [weak self] in self?.moveToNextHunk() }
        textView.onPreviousHunk = { [weak self] in self?.moveToPreviousHunk() }
        textView.onNextFile = { [weak self] in self?.moveToNextFile() }
        textView.onPreviousFile = { [weak self] in self?.moveToPreviousFile() }
        textView.onFocusSearch = { [weak self] in self?.focusSearch() }
        textView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        stateLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        stateLabel.alignment = .center
        stateLabel.maximumNumberOfLines = 4
        stateLabel.setAccessibilityRole(.staticText)

        accessibilityProxy.setAccessibilityLabel("Diff structure")
        accessibilityProxy.setAccessibilityRole(.group)
        accessibilityProxy.setAccessibilityElement(false)

        let wrapControls = NSStackView(views: [wrapButton])
        let searchControls = NSStackView(views: [searchField, previousMatchButton, nextMatchButton, searchResultsLabel])
        let hunkControls = NSStackView(views: [previousHunkButton, nextHunkButton, hunkStatusLabel])
        let optionControls = NSStackView(views: [whitespaceButton])
        let foldingControls = NSStackView(views: [foldContextButton, showAllContextButton])
        let copyControls = NSStackView(views: [copyDisplayedButton, copyRawButton])
        let fileActionControls = NSStackView(views: [openFileButton, revealFileButton, retryFileButton])
        let errorControls = NSStackView(views: [disclosureButton, copyErrorButton])
        let rows = [wrapControls, searchControls, hunkControls, optionControls, foldingControls, copyControls, fileActionControls, errorControls]
        for row in rows {
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
        }
        searchControls.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hunkControls.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [filePicker, wrapControls, searchControls, hunkControls, optionControls, foldingControls, copyControls, fileActionControls, errorControls, copyStatusLabel])
        controls.orientation = .vertical
        controls.spacing = 6
        controls.alignment = .leading

        for child in [controls, summaryBar, scrollView, stateLabel, accessibilityProxy] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        let summaryBarHeightConstraint = summaryBar.heightAnchor.constraint(equalToConstant: 0)
        self.summaryBarHeightConstraint = summaryBarHeightConstraint
        NSLayoutConstraint.activate([
            filePicker.widthAnchor.constraint(equalTo: controls.widthAnchor),
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            summaryBar.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 6),
            summaryBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            summaryBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            summaryBarHeightConstraint,
            scrollView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24),
            accessibilityProxy.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            accessibilityProxy.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            accessibilityProxy.widthAnchor.constraint(equalToConstant: 1),
            accessibilityProxy.heightAnchor.constraint(equalToConstant: 1)
        ])
        view = container
    }

}
