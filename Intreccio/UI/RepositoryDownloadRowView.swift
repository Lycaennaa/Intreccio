import AppKit

nonisolated enum RepositoryDownloadStatus: Sendable, Equatable {
    case queued
    case downloading
    case paused
    case cancelling
    case completed
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .downloading, .paused, .cancelling:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    var isTerminal: Bool { !isActive }
}

@MainActor
final class RepositoryDownloadRowView: NSView {
    let jobID: UUID
    var onPause: ((UUID) -> Void)?
    var onCancel: ((UUID) -> Void)?
    var onRetry: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?

    private let titleLabel: NSTextField
    private let statusLabel: NSTextField
    private let detailLabel: NSTextField
    private let progressIndicator: NSProgressIndicator
    private let pauseButton: NSButton
    private let cancelButton: NSButton
    private let retryButton: NSButton
    private let removeButton: NSButton

    init(jobID: UUID, title: String) {
        self.jobID = jobID
        titleLabel = NSTextField(labelWithString: title)
        statusLabel = NSTextField(labelWithString: "Queued")
        detailLabel = NSTextField(labelWithString: "Waiting…")
        progressIndicator = NSProgressIndicator()
        pauseButton = NSButton(title: "Pause", target: nil, action: nil)
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        retryButton = NSButton(title: "Retry", target: nil, action: nil)
        removeButton = NSButton(title: "Remove", target: nil, action: nil)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 1).cgColor
        layer?.cornerRadius = 8

        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = .white
        statusLabel.textColor = NSColor(white: 0.65, alpha: 1)
        detailLabel.textColor = NSColor(white: 0.8, alpha: 1)
        detailLabel.maximumNumberOfLines = 3
        detailLabel.usesSingleLineMode = false
        detailLabel.lineBreakMode = .byWordWrapping
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)

        pauseButton.target = self
        pauseButton.action = #selector(pause(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        removeButton.target = self
        removeButton.action = #selector(remove(_:))
        retryButton.isHidden = true
        removeButton.isHidden = true

        let header = NSStackView(views: [titleLabel, statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 8
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let buttons = NSStackView(views: [pauseButton, cancelButton, retryButton, removeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 6
        let stack = NSStackView(views: [header, detailLabel, progressIndicator, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func update(status: RepositoryDownloadStatus, detail: String, fractionCompleted: Double?) {
        statusLabel.stringValue = status.title
        detailLabel.stringValue = status.failureMessage ?? detail
        switch status {
        case .queued, .downloading:
            pauseButton.isHidden = false
            pauseButton.title = "Pause"
            pauseButton.isEnabled = true
            cancelButton.isHidden = false
            cancelButton.isEnabled = true
            retryButton.isHidden = true
            removeButton.isHidden = true
        case .paused:
            pauseButton.isHidden = false
            pauseButton.title = "Resume"
            pauseButton.isEnabled = true
            cancelButton.isHidden = false
            cancelButton.isEnabled = true
            retryButton.isHidden = true
            removeButton.isHidden = true
        case .cancelling:
            pauseButton.isHidden = true
            cancelButton.isHidden = true
            retryButton.isHidden = true
            removeButton.isHidden = true
        case .completed:
            pauseButton.isHidden = true
            cancelButton.isHidden = true
            retryButton.isHidden = true
            removeButton.isHidden = false
        case .failed, .cancelled:
            pauseButton.isHidden = true
            cancelButton.isHidden = true
            retryButton.isHidden = false
            removeButton.isHidden = false
        }

        let active = status == .queued || status == .downloading
        if active, fractionCompleted == nil {
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        } else {
            if progressIndicator.isIndeterminate {
                progressIndicator.isIndeterminate = false
                progressIndicator.stopAnimation(nil)
            }
            if let fractionCompleted {
                progressIndicator.doubleValue = min(max(fractionCompleted, 0), 1)
            } else if status == .completed {
                progressIndicator.doubleValue = 1
            }
        }
    }

    @objc private func pause(_ sender: NSButton) { onPause?(jobID) }
    @objc private func cancel(_ sender: NSButton) { onCancel?(jobID) }
    @objc private func retry(_ sender: NSButton) { onRetry?(jobID) }
    @objc private func remove(_ sender: NSButton) { onRemove?(jobID) }
}

private extension RepositoryDownloadStatus {
    var title: String {
        switch self {
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .cancelling: return "Cancelling"
        case .completed: return "Complete"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}