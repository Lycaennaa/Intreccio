import AppKit

@MainActor
final class DiffSummaryBar: NSView {
    static let compactBreakpoint: CGFloat = 960

    let modeLabel = NSTextField(labelWithString: "")
    let fileCountLabel = NSTextField(labelWithString: "")
    let additionsLabel = NSTextField(labelWithString: "")
    let deletionsLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")

    private let stack = NSStackView()
    private var stackConstraints: [NSLayoutConstraint] = []
    private(set) var summary: DiffSummaryModel?
    private(set) var isCompactLayout = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func apply(_ summary: DiffSummaryModel) {
        self.summary = summary
        isHidden = false
        NSLayoutConstraint.activate(stackConstraints)
        updateLabels()
        setAccessibilityValue(summary.accessibilityText)
    }

    func clear() {
        summary = nil
        NSLayoutConstraint.deactivate(stackConstraints)
        isHidden = true
        modeLabel.stringValue = ""
        fileCountLabel.stringValue = ""
        additionsLabel.stringValue = ""
        deletionsLabel.stringValue = ""
        statusLabel.stringValue = ""
        setAccessibilityValue(nil)
    }

    override func layout() {
        super.layout()
        let compact = bounds.width < Self.compactBreakpoint
        if compact != isCompactLayout {
            isCompactLayout = compact
            updateLabels()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        layer?.cornerRadius = 6
        setAccessibilityLabel("Diff summary")

        let labels = [modeLabel, fileCountLabel, additionsLabel, deletionsLabel, statusLabel]
        for label in labels {
            label.font = .systemFont(ofSize: 11)
            label.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for label in [modeLabel, fileCountLabel, additionsLabel, deletionsLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        modeLabel.font = .boldSystemFont(ofSize: 11)
        additionsLabel.textColor = NSColor(calibratedRed: 0.48, green: 0.90, blue: 0.58, alpha: 1)
        deletionsLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.50, alpha: 1)
        statusLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.38, alpha: 1)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.addArrangedSubview(modeLabel)
        stack.addArrangedSubview(fileCountLabel)
        stack.addArrangedSubview(additionsLabel)
        stack.addArrangedSubview(deletionsLabel)
        stack.addArrangedSubview(statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stackConstraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ]
        clear()
    }

    private func updateLabels() {
        guard let summary else { return }
        modeLabel.stringValue = summary.mode.title
        fileCountLabel.stringValue = summary.fileCountText
        additionsLabel.stringValue = summary.additionsText
        deletionsLabel.stringValue = summary.deletionsText
        statusLabel.stringValue = (isCompactLayout ? summary.compactStatusText : summary.statusText) ?? ""
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        stack.spacing = isCompactLayout ? 8 : 10
    }
}
