import AppKit

@MainActor
final class FileWatchingSettingsViewController: NSViewController, SettingsSectionController {
    static let debounceOptions: [(label: String, milliseconds: Int)] = [
        ("Fast (250 ms)", 250),
        ("Standard (500 ms)", 500),
        ("Relaxed (1 s)", 1_000),
    ]

    private let coordinator: AppCoordinator
    private let debouncePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        debouncePopup.target = self
        debouncePopup.action = #selector(changeDebounce(_:))
        debouncePopup.addItems(withTitles: Self.debounceOptions.map { $0.label })
        view = SettingsUI.section(title: "File Watching", views: [
            SettingsUI.row(SettingsUI.label("Refresh debounce"), debouncePopup),
        ])
    }

    func refresh(from snapshot: AppSnapshot) {
        guard let index = Self.debounceOptions.firstIndex(where: {
            $0.milliseconds == snapshot.state.uiState.fileWatchDebounceMilliseconds
        }) else { return }
        debouncePopup.selectItem(at: index)
    }

    @objc private func changeDebounce(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.debounceOptions.indices.contains(index) else { return }
        coordinator.setFileWatchDebounce(milliseconds: Self.debounceOptions[index].milliseconds)
    }
}

