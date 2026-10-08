import AppKit

@MainActor
enum SettingsUI {
    static func section(title: String, views: [NSView]) -> NSScrollView {
        let stack = NSStackView(views: [sectionLabel(title)] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor)
        ])
        return scroll
    }

    static func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .white
        return label
    }

    static func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        return label
    }

    static func row(_ views: NSView...) -> NSStackView {
        row(views)
    }

    static func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    static func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        return stack
    }

    static func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return box
    }

    static func smallButton(title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }
}
