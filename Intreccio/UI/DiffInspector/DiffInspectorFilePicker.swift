import AppKit

@MainActor
final class DiffFilePickerButton: NSPopUpButton {
    private var virtualEntries: [DiffFilePickerEntry] = []
    private var virtualSelectedIndex = -1

    func setVirtualEntries(_ entries: [DiffFilePickerEntry], selectedIndex: Int?) {
        virtualEntries = entries
        virtualSelectedIndex = selectedIndex ?? -1
    }

    override var numberOfItems: Int {
        virtualEntries.count
    }

    override var indexOfSelectedItem: Int {
        virtualSelectedIndex
    }

    override var titleOfSelectedItem: String? {
        guard virtualEntries.indices.contains(virtualSelectedIndex) else { return nil }
        return virtualEntries[virtualSelectedIndex].title
    }

    override func selectItem(at index: Int) {
        guard virtualEntries.indices.contains(index) else { return }
        virtualSelectedIndex = index
        if index < super.numberOfItems {
            super.selectItem(at: index)
        }
    }

    override func select(_ item: NSMenuItem?) {
        if let index = item?.representedObject as? Int,
           virtualEntries.indices.contains(index) {
            virtualSelectedIndex = index
        }
        super.select(item)
    }
}

@MainActor
final class DiffFilePickerMenuItemView: NSView {
    private let statusLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    init(entry: DiffFilePickerEntry) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        statusLabel.stringValue = entry.statusText
        pathLabel.stringValue = entry.pathTitle
        detailLabel.stringValue = [entry.countText, entry.stateText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        configure(statusLabel, bold: true, compressionResistance: .required)
        configure(pathLabel, bold: false, compressionResistance: .defaultLow)
        configure(detailLabel, bold: false, compressionResistance: .defaultLow)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        detailLabel.isHidden = detailLabel.stringValue.isEmpty
        setAccessibilityLabel(entry.accessibilityText)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(pathLabel)
        stack.addArrangedSubview(detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 360, height: 24)
    }

    private func configure(
        _ label: NSTextField,
        bold: Bool,
        compressionResistance: NSLayoutConstraint.Priority
    ) {
        label.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        label.textColor = .controlTextColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(compressionResistance, for: .horizontal)
    }
}

@MainActor
final class DiffFilePickerMenu: NSMenu, NSMenuDelegate {
    private var entries: [DiffFilePickerEntry] = []
    private static let eagerlyMaterializedEntryLimit = 32

    nonisolated override init(title: String) {
        super.init(title: title)
    }
    nonisolated init() {
        super.init(title: "Diff files")
    }

    required nonisolated init(coder: NSCoder) {
        super.init(coder: coder)
    }

    @MainActor
    func replaceEntries(_ entries: [DiffFilePickerEntry]) {
        self.entries = entries
        removeAllItems()
        guard entries.count <= Self.eagerlyMaterializedEntryLimit else { return }
        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.view = DiffFilePickerMenuItemView(entry: entry)
            item.representedObject = index
            item.toolTip = entry.title
            item.setAccessibilityHelp(entry.accessibilityText)
            addItem(item)
        }
    }

    @MainActor
    func numberOfItems(in menu: NSMenu) -> Int {
        entries.count
    }

    @MainActor
    func menu(_ menu: NSMenu, update item: NSMenuItem, at index: Int, shouldCancel: Bool) -> Bool {
        guard !shouldCancel, entries.indices.contains(index) else { return false }
        let entry = entries[index]
        item.title = entry.title
        item.view = DiffFilePickerMenuItemView(entry: entry)
        item.representedObject = index
        item.toolTip = entry.title
        item.setAccessibilityHelp(entry.accessibilityText)
        item.target = nil
        item.action = nil
        return true
    }
}
