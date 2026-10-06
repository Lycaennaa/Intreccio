import AppKit

@MainActor
final class RepositoryDownloadManager: NSObject, NSWindowDelegate {
    @MainActor
    private final class Job {
        let id: UUID
        let sourceURL: URL
        let destinationParent: URL
        let displayName: String
        let order: UInt64
        var status: RepositoryDownloadStatus = .queued
        var progress: RepositoryCloneProgress?
        var control: ProcessControl?
        var operationTask: Task<Void, Never>?
        var progressTask: Task<Void, Never>?

        init(id: UUID, sourceURL: URL, destinationParent: URL, order: UInt64) {
            self.id = id
            self.sourceURL = sourceURL
            self.destinationParent = destinationParent
            displayName = sourceURL.deletingPathExtension().lastPathComponent
            self.order = order
        }
    }

    private let coordinator: AppCoordinator
    private var hostWindow: NSWindow?
    private weak var primaryWindow: NSWindow?
    private var panel: NSPanel?
    private var jobsStack: NSStackView?
    private var emptyLabel: NSTextField?
    private var rowViews: [UUID: RepositoryDownloadRowView] = [:]
    private var jobs: [UUID: Job] = [:]
    private var nextOrder: UInt64 = 0
    private var outsideClickMonitor: Any?

    var isBusy: Bool { jobs.values.contains { $0.status.isActive } }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
    }
    func attach(to window: NSWindow) {
        primaryWindow = window
    }

    func startClone(from sourceURL: URL, into destinationParent: URL, presentingWindow: NSWindow? = nil) {
        guard let presentationWindow = primaryWindow ?? presentingWindow else { return }
        let job = Job(
            id: UUID(),
            sourceURL: sourceURL,
            destinationParent: destinationParent,
            order: nextOrder
        )
        nextOrder &+= 1
        jobs[job.id] = job
        makePanelIfNeeded()
        rebuildRows()
        present(from: presentationWindow)
        begin(job)
    }

    func present(from window: NSWindow) {
        hostWindow = window
        makePanelIfNeeded()
        rebuildRows()
        guard let panel else { return }
        if let parent = panel.parent, parent !== window {
            parent.removeChildWindow(panel)
        }
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        let origin = NSPoint(
            x: window.frame.midX - panel.frame.width / 2,
            y: window.frame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    func cancelForTermination() -> Task<Void, Never>? {
        let activeTasks = jobs.values.compactMap { job -> Task<Void, Never>? in
            guard job.status.isActive, let task = job.operationTask else { return nil }
            cancel(job)
            return task
        }
        guard !activeTasks.isEmpty else {
            hidePanel()
            return nil
        }
        return Task {
            for task in activeTasks {
                await task.value
            }
        }
    }

    func finishTerminationWait() {
        hidePanel()
    }

    private func begin(_ job: Job) {
        job.status = .downloading
        updateRow(for: job)
        job.control = ProcessControl()
        let control = job.control
        let streamAndContinuation = AsyncStream<RepositoryCloneProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let progressTask = Task { [weak self] in
            for await update in streamAndContinuation.stream {
                guard let self else { return }
                self.receive(update, for: job.id)
            }
        }
        job.progressTask = progressTask

        let coordinator = self.coordinator
        let operationTask = Task { [weak self, coordinator, control, progressTask] in
            let result = await coordinator.cloneRepository(
                from: job.sourceURL,
                into: job.destinationParent,
                control: control,
                progress: { update in
                    streamAndContinuation.continuation.yield(update)
                }
            )
            streamAndContinuation.continuation.finish()
            await progressTask.value
            self?.complete(jobID: job.id, result: result)
        }
        job.operationTask = operationTask
    }

    private func receive(_ update: RepositoryCloneProgress, for jobID: UUID) {
        guard let job = jobs[jobID], job.status.isActive else { return }
        job.progress = update
        updateRow(for: job)
    }

    private func complete(jobID: UUID, result: RepositoryCloneResult) {
        guard let job = jobs[jobID] else { return }
        job.operationTask = nil
        job.progressTask = nil
        job.control = nil
        switch result {
        case .succeeded:
            job.status = .completed
        case .failed(let message):
            job.status = .failed(message)
        case .cancelled:
            job.status = .cancelled
        }
        updateRow(for: job)
    }

    private func pause(_ jobID: UUID) {
        guard let job = jobs[jobID], job.status == .downloading, let control = job.control else { return }
        guard control.pause() else {
            job.progress = RepositoryCloneProgress(detail: "Could not pause the Git process.", fractionCompleted: nil)
            updateRow(for: job)
            return
        }
        job.status = .paused
        updateRow(for: job)
    }

    private func resume(_ jobID: UUID) {
        guard let job = jobs[jobID], job.status == .paused, let control = job.control else { return }
        guard control.resume() else {
            job.progress = RepositoryCloneProgress(detail: "Could not resume the Git process.", fractionCompleted: nil)
            updateRow(for: job)
            return
        }
        job.status = .downloading
        updateRow(for: job)
    }

    private func togglePause(_ jobID: UUID) {
        guard let job = jobs[jobID] else { return }
        if job.status == .paused {
            resume(jobID)
        } else {
            pause(jobID)
        }
    }

    private func cancel(_ job: Job) {
        guard job.status.isActive, job.status != .cancelling else { return }
        _ = job.control?.resume()
        job.status = .cancelling
        updateRow(for: job)
        job.operationTask?.cancel()
    }

    private func cancel(_ jobID: UUID) {
        guard let job = jobs[jobID] else { return }
        cancel(job)
    }

    private func retry(_ jobID: UUID) {
        guard let job = jobs[jobID], job.status.isTerminal else { return }
        job.status = .queued
        job.progress = nil
        rebuildRows()
        begin(job)
    }

    private func remove(_ jobID: UUID) {
        guard let job = jobs[jobID], job.status.isTerminal else { return }
        jobs.removeValue(forKey: jobID)
        rebuildRows()
    }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Downloads"
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.delegate = self
        panel.minSize = NSSize(width: 480, height: 240)

        let header = NSTextField(labelWithString: "Downloads")
        header.font = .boldSystemFont(ofSize: 18)
        header.textColor = .white
        let emptyLabel = NSTextField(labelWithString: "No downloads")
        emptyLabel.textColor = NSColor(white: 0.65, alpha: 1)
        let jobsStack = NSStackView()
        jobsStack.orientation = .vertical
        jobsStack.alignment = .leading
        jobsStack.spacing = 10
        jobsStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = jobsStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.addSubview(header)
        contentView.addSubview(emptyLabel)
        contentView.addSubview(scrollView)
        header.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            emptyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            emptyLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            jobsStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            jobsStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            jobsStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 2),
            jobsStack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor, constant: -2),
        ])
        panel.contentView = contentView
        self.panel = panel
        self.jobsStack = jobsStack
        self.emptyLabel = emptyLabel
    }

    private func rebuildRows() {
        guard let jobsStack else { return }
        jobsStack.arrangedSubviews.forEach {
            jobsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rowViews.removeAll()
        let orderedJobs = jobs.values.sorted { $0.order < $1.order }
        emptyLabel?.isHidden = !orderedJobs.isEmpty
        for job in orderedJobs {
            let row = RepositoryDownloadRowView(jobID: job.id, title: job.displayName)
            row.onPause = { [weak self] jobID in self?.togglePause(jobID) }
            row.onCancel = { [weak self] jobID in self?.cancel(jobID) }
            row.onRetry = { [weak self] jobID in self?.retry(jobID) }
            row.onRemove = { [weak self] jobID in self?.remove(jobID) }
            rowViews[job.id] = row
            jobsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: jobsStack.widthAnchor).isActive = true
            updateRow(for: job)
        }
    }

    private func updateRow(for job: Job) {
        guard let row = rowViews[job.id] else { return }
        let detail = job.progress?.detail ?? defaultDetail(for: job.status)
        row.update(
            status: job.status,
            detail: detail,
            fractionCompleted: job.progress?.fractionCompleted
        )
    }

    private func defaultDetail(for status: RepositoryDownloadStatus) -> String {
        switch status {
        case .queued: return "Waiting for Git…"
        case .downloading: return "Preparing…"
        case .paused: return "Paused"
        case .cancelling: return "Cancelling…"
        case .completed: return "Repository added to Intreccio."
        case .failed: return ""
        case .cancelled: return "The clone operation was cancelled. You can retry it."
        }
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible, event.window !== panel else { return event }
            self.hidePanel()
            return event
        }
    }

    private func hidePanel() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func dismissPanel() {
        hidePanel()
    }

    func windowDidResignKey(_ notification: Notification) {
        hidePanel()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissPanel()
        return false
    }
}