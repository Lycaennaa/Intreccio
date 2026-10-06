import AppKit

@MainActor
final class OpenApplicationRemovalDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let applicationURLs: [URL]
    private let applicationNames: [String]
    private let tableView = NSTableView()
    private let accessoryView: NSScrollView
    private weak var removeButton: NSButton?

    init(applicationURLs: [URL], applicationNames: [String]) {
        self.applicationURLs = applicationURLs
        self.applicationNames = applicationNames
        let rowHeight: CGFloat = 24
        let visibleWidth: CGFloat = 360
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let longestNameWidth = applicationNames
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let contentWidth = max(visibleWidth, ceil(longestNameWidth) + 24)
        let contentHeight = max(CGFloat(applicationURLs.count) * rowHeight, rowHeight)
        let visibleHeight = min(max(contentHeight, 72), 280)
        accessoryView = NSScrollView(frame: NSRect(x: 0, y: 0, width: visibleWidth, height: visibleHeight))
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Application"))
        column.title = "Application"
        column.width = contentWidth
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Applications to remove")
        tableView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        accessoryView.drawsBackground = true
        accessoryView.borderType = .noBorder
        accessoryView.hasVerticalScroller = contentHeight > visibleHeight
        accessoryView.hasHorizontalScroller = contentWidth > visibleWidth
        accessoryView.autohidesScrollers = true
        accessoryView.documentView = tableView
    }

    func present(
        from window: NSWindow?,
        darkAppearance: Bool = false,
        onRemove: @escaping ([URL]) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove Applications from List"
        alert.informativeText = "Select one or more applications. Hold Command or Shift to select multiple."
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if darkAppearance {
            alert.window.appearance = NSAppearance(named: .darkAqua)
            alert.window.backgroundColor = .black
            alert.window.isOpaque = true
            alert.window.contentView?.wantsLayer = true
            alert.window.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        }
        guard let removeButton = alert.buttons.first else { return }
        self.removeButton = removeButton
        removeButton.hasDestructiveAction = true
        removeButton.isEnabled = false

        // No manual key-view plumbing and no teardown mutations here. Prior
        // attempts crashed (EXC_BAD_ACCESS in -[NSView _removeFromKeyViewLoop])
        // because setNextKeyView: does not retain its target: once the alert's
        // buttons deallocated, the table's loop links dangled, and any later
        // delegate/dataSource reset forced NSTableRowData dealloc whose row
        // views walked those dangling links. AppKit manages the key view loop
        // and accessoryView lifetime correctly when left alone.
        // Strong self capture anchors the dialog for the sheet's lifetime;
        // dataSource/delegate are unretained, so nothing else keeps it alive.
        let completionHandler: (NSApplication.ModalResponse) -> Void = { [self] response in
            handleDismissal(
                response,
                selectedURLs: selectedApplicationURLs,
                onRemove: onRemove
            )
            // Bounce lifetime to the next runloop tick so the dialog, alert,
            // and table all deallocate after the modal-session teardown has
            // fully unwound instead of inside it.
            DispatchQueue.main.async { _ = self }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completionHandler)
        } else {
            completionHandler(alert.runModal())
        }
    }

    // Internal so tests can drive dismissal semantics without presenting a modal sheet.
    func handleDismissal(
        _ response: NSApplication.ModalResponse,
        selectedURLs: [URL],
        onRemove: ([URL]) -> Void
    ) {
        guard response == .alertFirstButtonReturn, !selectedURLs.isEmpty else { return }
        onRemove(selectedURLs)
    }

    private var selectedApplicationURLs: [URL] {
        tableView.selectedRowIndexes.compactMap { row in
            applicationURLs.indices.contains(row) ? applicationURLs[row] : nil
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        applicationURLs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard applicationNames.indices.contains(row), applicationURLs.indices.contains(row) else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: applicationNames[row])
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = applicationURLs[row].path
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton?.isEnabled = !selectedApplicationURLs.isEmpty
    }
}
