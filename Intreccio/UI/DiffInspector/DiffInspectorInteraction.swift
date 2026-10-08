import AppKit

@MainActor
final class DiffTextView: NSTextView {
    var onNextHunk: (() -> Void)?
    var onPreviousHunk: (() -> Void)?
    var onNextFile: (() -> Void)?
    var onPreviousFile: (() -> Void)?
    var onFocusSearch: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), modifiers.contains(.option) else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 126:
            onPreviousHunk?()
        case 125:
            onNextHunk?()
        case 123:
            onPreviousFile?()
        case 124:
            onNextFile?()
        case 3 where event.charactersIgnoringModifiers?.lowercased() == "f":
            onFocusSearch?()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
extension DiffInspectorViewController: NSMenuItemValidation {
    func clearInteractionPresentation() {
        currentPresentationModel = nil
        presentationIsRetained = false
        navigation = .empty
        currentHunkIndex = -1
        lastRenderedScope = nil
        searchMatches = []
        currentSearchMatchIndex = -1
        filePickerEntries = []
        filePickerMode = nil
        filePickerGeneration = .max
        searchResultsLabel.stringValue = ""
        hunkStatusLabel.stringValue = ""
        copyStatusLabel.stringValue = ""
        searchField.stringValue = ""
        searchField.isHidden = true
        previousMatchButton.isEnabled = false
        nextMatchButton.isEnabled = false
        previousHunkButton.isEnabled = false
        nextHunkButton.isEnabled = false
        foldContextButton.isHidden = true
        showAllContextButton.isHidden = true
        copyDisplayedButton.isHidden = true
        copyRawButton.isHidden = true
        openFileButton.isHidden = true
        revealFileButton.isHidden = true
        retryFileButton.isHidden = true
        copyStatusLabel.isHidden = true
        accessibilityProxy.setAccessibilityChildren([])
    }

    func applyInteractionPresentation(
        model: DiffPresentationModel,
        scope: DiffPresentationScope,
        renderLimited: Bool
    ) {
        searchField.isHidden = false
        foldContextButton.isHidden = false
        copyDisplayedButton.isHidden = false
        copyRawButton.isHidden = false
        copyRawButton.isEnabled = true
        openFileButton.isHidden = false
        revealFileButton.isHidden = false
        retryFileButton.isHidden = false
        updateHunkControls()
        updateFileActionControls()
        updateSearchMatches(keepCurrentMatch: true)
        updateAccessibilityHierarchy(model: model, scope: scope, renderLimited: renderLimited)
        showAllContextButton.isHidden = foldContextButton.state != .on || navigation.foldedContexts.isEmpty
    }

    func markPresentationRetained(_ message: String) {
        stateLabel.stringValue = message
        stateLabel.isHidden = false
        copyRawButton.isEnabled = false
        updateFileActionControls()
        updateSearchControls()
        updateHunkControls()
    }

    func focusSearch() {
        guard !searchField.isHidden else { return }
        view.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    var canNavigateDiffHunks: Bool {
        !textView.isHidden && !presentationIsRetained && !navigation.hunks.isEmpty
    }

    var canNavigateDiffFiles: Bool {
        !textView.isHidden && !presentationIsRetained && filePickerEntries.count > 2
    }

    var canSearchDiff: Bool {
        !textView.isHidden && !presentationIsRetained
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        updateSearchMatches(keepCurrentMatch: false)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        updateSearchMatches(keepCurrentMatch: false)
    }

    func updateSearchMatches(keepCurrentMatch: Bool) {
        let oldMatch = keepCurrentMatch && currentSearchMatchIndex >= 0
            ? searchMatches[safe: currentSearchMatchIndex]
            : nil
        searchMatches = DiffSearchMatcher.matches(in: textView.string, query: searchField.stringValue)
        if searchMatches.isEmpty {
            currentSearchMatchIndex = -1
        } else if let oldMatch,
                  let index = searchMatches.firstIndex(of: oldMatch) {
            currentSearchMatchIndex = index
        } else {
            currentSearchMatchIndex = min(max(currentSearchMatchIndex, 0), searchMatches.count - 1)
        }
        updateSearchControls()
    }

    @objc func nextSearchMatch(_ sender: NSButton) {
        moveToSearchMatch(offset: 1)
    }

    @objc func previousSearchMatch(_ sender: NSButton) {
        moveToSearchMatch(offset: -1)
    }

    private func moveToSearchMatch(offset: Int) {
        guard !searchMatches.isEmpty else { return }
        let start = currentSearchMatchIndex < 0 ? 0 : currentSearchMatchIndex
        currentSearchMatchIndex = (start + offset + searchMatches.count) % searchMatches.count
        let range = searchMatches[currentSearchMatchIndex]
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
        updateSearchControls()
    }

    private func updateSearchControls() {
        let count = searchMatches.count
        let hasQuery = !searchField.stringValue.isEmpty
        previousMatchButton.isEnabled = hasQuery && count > 0
        nextMatchButton.isEnabled = hasQuery && count > 0
        if !hasQuery {
            searchResultsLabel.stringValue = ""
        } else if count == 0 {
            searchResultsLabel.stringValue = "No matches"
        } else {
            searchResultsLabel.stringValue = String(currentSearchMatchIndex + 1) + " of " + String(count)
        }
        searchResultsLabel.setAccessibilityValue(searchResultsLabel.stringValue)
    }

    @objc func nextHunk(_ sender: NSButton) {
        moveToNextHunk()
    }

    @objc func previousHunk(_ sender: NSButton) {
        moveToPreviousHunk()
    }

    func moveToNextHunk() {
        moveToHunk(offset: 1)
    }

    func moveToPreviousHunk() {
        moveToHunk(offset: -1)
    }

    private func moveToHunk(offset: Int) {
        guard !navigation.hunks.isEmpty else { return }
        let start = currentHunkIndex < 0 ? (offset > 0 ? -1 : 0) : currentHunkIndex
        currentHunkIndex = (start + offset + navigation.hunks.count) % navigation.hunks.count
        let target = navigation.hunks[currentHunkIndex]
        textView.scrollRangeToVisible(target.range)
        textView.showFindIndicator(for: target.range)
        updateHunkControls()
    }

    func updateHunkControls() {
        let count = navigation.hunks.count
        previousHunkButton.isEnabled = count > 0
        nextHunkButton.isEnabled = count > 0
        if count == 0 {
            hunkStatusLabel.stringValue = "No hunks"
        } else if currentHunkIndex >= 0 {
            hunkStatusLabel.stringValue = "Hunk " + String(currentHunkIndex + 1) + " of " + String(count)
        } else {
            hunkStatusLabel.stringValue = String(count) + (count == 1 ? " hunk" : " hunks")
        }
        hunkStatusLabel.setAccessibilityValue(hunkStatusLabel.stringValue)
    }

    func moveToNextFile() {
        moveToFile(offset: 1)
    }

    func moveToPreviousFile() {
        moveToFile(offset: -1)
    }

    private func moveToFile(offset: Int) {
        guard let nextIndex = DiffFileNavigator.targetIndex(
            selectedIndex: filePicker.indexOfSelectedItem,
            entryCount: filePickerEntries.count,
            offset: offset
        ) else { return }
        filePicker.selectItem(at: nextIndex)
        changeFile(filePicker)
    }

    @objc func toggleContextFolding(_ sender: NSButton) {
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

    @objc func showAllContext(_ sender: NSButton) {
        foldContextButton.state = .off
        toggleContextFolding(foldContextButton)
    }

    @objc func copyDisplayedDiff(_ sender: Any?) {
        guard displayedFailure == nil, !textView.isHidden else {
            showCopyStatus("Displayed diff unavailable while no current diff is loaded.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        showCopyStatus("Displayed diff copied.")
    }

    @objc func copyRawPatch(_ sender: Any?) {
        guard !presentationIsRetained,
              displayedFailure == nil,
              let model = currentPresentationModel else {
            showCopyStatus("Raw patch unavailable while no current diff is loaded.")
            return
        }
        let availability = DiffRawCopyAvailability(model.rawPatch)
        guard let bytes = model.rawPatch.exactGitBytes else {
            showCopyStatus(availability.failureMessage)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(bytes, forType: NSPasteboard.PasteboardType("public.data"))
        if let string = String(data: bytes, encoding: .utf8) {
            NSPasteboard.general.setString(string, forType: .string)
        }
        showCopyStatus("Complete Git raw patch copied.")
    }

    private func showCopyStatus(_ message: String) {
        copyStatusLabel.stringValue = message
        copyStatusLabel.isHidden = message.isEmpty
        copyStatusLabel.setAccessibilityValue(message)
    }

    private var focusedFileForActions: DiffPresentationFile? {
        guard let model = currentPresentationModel else { return nil }
        if let selectedFileID {
            return model.file(with: selectedFileID)
        }
        return model.files.count == 1 ? model.files.first : nil
    }

    private var selectedFileCanBeAddressed: Bool {
        guard displayedFailure == nil,
              let file = focusedFileForActions,
              file.path.isFileActionAddressable else { return false }
        guard case .content(let content) = file.state else { return false }
        if case .unavailable(.invalidPath) = content { return false }
        return true
    }

    private var selectedFileCanRetry: Bool {
        guard !presentationIsRetained,
              let file = focusedFileForActions,
              case .content(.unavailable(let reason)) = file.state else { return false }
        return reason.isRetryable
    }

    func updateFileActionControls() {
        let hasFile = focusedFileForActions != nil
        openFileButton.isEnabled = hasFile && selectedFileCanBeAddressed
        revealFileButton.isEnabled = hasFile && selectedFileCanBeAddressed
        retryFileButton.isEnabled = selectedFileCanRetry
        let help: String
        if let file = focusedFileForActions {
            help = file.path.isFileActionAddressable
                ? "Actions validate repository containment, resource type, and file identity immediately before launch."
                : "This path is not safely addressable."
        } else {
            help = "Select one file before opening or revealing it."
        }
        openFileButton.setAccessibilityHelp(help)
        revealFileButton.setAccessibilityHelp(help)
        retryFileButton.setAccessibilityHelp(selectedFileCanRetry ? "Retries reading this unavailable file while keeping valid sibling files navigable." : "No retryable unavailable file is selected.")
    }

    @objc func openSelectedFile(_ sender: NSButton) {
        guard selectedFileCanBeAddressed, let file = focusedFileForActions else {
            showCopyStatus("File cannot be opened safely.")
            return
        }
        onFileAction?(.open(file.path))
    }

    @objc func revealSelectedFile(_ sender: NSButton) {
        guard selectedFileCanBeAddressed, let file = focusedFileForActions else {
            showCopyStatus("File cannot be revealed safely.")
            return
        }
        onFileAction?(.reveal(file.path))
    }

    @objc func retrySelectedFile(_ sender: NSButton) {
        guard selectedFileCanRetry, let file = focusedFileForActions else { return }
        onRetryUnavailableFile?(file.id)
    }

    func makeDiffContextMenu() -> NSMenu {
        let menu = NSMenu()
        let copySelection = NSMenuItem(title: "Copy Selection", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copySelection.target = nil
        menu.addItem(copySelection)
        menu.addItem(.separator())
        let copyDisplayed = NSMenuItem(title: "Copy Displayed Diff", action: #selector(copyDisplayedDiff(_:)), keyEquivalent: "")
        copyDisplayed.target = self
        menu.addItem(copyDisplayed)
        let copyRaw = NSMenuItem(title: "Copy Raw Patch", action: #selector(copyRawPatch(_:)), keyEquivalent: "")
        copyRaw.target = self
        menu.addItem(copyRaw)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open File", action: #selector(openSelectedFile(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealSelectedFile(_:)), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        if action == #selector(NSText.copy(_:)) {
            return displayedFailure == nil && !textView.isHidden && textView.selectedRange().length > 0
        }
        if action == #selector(copyDisplayedDiff(_:)) {
            return displayedFailure == nil && !textView.isHidden
        }
        if action == #selector(copyRawPatch(_:)) {
            return displayedFailure == nil && !presentationIsRetained && currentPresentationModel != nil
        }
        if action == #selector(openSelectedFile(_:)) || action == #selector(revealSelectedFile(_:)) {
            return selectedFileCanBeAddressed
        }
        if action == #selector(retrySelectedFile(_:)) {
            return selectedFileCanRetry
        }
        return true
    }

    func updateAccessibilityHierarchy(
        model: DiffPresentationModel,
        scope: DiffPresentationScope,
        renderLimited: Bool
    ) {
        let snapshot = DiffAccessibilityBuilder.make(
            for: model,
            scope: scope,
            foldContext: foldContextButton.state == .on,
            renderLimited: renderLimited
        )
        let frame = textView.window.map { window in
            window.convertToScreen(textView.convert(textView.bounds, to: nil))
        } ?? .zero
        let elements = makeAccessibilityElements(node: snapshot, parent: accessibilityProxy, frame: frame)
        accessibilityProxy.setAccessibilityChildren(elements)
        textView.setAccessibilityValue(snapshot.value ?? snapshot.label)
        textView.setAccessibilityHelp("Displayed diff structure contains files, hunks, and line status. " + DiffRawCopyAvailability(model.rawPatch).accessibilityText + ".")
    }

    private func makeAccessibilityElements(
        node: DiffAccessibilityNode,
        parent: Any,
        frame: NSRect
    ) -> [Any] {
        let element = NSAccessibilityElement()
        let role: NSAccessibility.Role = switch node.kind {
        case .line, .state: .staticText
        case .root, .file, .hunk, .foldedContext: .group
        }
        element.setAccessibilityRole(role)
        element.setAccessibilityLabel(node.label)
        if let value = node.value { element.setAccessibilityValue(value) }
        element.setAccessibilityParent(parent)
        element.setAccessibilityFrame(frame)
        let children = node.children.flatMap {
            makeAccessibilityElements(node: $0, parent: element, frame: frame)
        }
        element.setAccessibilityChildren(children)
        return [element]
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
