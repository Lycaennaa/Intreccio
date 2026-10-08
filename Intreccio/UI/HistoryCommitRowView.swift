import AppKit

enum HistoryCommitRowView {
  static func make(commit: Commit, dateFormatter: DateFormatter) -> NSView {
    let cell = NSTableCellView()
    let subject = NSTextField(labelWithString: commit.subject.isEmpty ? "(no subject)" : commit.subject)
    let metadataText = [
      commit.authorName,
      String(commit.objectID.prefix(8)),
      dateFormatter.string(from: commit.authoredAt)
    ].joined(separator: "   ")
    let metadata = NSTextField(labelWithString: metadataText)
    subject.lineBreakMode = .byTruncatingTail
    metadata.lineBreakMode = .byTruncatingTail
    metadata.font = .preferredFont(forTextStyle: .caption2)
    metadata.textColor = .secondaryLabelColor
    subject.translatesAutoresizingMaskIntoConstraints = false
    metadata.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(subject)
    cell.addSubview(metadata)
    cell.textField = subject
    NSLayoutConstraint.activate([
      subject.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      subject.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      subject.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
      metadata.leadingAnchor.constraint(equalTo: subject.leadingAnchor),
      metadata.trailingAnchor.constraint(equalTo: subject.trailingAnchor),
      metadata.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 2)
    ])
    cell.toolTip = commit.subject
    cell.setAccessibilityLabel("\(subject.stringValue), \(metadata.stringValue)")
    return cell
  }
}
