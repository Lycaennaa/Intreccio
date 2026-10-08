import CoreText
import Foundation
import os

nonisolated let diffPerformanceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.lycaennaa.intreccio",
    category: "DiffRendering"
)

nonisolated func diffChangeLabel(_ change: DiffFileChange) -> String {
    switch change {
    case .added: "A"
    case .modified: "M"
    case .deleted: "D"
    case .renamed: "R"
    case .copied: "C"
    case .conflicted: "U"
    case .untracked: "?"
    }
}

nonisolated enum DiffAttributedStringBuilder {
    private struct ColorPalette {
        let base: CGColor
        let muted: CGColor
        let header: CGColor
        let hunk: CGColor
        let addition: CGColor
        let deletion: CGColor
        let string: CGColor
        let comment: CGColor
        let warning: CGColor
        let headerBackground: CGColor
        let hunkBackground: CGColor
        let additionBackground: CGColor
        let deletionBackground: CGColor

        init() {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            base = Self.makeColor(0.92, 0.92, 0.94, colorSpace: colorSpace)
            muted = Self.makeColor(0.48, 0.50, 0.54, colorSpace: colorSpace)
            header = Self.makeColor(0.35, 0.78, 0.98, colorSpace: colorSpace)
            hunk = Self.makeColor(0.75, 0.45, 0.98, colorSpace: colorSpace)
            addition = Self.makeColor(0.35, 0.86, 0.48, colorSpace: colorSpace)
            deletion = Self.makeColor(1.0, 0.36, 0.38, colorSpace: colorSpace)
            string = Self.makeColor(1.0, 0.64, 0.28, colorSpace: colorSpace)
            comment = Self.makeColor(0.58, 0.60, 0.64, colorSpace: colorSpace)
            warning = string
            headerBackground = Self.makeColor(0.08, 0.16, 0.22, 0.75, colorSpace: colorSpace)
            hunkBackground = Self.makeColor(0.13, 0.08, 0.20, 0.75, colorSpace: colorSpace)
            additionBackground = Self.makeColor(0.05, 0.18, 0.09, 0.72, colorSpace: colorSpace)
            deletionBackground = Self.makeColor(0.22, 0.06, 0.07, 0.72, colorSpace: colorSpace)
        }

        func color(for style: DiffRenderStyle) -> CGColor {
            switch style {
            case .base: base
            case .muted: muted
            case .header: header
            case .hunk, .keyword: hunk
            case .addition: addition
            case .deletion: deletion
            case .string: string
            case .comment: comment
            case .warning: warning
            }
        }

        func background(for style: DiffRenderStyle) -> CGColor? {
            switch style {
            case .header: headerBackground
            case .hunk: hunkBackground
            case .addition: additionBackground
            case .deletion: deletionBackground
            case .base, .muted, .keyword, .string, .comment, .warning: nil
            }
        }

        private static func makeColor(
            _ red: CGFloat,
            _ green: CGFloat,
            _ blue: CGFloat,
            _ alpha: CGFloat = 1,
            colorSpace: CGColorSpace
        ) -> CGColor {
            CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
        }
    }

    static func make(_ layout: DiffTextLayout, fontSize: CGFloat = 12) -> DiffAttributedRender? {
        guard !Task.isCancelled else { return nil }
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let backgroundKey = NSAttributedString.Key(kCTBackgroundColorAttributeName as String)
        let regular = CTFontCreateWithName("SFMono-Regular" as CFString, fontSize, nil)
        let semibold = CTFontCreateWithName("SFMono-Semibold" as CFString, fontSize, nil)
        let palette = ColorPalette()
        let output = NSMutableAttributedString(string: layout.text, attributes: [
            fontKey: regular,
            colorKey: palette.base
        ])
        guard !Task.isCancelled else { return nil }
        for run in layout.runs {
            if Task.isCancelled { return nil }
            let font: CTFont = switch run.style {
            case .header, .warning: semibold
            default: regular
            }
            var attributes: [NSAttributedString.Key: Any] = [
                fontKey: font,
                colorKey: palette.color(for: run.style)
            ]
            if let backgroundStyle = run.backgroundStyle,
               let background = palette.background(for: backgroundStyle) {
                attributes[backgroundKey] = background
            }
            output.addAttributes(attributes, range: run.range)
        }
        guard !Task.isCancelled else { return nil }
        return DiffAttributedRender(value: output)
    }
}

nonisolated enum DiffPresentationBuilder {}

nonisolated func diffDisplayedText(_ text: String, showWhitespace: Bool) -> String {
    guard showWhitespace else { return text }
    return text
        .replacingOccurrences(of: "\t", with: "→   ")
        .replacingOccurrences(of: " ", with: "·")
}

nonisolated enum DiffTextLayoutBuilder {
    static func make(
        _ files: [DiffFile],
        showWhitespace: Bool,
        prefix: String? = nil,
        foldContext: Bool = false
    ) -> DiffTextLayout? {
        guard !Task.isCancelled else { return nil }
        var text = ""
        var runs: [DiffRenderRun] = []
        var hunkTargets: [DiffHunkDisplayTarget] = []
        var lineTargets: [DiffLineDisplayTarget] = []
        var foldedContextTargets: [DiffFoldedContextDisplayTarget] = []
        var utf16Count = 0

        @discardableResult
        func append(
            _ value: String,
            style: DiffRenderStyle,
            backgroundStyle: DiffRenderStyle? = nil
        ) -> NSRange {
            let start = utf16Count
            guard !value.isEmpty, !Task.isCancelled else {
                return NSRange(location: start, length: 0)
            }
            let length = value.utf16.count
            text += value
            if let last = runs.last,
               last.style == style,
               last.backgroundStyle == backgroundStyle,
               NSMaxRange(last.range) == utf16Count {
                runs[runs.count - 1] = DiffRenderRun(
                    range: NSRange(location: last.range.location, length: last.range.length + length),
                    style: style,
                    backgroundStyle: backgroundStyle
                )
            } else {
                runs.append(DiffRenderRun(
                    range: NSRange(location: utf16Count, length: length),
                    style: style,
                    backgroundStyle: backgroundStyle
                ))
            }
            utf16Count += length
            return NSRange(location: start, length: length)
        }

        if let prefix, !prefix.isEmpty {
            append(prefix, style: .base)
            append("\n", style: .base)
            if Task.isCancelled { return nil }
        }

        for (fileIndex, file) in files.enumerated() {
            if Task.isCancelled { return nil }
            if fileIndex > 0 {
                append("\n================================================================\n", style: .muted)
            }
            let path = file.displayPath
            let name = file.displayOriginalPath.map { $0 + " → " + path } ?? path
            let mode: String
            switch (file.oldMode, file.newMode) {
            case let (old?, new?): mode = " (mode " + old + " → " + new + ")"
            case let (nil, new?): mode = " (mode " + new + ")"
            case let (old?, nil): mode = " (mode " + old + " removed)"
            case (nil, nil): mode = ""
            }
            append("\n " + file.change.rawValue.uppercased() + "  " + name + mode + "\n", style: .header, backgroundStyle: .header)
            switch file.content {
            case .binary(let byteCount):
                append(" Binary file", style: .muted)
                if let byteCount { append(" (" + String(byteCount) + " bytes)", style: .muted) }
                append("\n", style: .muted)
            case .oversized(let reason, let byteCount):
                let details = byteCount.map {
                    diffOversizedReasonLabel(reason) + "; " + String($0) + " bytes"
                } ?? diffOversizedReasonLabel(reason)
                append(" File too large to render (" + details + ")", style: .muted)
                append("\n", style: .muted)
            case .unavailable(let reason):
                append(" File unavailable (" + DiffPresentationBuilder.unavailableReasonText(reason) + ")\n", style: .warning)
            case .conflicted(let statusX, let statusY):
                append(" Unmerged conflict (status " + statusX.rawValue + statusY.rawValue + ")\n", style: .warning)
            case .text(let hunks):
                if hunks.isEmpty { append(" Metadata-only change\n", style: .muted) }
                for (hunkIndex, hunk) in hunks.enumerated() {
                    if Task.isCancelled { return nil }
                    let heading = hunk.heading.map { " " + $0 } ?? ""
                    let hunkLabel = "@@ -" + String(hunk.oldRange.start) + "," + String(hunk.oldRange.count)
                        + " +" + String(hunk.newRange.start) + "," + String(hunk.newRange.count) + " @@" + heading
                    let hunkRange = append(hunkLabel + "\n", style: .hunk, backgroundStyle: .hunk)
                    hunkTargets.append(DiffHunkDisplayTarget(
                        range: hunkRange,
                        fileIndex: fileIndex,
                        hunkIndex: hunkIndex,
                        label: hunkLabel
                    ))
                    var lineIndex = 0
                    for segment in DiffContextFolding.segments(for: hunk.lines, enabled: foldContext) {
                        if Task.isCancelled { return nil }
                        switch segment {
                        case .line(let line):
                            let old = line.oldLineNumber.map { String(format: "%5d", $0) } ?? "     "
                            let new = line.newLineNumber.map { String(format: "%5d", $0) } ?? "     "
                            let marker: String
                            let lineStyle: DiffRenderStyle
                            switch line.kind {
                            case .context: marker = " "; lineStyle = .base
                            case .addition: marker = "+"; lineStyle = .addition
                            case .deletion: marker = "-"; lineStyle = .deletion
                            }
                            let rowBackground: DiffRenderStyle? = switch line.kind {
                            case .context: nil
                            case .addition: .addition
                            case .deletion: .deletion
                            }
                            let rowStart = utf16Count
                            append(old + " " + new + " ", style: .muted, backgroundStyle: rowBackground)
                            append(marker + " ", style: lineStyle, backgroundStyle: rowBackground)
                            if line.tokens.isEmpty {
                                append(diffDisplayedText(line.text, showWhitespace: showWhitespace), style: lineStyle, backgroundStyle: rowBackground)
                            } else {
                                for token in line.tokens {
                                    if Task.isCancelled { return nil }
                                    let style: DiffRenderStyle = switch token.kind {
                                    case .plain: lineStyle
                                    case .keyword: .keyword
                                    case .string: .string
                                    case .comment: .comment
                                    }
                                    append(
                                        diffDisplayedText(token.text, showWhitespace: showWhitespace),
                                        style: style,
                                        backgroundStyle: rowBackground
                                    )
                                }
                            }
                            append("\n", style: .base, backgroundStyle: rowBackground)
                            if !line.hasTrailingNewline {
                                append(
                                    "            \\ No newline at end of file\n",
                                    style: .muted,
                                    backgroundStyle: rowBackground
                                )
                            }
                            lineTargets.append(DiffLineDisplayTarget(
                                range: NSRange(location: rowStart, length: utf16Count - rowStart),
                                fileIndex: fileIndex,
                                hunkIndex: hunkIndex,
                                lineIndex: lineIndex,
                                kind: line.kind,
                                oldLineNumber: line.oldLineNumber,
                                newLineNumber: line.newLineNumber
                            ))
                            lineIndex += 1
                        case .folded(let count):
                            let placeholder = "            ⋯ " + String(count)
                                + " context lines folded; use Show All Context to reveal ⋯\n"
                            let foldedRange = append(placeholder, style: .muted)
                            foldedContextTargets.append(DiffFoldedContextDisplayTarget(
                                range: foldedRange,
                                fileIndex: fileIndex,
                                hunkIndex: hunkIndex,
                                count: count
                            ))
                            lineIndex += count
                        }
                    }
                }
            }
        }
        let navigation = DiffTextNavigation(
            hunks: hunkTargets,
            lines: lineTargets,
            foldedContexts: foldedContextTargets
        )
        return Task.isCancelled ? nil : DiffTextLayout(text: text, runs: runs, navigation: navigation)
    }
}

nonisolated enum DiffRenderPreparationBuilder {
    static func make(_ request: DiffRenderRequest) -> DiffPreparedRender? {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var summary = DiffPresentationBuilder.summary(for: request.model, mode: request.summaryMode)
        let selectedFiles = request.model.files(for: request.scope)
        let files = selectedFiles.compactMap { presentationFile -> DiffFile? in
            guard case .content(let content) = presentationFile.state else { return nil }
            return DiffFile(
                gitPath: presentationFile.header.path,
                originalGitPath: presentationFile.header.originalPath,
                change: presentationFile.header.change,
                content: content,
                oldMode: presentationFile.header.oldMode,
                newMode: presentationFile.header.newMode
            )
        }
        var resolvedPrefix: String?
        switch request.prefix {
        case .none:
            resolvedPrefix = nil
        case .cached(let prefix):
            resolvedPrefix = prefix
        case .commit(let details):
            resolvedPrefix = DiffPresentationBuilder.commitPrefix(details)
            if resolvedPrefix == nil { return nil }
        case .fallback(let fallback):
            resolvedPrefix = DiffPresentationBuilder.diffFallbackText(fallback)
            if resolvedPrefix == nil { return nil }
        }
        if let fallback = scopedFallback(
            for: request.model,
            selectedFiles: selectedFiles,
            scope: request.scope
        ), files.isEmpty || isAllFiles(request.scope) {
            guard let fallbackText = DiffPresentationBuilder.diffFallbackText(fallback) else { return nil }
            if let currentPrefix = resolvedPrefix, !currentPrefix.isEmpty {
                resolvedPrefix = currentPrefix + "\n\n" + fallbackText
            } else {
                resolvedPrefix = fallbackText
            }
        }
        let picker: DiffFilePickerModel?
        if request.needsPicker {
            guard let preparedPicker = DiffPresentationBuilder.filePicker(for: request.model, mode: request.summaryMode) else { return nil }
            picker = preparedPicker
        } else {
            picker = nil
        }
        let exceedsRenderLimit = estimatedRenderBytes(
            files: files,
            prefix: resolvedPrefix,
            showWhitespace: request.showWhitespace,
            foldContext: request.foldContext
        )
        .map { $0 > DiffLimits.render.maximumBytes } ?? true
        if exceedsRenderLimit {
            summary = summary.addingRenderLimitNotice()
        }
        let layout: DiffTextLayout?
        if exceedsRenderLimit {
            let fallbackPrefix = "Diff display exceeds the " + String(DiffLimits.render.maximumBytes) + "-byte render limit."
            layout = DiffTextLayoutBuilder.make(
                [],
                showWhitespace: request.showWhitespace,
                prefix: fallbackPrefix,
                foldContext: request.foldContext
            )
        } else {
            layout = DiffTextLayoutBuilder.make(
                files,
                showWhitespace: request.showWhitespace,
                prefix: resolvedPrefix,
                foldContext: request.foldContext
            )
        }
        guard let layout,
              let rendered = DiffAttributedStringBuilder.make(layout, fontSize: request.fontSize) else { return nil }
        let duration = String(describing: startedAt.duration(to: clock.now))
        diffPerformanceLogger.info("Rendered \(files.count) files and \(layout.text.utf8.count) bytes in \(duration, privacy: .public)")
        return DiffPreparedRender(
            attributed: rendered.value,
            picker: picker,
            prefix: exceedsRenderLimit ? nil : resolvedPrefix,
            summary: summary,
            navigation: layout.navigation
        )
    }

    private static func estimatedRenderBytes(
        files: [DiffFile],
        prefix: String?,
        showWhitespace: Bool,
        foldContext: Bool
    ) -> Int? {
        var total = prefix?.utf8.count ?? 0
        func add(_ value: Int) -> Bool {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return false }
            total = result.partialValue
            return true
        }

        for (fileIndex, file) in files.enumerated() {
            if fileIndex > 0 {
                guard add("\n================================================================\n".utf8.count) else { return nil }
            }
            let pathCost = file.displayPath.utf8.count.multipliedReportingOverflow(by: 4)
            guard !pathCost.overflow,
                  add(pathCost.partialValue),
                  add(128) else { return nil }
            switch file.content {
            case .text(let hunks):
                for hunk in hunks {
                    guard add(64 + (hunk.heading?.utf8.count ?? 0)) else { return nil }
                    for segment in DiffContextFolding.segments(for: hunk.lines, enabled: foldContext) {
                        switch segment {
                        case .line(let line):
                            let lineBytes = diffDisplayedText(line.text, showWhitespace: showWhitespace).utf8.count
                            let old = line.oldLineNumber.map { String(format: "%5d", $0) } ?? "     "
                            let new = line.newLineNumber.map { String(format: "%5d", $0) } ?? "     "
                            guard add((old + " " + new + " ").utf8.count),
                                  add(2),
                                  add(lineBytes),
                                  add(1) else { return nil }
                            if !line.hasTrailingNewline {
                                guard add("            \\ No newline at end of file\n".utf8.count) else { return nil }
                            }
                        case .folded(let count):
                            let placeholder = "            ⋯ " + String(count)
                                + " context lines folded; use Show All Context to reveal ⋯\n"
                            guard add(placeholder.utf8.count) else { return nil }
                        }
                    }
                }
            case .binary, .oversized, .unavailable, .conflicted:
                guard add(96) else { return nil }
            }
        }
        return total
    }

    private static func scopedFallback(
        for model: DiffPresentationModel,
        selectedFiles: [DiffPresentationFile],
        scope: DiffPresentationScope
    ) -> DiffFallback? {
        guard let fallback = model.fallback else { return nil }
        guard !isAllFiles(scope) else { return fallback }
        let summaries = selectedFiles.compactMap { file -> DiffFileSummary? in
            guard case .aggregateFallback = file.state else { return nil }
            return DiffFileSummary(
                gitPath: file.header.path,
                originalGitPath: file.header.originalPath,
                change: file.header.change
            )
        }
        guard !summaries.isEmpty else { return nil }
        return DiffFallback(reason: fallback.reason, files: summaries)
    }

    private static func isAllFiles(_ scope: DiffPresentationScope) -> Bool {
        if case .allFiles = scope { return true }
        return false
    }
}
