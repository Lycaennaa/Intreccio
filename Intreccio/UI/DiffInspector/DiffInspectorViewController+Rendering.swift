import AppKit
@MainActor
extension DiffInspectorViewController {
    func render(
        mode: AppMode,
        hasRepository: Bool,
        hasSelection: Bool,
        state: SelectedDiffState,
        commitState: SelectedCommitState,
        diffGeneration: UInt64 = 0,
        commitGeneration: UInt64 = 0,
        repositoryID: UUID? = nil,
        selectedPaths: [GitPath] = []
    ) {
        guard isViewLoaded else { return }
        let diffPhase = DiffRenderPhase(state)
        let commitPhase = DiffRenderPhase(commitState)
        var currentContentIdentity = contentIdentity(
            mode: mode,
            repositoryID: repositoryID,
            hasSelection: hasSelection,
            selectedPaths: selectedPaths,
            selectedFileID: selectedFileID,
            commitState: commitState
        )
        let preservesVisibleContent = currentContentIdentity != nil && currentContentIdentity == lastContentIdentity
        let selectionChanged = mode == .changes
            && (hasSelection != lastHasSelection || selectedPaths != lastSelectedPaths)
        let sourceChanged = mode != lastMode
            || hasRepository != lastHasRepository
            || (mode == .history
                ? commitGeneration != lastCommitGeneration || commitPhase != lastCommitPhase
                : selectionChanged || diffGeneration != lastDiffGeneration || diffPhase != lastDiffPhase)
        let repositoryChanged: Bool
        if let repositoryID {
            repositoryChanged = presentationSnapshotID?.repositoryID != repositoryID
        } else {
            repositoryChanged = hasRepository && presentationSnapshotID == nil
        }
        let sourceRevisionChanged = repositoryChanged
            || mode != lastMode
            || (mode == .history
                ? commitGeneration != lastCommitGeneration
                : selectionChanged || diffGeneration != lastDiffGeneration)
        let unchanged = !sourceChanged && currentContentIdentity == lastContentIdentity
        guard !hasRendered || !unchanged else { return }
        renderTask?.cancel()
        renderTask = nil

        if sourceRevisionChanged {
            let retainsPresentation = preservesVisibleContent
                && currentPresentationModel != nil
                && mode == lastMode
                && !repositoryChanged
                && !selectionChanged
            if retainsPresentation, let selectedFileID {
                preferredFilePath = currentPresentationModel?.file(with: selectedFileID)?.path
                    ?? filePickerEntries.first(where: { $0.id == selectedFileID })?.path
            } else {
                preferredFilePath = nil
            }
            presentationSnapshotID = hasRepository
                ? DiffSnapshotID(repositoryID: repositoryID ?? UUID())
                : nil
            if retainsPresentation {
                presentationIsRetained = true
                markPresentationRetained("Loading updated diff; showing previous diff")
            } else {
                presentationIsRetained = false
                filePicker.isEnabled = false
                selectedFileID = nil
                currentPresentationModel = nil
                navigation = .empty
                currentHunkIndex = -1
                currentContentIdentity = contentIdentity(
                    mode: mode,
                    repositoryID: repositoryID,
                    hasSelection: hasSelection,
                    selectedPaths: selectedPaths,
                    selectedFileID: nil,
                    commitState: commitState
                )
            }
        }
        hasRendered = true
        lastMode = mode
        lastHasRepository = hasRepository
        lastHasSelection = hasSelection
        lastState = state
        lastCommitState = commitState
        lastDiffGeneration = diffGeneration
        lastCommitGeneration = commitGeneration
        lastDiffPhase = diffPhase
        lastCommitPhase = commitPhase
        lastContentIdentity = currentContentIdentity
        lastRepositoryID = repositoryID
        lastSelectedPaths = selectedPaths
        whitespaceGeneration &+= 1
        whitespaceButton.isHidden = mode == .history
        if mode == .history {
            renderCommit(
                state: commitState,
                hasRepository: hasRepository,
                preservesVisibleContent: preservesVisibleContent
            )
            return
        }
        guard hasRepository else {
            showState("Select a repository")
            return
        }
        if case .failed(let failure) = state {
            showFailure(failure, preservesVisibleContent: preservesVisibleContent)
            return
        }
        guard hasSelection else {
            showState("Select one or more changed files")
            return
        }
        switch state {
        case .idle:
            if preservesVisibleContent, hasVisibleText { return }
            showState("Loading diff")
        case .loading:
            if preservesVisibleContent, hasVisibleText { return }
            showState("Loading diff")
        case .failed:
            break
        case .loaded(let diff):
            if diff.files.isEmpty, diff.fallback == nil {
                showState("No changes in selection")
            } else {
                renderDiff(diff, preservesVisibleContent: preservesVisibleContent)
            }
        }
    }

    var hasVisibleText: Bool {
        !textView.isHidden && (textView.textStorage?.length ?? 0) > 0
    }

    func contentIdentity(
        mode: AppMode,
        repositoryID: UUID?,
        hasSelection: Bool,
        selectedPaths: [GitPath],
        selectedFileID: DiffFileID?,
        commitState: SelectedCommitState
    ) -> DiffContentIdentity? {
        guard let repositoryID else { return nil }
        switch mode {
        case .changes:
            guard hasSelection else { return nil }
            let sortedSelectedPaths = selectedPaths.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
            return .changes(
                repositoryID: repositoryID,
                kind: kind,
                paths: sortedSelectedPaths,
                fileID: selectedFileID
            )
        case .history:
            guard let objectID = commitState.commit?.objectID else { return nil }
            return .history(repositoryID: repositoryID, commitObjectID: objectID, fileID: selectedFileID)
        }
    }

    func applySummaryBar(_ summary: DiffSummaryModel) {
        summaryBarHeightConstraint?.constant = summaryBar.intrinsicContentSize.height
        summaryBar.apply(summary)
    }

    func clearSummaryBar() {
        summaryBar.clear()
        summaryBarHeightConstraint?.constant = 0
    }

    func showState(_ message: String) {
        clearFailurePresentation()
        clearSummaryBar()
        clearInteractionPresentation()
        selectedFileID = nil
        filePicker.isHidden = true
        stateLabel.stringValue = message
        stateLabel.isHidden = false
        textView.setAccessibilityLabel("Unified diff text")
        textView.isHidden = true
        textView.string = ""
    }

    func clearFailurePresentation() {
        displayedFailure = nil
        disclosureButton.title = "Show Error Details"
        disclosureButton.isHidden = true
        copyErrorButton.isHidden = true
    }
    func showFailure(_ failure: OperationFailure, preservesVisibleContent: Bool = false) {
        displayedFailure = failure
        if preservesVisibleContent, hasVisibleText {
            presentationIsRetained = true
            disclosureButton.isHidden = true
            copyErrorButton.isHidden = false
            stateLabel.stringValue = failure.title + "\n" + failure.recoverySuggestion
            stateLabel.isHidden = false
            copyRawButton.isEnabled = false
            updateFileActionControls()
            return
        }
        clearSummaryBar()
        clearInteractionPresentation()
        selectedFileID = nil
        filePicker.isHidden = true
        textView.setAccessibilityLabel("Git error details")
        disclosureButton.title = "Show Error Details"
        disclosureButton.isHidden = false
        copyErrorButton.isHidden = false
        stateLabel.stringValue = failure.title + "\n" + failure.recoverySuggestion
        stateLabel.isHidden = false
        textView.isHidden = true
        textView.string = failure.details
    }

    func renderCommit(
        state: SelectedCommitState,
        hasRepository: Bool,
        preservesVisibleContent: Bool
    ) {
        guard hasRepository else {
            showState("Select a repository")
            return
        }
        switch state {
        case .idle:
            showState("Select a commit")
        case .loading:
            if preservesVisibleContent, hasVisibleText { return }
            showState("Loading commit")
        case .failed(_, let failure):
            showFailure(failure, preservesVisibleContent: preservesVisibleContent)
        case .loaded(let details):
            clearFailurePresentation()
            guard let snapshotID = presentationSnapshotID else {
                showState("Select a repository")
                return
            }
            let model = DiffPresentationModel(
                diff: details.diff,
                snapshotID: snapshotID,
                metadata: details.metadata,
                rawPatch: .git(details.rawPatch)
            )
            let cachedPrefix = commitPrefixGeneration == lastCommitGeneration ? commitPrefix : nil
            renderFiles(
                model,
                prefix: cachedPrefix,
                commitDetails: cachedPrefix == nil ? details : nil,
                accessibilityLabel: "Commit details and unified patch",
                preservesVisibleContent: preservesVisibleContent
            )
        }
    }

    func renderDiff(_ diff: GitDiff, preservesVisibleContent: Bool) {
        clearFailurePresentation()
        guard let snapshotID = presentationSnapshotID else {
            showState("Select a repository")
            return
        }
        renderFiles(
            DiffPresentationModel(diff: diff, snapshotID: snapshotID),
            prefix: nil,
            commitDetails: nil,
            accessibilityLabel: "Unified diff",
            preservesVisibleContent: preservesVisibleContent
        )
    }

    func renderFiles(
        _ model: DiffPresentationModel,
        prefix: String?,
        commitDetails: CommitDetails?,
        accessibilityLabel: String,
        preservesVisibleContent: Bool
    ) {
        textView.setAccessibilityLabel(accessibilityLabel)
        let generation = whitespaceGeneration
        let showWhitespace = whitespaceButton.state == .on
        let requestedFileID = selectedFileID.flatMap { $0.snapshotID == model.snapshotID ? $0 : nil }
        let pickerMode = lastMode
        let summaryMode: DiffSummaryMode = switch pickerMode {
        case .changes: .changes
        case .history: .history
        }
        let pickerGeneration = lastMode == .history ? lastCommitGeneration : lastDiffGeneration
        let needsPicker = filePickerMode != pickerMode || filePickerGeneration != pickerGeneration
        let keepsCurrentPresentation = preservesVisibleContent && hasVisibleText
        if needsPicker {
            filePicker.isEnabled = false
            if !keepsCurrentPresentation { filePicker.isHidden = true }
        }
        if !keepsCurrentPresentation {
            clearSummaryBar()
            stateLabel.stringValue = "Rendering diff"
            stateLabel.isHidden = false
            textView.isHidden = true
        }
        let foldContext = foldContextButton.state == .on
        let scope: DiffPresentationScope = requestedFileID.map { .focused($0) } ?? .allFiles
        renderTask = Task { [weak self] in
            let fontSize = self?.diffFontSize ?? 12
            let prefixSource: DiffRenderPrefixSource
            if let prefix {
                prefixSource = .cached(prefix)
            } else if let commitDetails {
                prefixSource = .commit(commitDetails)
            } else {
                prefixSource = .none
            }
            let request = DiffRenderRequest(
                model: model,
                scope: scope,
                prefix: prefixSource,
                summaryMode: summaryMode,
                showWhitespace: showWhitespace,
                foldContext: foldContext,
                fontSize: fontSize,
                needsPicker: needsPicker
            )
            let worker: Task<DiffPreparedRender?, Never> = Task.detached(priority: .userInitiated) {
                DiffRenderPreparationBuilder.make(request)
            }
            let rendered = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let rendered, let self, !Task.isCancelled, whitespaceGeneration == generation else { return }
            if let picker = rendered.picker {
                applyFilePicker(picker, mode: pickerMode, generation: pickerGeneration)
            }
            let restoredFileSelection = requestedFileID == nil
                && preferredFilePath != nil
                && selectedFileID != nil
            preferredFilePath = nil
            if restoredFileSelection {
                lastContentIdentity = contentIdentity(
                    mode: lastMode,
                    repositoryID: lastRepositoryID,
                    hasSelection: lastHasSelection,
                    selectedPaths: lastSelectedPaths,
                    selectedFileID: selectedFileID,
                    commitState: lastCommitState
                )
                renderTask = nil
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
                return
            }
            applySummaryBar(rendered.summary)
            if commitDetails != nil, let prefix = rendered.prefix {
                commitPrefixGeneration = lastCommitGeneration
                commitPrefix = prefix
            }
            let effectiveFileID = selectedFileID
            lastContentIdentity = contentIdentity(
                mode: lastMode,
                repositoryID: lastRepositoryID,
                hasSelection: lastHasSelection,
                selectedPaths: lastSelectedPaths,
                selectedFileID: effectiveFileID,
                commitState: lastCommitState
            )
            let scrollOrigin = keepsCurrentPresentation ? scrollView.contentView.bounds.origin : .zero
            textView.textStorage?.setAttributedString(rendered.attributed)
            currentPresentationModel = model
            presentationIsRetained = false
            if lastRenderedScope != scope { currentHunkIndex = -1 }
            lastRenderedScope = scope
            navigation = rendered.navigation
            currentHunkIndex = min(currentHunkIndex, navigation.hunks.count - 1)
            stateLabel.isHidden = true
            textView.isHidden = false
            applyInteractionPresentation(
                model: model,
                scope: scope,
                renderLimited: rendered.summary.notices.contains(.renderLimited)
            )
            restoreScrollOrigin(scrollOrigin)
            renderTask = nil
        }
    }

    func restoreScrollOrigin(_ origin: NSPoint) {
        let clipView = scrollView.contentView
        let documentBounds = textView.bounds
        let maxX = max(documentBounds.minX, documentBounds.maxX - clipView.bounds.width)
        if documentBounds.height <= clipView.bounds.height {
            textView.scrollToBeginningOfDocument(nil)
            return
        }
        let maxY = max(documentBounds.minY, documentBounds.maxY - clipView.bounds.height)
        let constrainedOrigin = NSPoint(
            x: min(max(origin.x, documentBounds.minX), maxX),
            y: min(max(origin.y, documentBounds.minY), maxY)
        )
        clipView.scroll(to: constrainedOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    func applyFilePicker(_ picker: DiffFilePickerModel, mode: AppMode, generation: UInt64) {
        filePickerMode = mode
        filePickerGeneration = generation
        filePickerEntries = picker.entries
        let menu = filePicker.menu as? DiffFilePickerMenu ?? DiffFilePickerMenu()
        menu.delegate = menu
        filePicker.menu = menu
        menu.replaceEntries(picker.entries)
        filePicker.setVirtualEntries(picker.entries, selectedIndex: nil)
        filePicker.isEnabled = false
        guard picker.entries.count > 1 else {
            selectedFileID = nil
            filePicker.toolTip = nil
            filePicker.isHidden = true
            return
        }
        if let selectedFileID,
           let index = picker.entries.firstIndex(where: { $0.id == selectedFileID }) {
            filePicker.selectItem(at: index)
        } else if let preferredFilePath,
                  let index = picker.entries.firstIndex(where: { $0.path == preferredFilePath }) {
            selectedFileID = picker.entries[index].id
            filePicker.selectItem(at: index)
        } else {
            self.selectedFileID = nil
            filePicker.selectItem(at: 0)
        }
        filePicker.toolTip = picker.entries[filePicker.indexOfSelectedItem].title
        filePicker.setAccessibilityHelp(picker.entries[filePicker.indexOfSelectedItem].accessibilityText)
        filePicker.isHidden = false
        filePicker.isEnabled = true
    }

}
