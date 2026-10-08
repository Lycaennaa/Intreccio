import AppKit

enum BranchFileInspectorState: Equatable {
  case noCommit
  case noSelection
  case loadingTree
  case loadingFile
  case text(String)
  case binary
  case tooLarge
  case submodule
  case failed(String)
}

struct BranchFileInspectorPresentation: Equatable {
  let branchName: String
  let commitObjectID: String?
  let path: String?
  let state: BranchFileInspectorState
}

@MainActor
final class BranchFileInspectorViewController: NSViewController {
  private let titleLabel = NSTextField(labelWithString: "Select a file")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let textView = NSTextView()
  private let scrollView = NSScrollView()
  private var renderedPresentation: BranchFileInspectorPresentation?

  override func loadView() {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.cgColor
    container.setAccessibilityLabel("Read-only branch file preview")

    titleLabel.font = .preferredFont(forTextStyle: .headline)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.lineBreakMode = .byTruncatingTail

    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.textColor = .textColor
    textView.backgroundColor = .black
    textView.drawsBackground = true
    textView.textContainerInset = NSSize(width: 12, height: 12)
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .black
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true

    for child in [titleLabel, subtitleLabel, scrollView] {
      child.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(child)
    }
    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
      titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
      titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
    view = container
  }

  func render(_ presentation: BranchFileInspectorPresentation) {
    guard renderedPresentation != presentation else { return }
    renderedPresentation = presentation
    guard isViewLoaded else { return }
    titleLabel.stringValue = presentation.path ?? presentation.branchName
    let revision = presentation.commitObjectID.map { String($0.prefix(8)) } ?? "No commit"
    subtitleLabel.stringValue = [
      presentation.branchName,
      revision,
      "committed snapshot; working changes are not shown"
    ].joined(separator: " · ")
    textView.string = description(for: presentation.state)
    textView.setSelectedRange(NSRange(location: 0, length: 0))
  }

  private func description(for state: BranchFileInspectorState) -> String {
    switch state {
    case .noCommit: "This branch has no commit to browse."
    case .noSelection: "Select a tracked file to preview its committed contents."
    case .loadingTree: "Loading files from the committed branch snapshot…"
    case .loadingFile: "Loading file preview…"
    case .text(let text): text
    case .binary: "Binary file; preview unavailable."
    case .tooLarge: "File exceeds the 1 MiB preview limit."
    case .submodule: "Submodule entry; file contents are stored in another repository."
    case .failed(let message): "Could not load branch file:\n\n\(message)"
    }
  }
}
