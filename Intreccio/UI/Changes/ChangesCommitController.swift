import AppKit

@MainActor
final class ChangesCommitController: NSObject, NSTextViewDelegate {
    final class PlaceholderTextView: NSTextView {
        static let maximumLength = 4_096

        var placeholderString = "" {
            didSet { needsDisplay = true }
        }
        var onInputRejected: (() -> Void)?

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty else { return }
            placeholderString.draw(
                at: NSPoint(x: textContainerInset.width + 1, y: textContainerInset.height),
                withAttributes: [
                    .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.placeholderTextColor
                ]
            )
        }

        override func insertText(_ insertString: Any, replacementRange: NSRange) {
            let replacement: String
            if let attributedString = insertString as? NSAttributedString {
                replacement = attributedString.string
            } else if let string = insertString as? String {
                replacement = string
            } else {
                super.insertText(insertString, replacementRange: replacementRange)
                return
            }

            let effectiveRange = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            let retainedLength = (string as NSString).length - effectiveRange.length
            let availableLength = max(Self.maximumLength - retainedLength, 0)
            var accepted = ""
            var acceptedLength = 0
            var previousWasNewline = false
            var rejectedInput = false
            for character in replacement {
                let acceptedCharacter: Character
                if character.isNewline {
                    guard !previousWasNewline else { continue }
                    acceptedCharacter = " "
                    previousWasNewline = true
                } else {
                    acceptedCharacter = character
                    previousWasNewline = false
                }
                let characterLength = acceptedCharacter.utf16.count
                guard acceptedLength + characterLength <= availableLength else {
                    rejectedInput = true
                    break
                }
                accepted.append(acceptedCharacter)
                acceptedLength += characterLength
            }
            super.insertText(accepted, replacementRange: effectiveRange)
            if rejectedInput { onInputRejected?() }
        }

        override func insertNewline(_ sender: Any?) {
            insertText(" ", replacementRange: selectedRange())
        }
    }

    let summaryTextView = PlaceholderTextView()
    let summaryScrollView = NSScrollView()
    let summaryOverflowLabel = NSTextField(labelWithString: "Scroll for more")
    let descriptionTextView = NSTextView()
    let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    let cancelAmendButton = NSButton(title: "Cancel Amend", target: nil, action: nil)

    private let coordinator: AppCoordinator
    private var summaryHeightConstraint: NSLayoutConstraint?
    private var summaryInputWasRejected = false
    private var hasBuiltView = false
#if DEBUG
    private(set) var stagedPathFallbackBuildCountForTesting = 0
#endif

    private(set) lazy var view: NSView = {
        hasBuiltView = true
        return makeView()
    }()

    var canCommit: Bool { hasBuiltView && commitButton.isEnabled }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func configure(status: RepoStatus?, snapshot: AppSnapshot, statusContent: RepositoryStatusContent? = nil) {
        guard hasBuiltView else { return }
        let components = Self.commitMessageComponents(snapshot.commitMessage)
        if summaryTextView.string != components.summary {
            summaryTextView.string = components.summary
            summaryTextView.needsDisplay = true
            summaryTextView.scrollToBeginningOfDocument(nil)
        }
        if descriptionTextView.string != components.description {
            descriptionTextView.string = components.description
        }

        let running = snapshot.mutationState == .running
        let rebaseInProgress = status?.isRebaseInProgress == true
        let normalMutationEnabled = !running && !rebaseInProgress
        let stagedPathCount: Int
        if let statusContent, status != nil {
            stagedPathCount = statusContent.stagedPathCount
        } else if let status {
#if DEBUG
            stagedPathFallbackBuildCountForTesting += 1
#endif
            stagedPathCount = RepositoryStatusContent(status: status).stagedPathCount
        } else {
            stagedPathCount = 0
        }
        let amending = snapshot.amendSession != nil
        commitButton.title = amending ? "Amend Last Commit" : (stagedPathCount == 0 ? "Commit" : "Commit \(stagedPathCount) Staged")
        commitButton.isEnabled = normalMutationEnabled
            && status != nil
            && (amending || stagedPathCount > 0)
            && !summaryTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        commitButton.setAccessibilityHelp(amending
            ? "Replace the last commit using this message and any staged changes."
            : "Commit staged changes using this message.")
        cancelAmendButton.isHidden = !amending
        cancelAmendButton.isEnabled = normalMutationEnabled
        summaryTextView.isEditable = normalMutationEnabled && status != nil
        descriptionTextView.isEditable = normalMutationEnabled && status != nil
    }

    func focusMessage(in window: NSWindow?) {
        _ = view
        window?.makeFirstResponder(summaryTextView)
    }

    func updateLayout() {
        summaryScrollView.layoutSubtreeIfNeeded()
        updateSummaryEditorLayout()
    }

    @objc func commit(_ sender: Any?) {
        guard canCommit else { return }
        coordinator.commit()
    }

    @objc func cancelAmend(_ sender: Any?) {
        guard coordinator.mutationState != .running else { return }
        coordinator.cancelAmendingCommit()
    }

    func textDidChange(_ notification: Notification) {
        updateCommitMessage()
    }

    func updateCommitMessage() {
        let summary = summaryTextView.string
        summaryInputWasRejected = false
        summaryTextView.needsDisplay = true
        updateSummaryEditorLayout()
        let description = descriptionTextView.string
        let message = description.isEmpty ? summary : summary + "\n\n" + description
        coordinator.setCommitMessage(message)
    }

    func updateSummaryEditorLayout() {
        guard let font = summaryTextView.font,
              let layoutManager = summaryTextView.layoutManager,
              let textContainer = summaryTextView.textContainer else { return }
        let editorWidth = max(summaryScrollView.contentSize.width, 1)
        if abs(summaryTextView.frame.width - editorWidth) > 0.5 {
            summaryTextView.setFrameSize(NSSize(width: editorWidth, height: summaryTextView.frame.height))
            textContainer.containerSize = NSSize(width: editorWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let insetHeight = summaryTextView.textContainerInset.height * 2
        let minimumHeight = ceil(lineHeight + insetHeight)
        let maximumHeight = ceil((lineHeight * 3) + insetHeight)
        let probeRect = NSRect(x: 0, y: 0, width: editorWidth, height: maximumHeight + lineHeight)
        layoutManager.ensureLayout(forBoundingRect: probeRect, in: textContainer)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: probeRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let measuredHeight = ceil(layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).height + insetHeight)
        let hasUnmeasuredText = NSMaxRange(characterRange) < (summaryTextView.textStorage?.length ?? 0)
        let hasOverflow = hasUnmeasuredText || measuredHeight > maximumHeight
        let contentHeight = hasOverflow ? maximumHeight : measuredHeight
        let visibleHeight = min(max(contentHeight, minimumHeight), maximumHeight) + 4
        if abs((summaryHeightConstraint?.constant ?? 0) - visibleHeight) > 0.5 {
            summaryHeightConstraint?.constant = visibleHeight
        }
        let reachedLimit = summaryInputWasRejected
            || (summaryTextView.textStorage?.length ?? 0) >= PlaceholderTextView.maximumLength
        switch (hasOverflow, reachedLimit) {
        case (true, true):
            summaryOverflowLabel.stringValue = "Scroll for more • 4,096 character limit reached"
        case (true, false):
            summaryOverflowLabel.stringValue = "Scroll for more"
        case (false, true):
            summaryOverflowLabel.stringValue = "4,096 character limit reached"
        case (false, false):
            summaryOverflowLabel.stringValue = "Scroll for more"
        }
        summaryOverflowLabel.setAccessibilityLabel(summaryOverflowLabel.stringValue)
        summaryOverflowLabel.isHidden = !hasOverflow && !reachedLimit
    }

    nonisolated static func commitMessageComponents(_ message: String) -> (summary: String, description: String) {
        guard let newline = message.firstIndex(of: "\n") else { return (message, "") }
        let summary = String(message[..<newline])
        var descriptionStart = message.index(after: newline)
        if descriptionStart < message.endIndex, message[descriptionStart] == "\n" {
            descriptionStart = message.index(after: descriptionStart)
        }
        return (summary, String(message[descriptionStart...]))
    }

    private func makeView() -> NSView {
        let summaryFieldLabel = NSTextField(labelWithString: "Summary")
        summaryFieldLabel.font = .preferredFont(forTextStyle: .caption1)
        summaryFieldLabel.textColor = .secondaryLabelColor
        summaryTextView.delegate = self
        summaryTextView.placeholderString = "Summary (required)"
        summaryTextView.isRichText = false
        summaryTextView.isAutomaticQuoteSubstitutionEnabled = false
        summaryTextView.isAutomaticDashSubstitutionEnabled = false
        summaryTextView.isAutomaticTextReplacementEnabled = false
        summaryTextView.isAutomaticSpellingCorrectionEnabled = false
        summaryTextView.allowsUndo = true
        summaryTextView.font = .preferredFont(forTextStyle: .body)
        summaryTextView.backgroundColor = .black
        summaryTextView.textColor = .labelColor
        summaryTextView.insertionPointColor = .white
        summaryTextView.isHorizontallyResizable = false
        summaryTextView.isVerticallyResizable = true
        summaryTextView.autoresizingMask = [.width]
        summaryTextView.textContainer?.widthTracksTextView = true
        summaryTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        summaryTextView.layoutManager?.allowsNonContiguousLayout = true
        summaryTextView.onInputRejected = { [weak self] in
            self?.summaryInputWasRejected = true
            self?.updateSummaryEditorLayout()
        }
        summaryTextView.setAccessibilityLabel("Commit summary")
        summaryTextView.setAccessibilityHelp("Enter the commit title. Press Command-Return to commit staged changes.")
        summaryScrollView.borderType = .bezelBorder
        summaryScrollView.drawsBackground = true
        summaryScrollView.backgroundColor = .black
        summaryScrollView.documentView = summaryTextView
        summaryScrollView.hasVerticalScroller = true
        summaryScrollView.autohidesScrollers = true
        let summaryFont = summaryTextView.font!
        let summaryLineHeight = summaryFont.ascender - summaryFont.descender + summaryFont.leading
        let summaryHeightConstraint = summaryScrollView.heightAnchor.constraint(equalToConstant: ceil(summaryLineHeight + 12))
        summaryHeightConstraint.isActive = true
        self.summaryHeightConstraint = summaryHeightConstraint
        summaryOverflowLabel.font = .preferredFont(forTextStyle: .caption2)
        summaryOverflowLabel.textColor = .secondaryLabelColor
        summaryOverflowLabel.isHidden = true
        summaryOverflowLabel.setAccessibilityLabel("Commit summary status")

        let descriptionLabel = NSTextField(labelWithString: "Description")
        descriptionLabel.font = .preferredFont(forTextStyle: .caption1)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionTextView.delegate = self
        descriptionTextView.isRichText = false
        descriptionTextView.isAutomaticQuoteSubstitutionEnabled = false
        descriptionTextView.isAutomaticDashSubstitutionEnabled = false
        descriptionTextView.isAutomaticTextReplacementEnabled = false
        descriptionTextView.isAutomaticSpellingCorrectionEnabled = false
        descriptionTextView.font = .preferredFont(forTextStyle: .body)
        descriptionTextView.backgroundColor = .black
        descriptionTextView.textColor = .labelColor
        descriptionTextView.insertionPointColor = .white
        descriptionTextView.setAccessibilityLabel("Commit description")
        descriptionTextView.setAccessibilityHelp("Enter an optional longer commit description. Press Command-Return to commit staged changes.")
        let descriptionScrollView = NSScrollView()
        descriptionScrollView.borderType = .bezelBorder
        descriptionScrollView.drawsBackground = true
        descriptionScrollView.backgroundColor = .black
        descriptionScrollView.documentView = descriptionTextView
        descriptionScrollView.hasVerticalScroller = true
        descriptionScrollView.heightAnchor.constraint(equalToConstant: 88).isActive = true

        commitButton.target = self
        commitButton.action = #selector(commit(_:))
        cancelAmendButton.target = self
        cancelAmendButton.action = #selector(cancelAmend(_:))
        let controls = NSStackView(
            views: [
                summaryFieldLabel,
                summaryScrollView,
                summaryOverflowLabel,
                descriptionLabel,
                descriptionScrollView,
                commitButton,
                cancelAmendButton
            ]
        )
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6
        for child in [summaryScrollView, descriptionScrollView, commitButton, cancelAmendButton] {
            child.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }
        return controls
    }
}
