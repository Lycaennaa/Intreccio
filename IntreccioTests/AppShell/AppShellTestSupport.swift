import AppKit
@testable import Intreccio
import XCTest

extension AppShellTests {
    func makeDiffFile(path: String, line: String) -> DiffFile {
        DiffFile(
            path: path,
            originalPath: nil,
            change: .modified,
            content: .text([
                DiffHunk(
                    oldRange: DiffRange(start: 0, count: 0),
                    newRange: DiffRange(start: 1, count: 1),
                    heading: nil,
                    lines: [
                        DiffLine(
                            kind: .addition,
                            text: line,
                            oldLineNumber: nil,
                            newLineNumber: 1,
                            hasTrailingNewline: true,
                            tokens: DiffSyntaxTokenizer.tokenize(line)
                        )
                    ]
                )
            ])
        )
    }

    func makeScrollableDiff(path: String, marker: String, lineCount: Int = 500) -> GitDiff {
        let lines = (1...lineCount).map { lineNumber in
            let text = "let value\(lineNumber) = \(lineNumber) // \(marker)"
            return DiffLine(
                kind: .addition,
                text: text,
                oldLineNumber: nil,
                newLineNumber: lineNumber,
                hasTrailingNewline: true,
                tokens: DiffSyntaxTokenizer.tokenize(text)
            )
        }
        return GitDiff(
            files: [
                DiffFile(
                    path: path,
                    originalPath: nil,
                    change: .modified,
                    content: .text([
                        DiffHunk(
                            oldRange: DiffRange(start: 0, count: 0),
                            newRange: DiffRange(start: 1, count: lines.count),
                            heading: nil,
                            lines: lines
                        )
                    ])
                )
            ],
            fallback: nil,
            sourceByteCount: lines.reduce(0) { $0 + $1.text.utf8.count + 1 },
            sourceLineCount: lines.count
        )
    }

    @MainActor
    func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }

    @MainActor
    func findTextView(containing text: String, in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.string.contains(text) { return textView }
        for subview in view.subviews {
            if let textView = findTextView(containing: text, in: subview) { return textView }
        }
        return nil
    }

    @MainActor
    func findTextField(placeholder: String, in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField, textField.placeholderString == placeholder { return textField }
        for subview in view.subviews {
            if let textField = findTextField(placeholder: placeholder, in: subview) { return textField }
        }
        return nil
    }

    @MainActor
    func findTextField(value: String, in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField, textField.stringValue == value { return textField }
        for subview in view.subviews {
            if let textField = findTextField(value: value, in: subview) { return textField }
        }
        return nil
    }

    @MainActor
    func findPopUpButton(in view: NSView) -> NSPopUpButton? {
        if let popUpButton = view as? NSPopUpButton { return popUpButton }
        for subview in view.subviews {
            if let popUpButton = findPopUpButton(in: subview) { return popUpButton }
        }
        return nil
    }

    @MainActor
    func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let button = findButton(titled: title, in: subview) { return button }
        }
        return nil
    }

    @MainActor
    func allDescendantViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allDescendantViews(in: $0) }
    }
}
