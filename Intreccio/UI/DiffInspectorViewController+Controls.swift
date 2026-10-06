import AppKit
import CoreText
import os

@MainActor
extension DiffInspectorViewController {
    func updateWordWrap() {
        let origin = scrollView.contentView.bounds.origin
        let wraps = wrapButton.state == .on
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.widthTracksTextView = wraps
        textView.textContainer?.containerSize = NSSize(
            width: wraps ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.hasHorizontalScroller = !wraps
        restoreScrollOrigin(origin)
    }

    @objc func changeFile(_ sender: NSPopUpButton) {
        let expectedGeneration = lastMode == .history ? lastCommitGeneration : lastDiffGeneration
        guard filePickerMode == Optional(lastMode), filePickerGeneration == expectedGeneration else {
            sender.isEnabled = false
            return
        }
        let index = sender.indexOfSelectedItem
        guard filePickerEntries.indices.contains(index) else { return }
        selectedFileID = filePickerEntries[index].id
        currentHunkIndex = -1
        lastRenderedScope = nil
        updateHunkControls()
        sender.toolTip = filePickerEntries[index].title
        sender.setAccessibilityHelp(filePickerEntries[index].accessibilityText)
        hasRendered = false
        render(
            mode: lastMode,
            hasRepository: lastHasRepository,
            hasSelection: lastHasSelection,
            state: lastState,
            commitState: lastCommitState,
            diffGeneration: lastDiffGeneration,
            commitGeneration: lastCommitGeneration,
            repositoryID: lastRepositoryID,
            selectedPaths: lastSelectedPaths
        )
    }

    @objc func toggleWordWrap(_ sender: NSButton) {
        updateWordWrap()
    }

    @objc func toggleWhitespace(_ sender: NSButton) {
        onWhitespaceChange?(sender.state == .on)
        hasRendered = false
        render(
            mode: lastMode,
            hasRepository: lastHasRepository,
            hasSelection: lastHasSelection,
            state: lastState,
            commitState: lastCommitState,
            diffGeneration: lastDiffGeneration,
            commitGeneration: lastCommitGeneration,
            repositoryID: lastRepositoryID,
            selectedPaths: lastSelectedPaths
        )
    }

    /// Syncs persisted settings into the controls. Invalidates in-flight renders
    /// so the next render (triggered by the caller) picks up new font/whitespace.
    func applyDisplaySettings(fontSize: Double, showWhitespace: Bool) {
        let whitespaceChanged = (whitespaceButton.state == .on) != showWhitespace
        whitespaceButton.state = showWhitespace ? .on : .off
        let size = CGFloat(fontSize)
        guard size != diffFontSize || whitespaceChanged else { return }
        if size != diffFontSize {
            diffFontSize = size
            textView.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        whitespaceGeneration &+= 1
        renderTask?.cancel()
        renderTask = nil
        hasRendered = false
    }

    @objc func toggleErrorDetails(_ sender: NSButton) {
        guard displayedFailure != nil else { return }
        textView.isHidden.toggle()
        stateLabel.isHidden = !textView.isHidden
        disclosureButton.title = textView.isHidden ? "Show Error Details" : "Hide Error Details"
    }

    @objc func copyError(_ sender: NSButton) {
        guard let displayedFailure else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedFailure.copyText, forType: .string)
    }

}
