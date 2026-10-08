import AppKit

@MainActor
final class DiffSettingsViewController: NSViewController, SettingsSectionController {
    static let fontSizes: [(label: String, size: Double)] = [
        ("Small (11 pt)", 11),
        ("Default (12 pt)", 12),
        ("Large (13 pt)", 13),
        ("Larger (14 pt)", 14)
    ]

    private let coordinator: AppCoordinator
    private let fontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let whitespaceCheck = NSButton(
        checkboxWithTitle: "Show whitespace in diffs",
        target: nil,
        action: nil
    )

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        fontSizePopup.target = self
        fontSizePopup.action = #selector(changeFontSize(_:))
        fontSizePopup.addItems(withTitles: Self.fontSizes.map(\.label))
        whitespaceCheck.target = self
        whitespaceCheck.action = #selector(toggleWhitespace(_:))
        view = SettingsUI.section(title: "Diff", views: [
            SettingsUI.row(SettingsUI.label("Font size"), fontSizePopup),
            whitespaceCheck
        ])
    }

    func refresh(from snapshot: AppSnapshot) {
        whitespaceCheck.state = snapshot.state.uiState.showWhitespaceInDiff ? .on : .off
        guard let index = Self.fontSizes.firstIndex(where: {
            $0.size == snapshot.state.uiState.diffFontSize
        }) else { return }
        fontSizePopup.selectItem(at: index)
    }

    #if DEBUG
    var selectedFontSizeForTesting: Double? {
        let index = fontSizePopup.indexOfSelectedItem
        guard Self.fontSizes.indices.contains(index) else { return nil }
        return Self.fontSizes[index].size
    }

    var showsWhitespaceForTesting: Bool { whitespaceCheck.state == .on }
    #endif

    @objc private func toggleWhitespace(_ sender: NSButton) {
        coordinator.setShowWhitespaceInDiff(sender.state == .on)
    }

    @objc private func changeFontSize(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.fontSizes.indices.contains(index) else { return }
        coordinator.setDiffFontSize(Self.fontSizes[index].size)
    }
}
