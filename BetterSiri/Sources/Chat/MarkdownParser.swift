import Foundation

enum MarkdownInlineStyle: Sendable, Equatable {
    case normal
    case bold
    case italic
    case code
    case link(url: String)
}

enum MarkdownInlineRun: Sendable, Equatable {
    case styled(style: MarkdownInlineStyle, text: String)
    case math(latex: String)
}

enum MarkdownTableAlignment: Sendable, Equatable {
    case left
    case center
    case right
}

struct MarkdownBlock: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case paragraph([MarkdownInlineRun])
        case heading(level: Int, content: [MarkdownInlineRun])
        case codeFence(language: String?, code: String)
        case unorderedList(items: [[MarkdownInlineRun]])
        case orderedList(items: [[MarkdownInlineRun]])
        case blockQuote(content: [MarkdownInlineRun])
        case table(
            header: [[MarkdownInlineRun]],
            alignments: [MarkdownTableAlignment],
            rows: [[[MarkdownInlineRun]]]
        )
        case horizontalRule
        case mathBlock(latex: String)
    }

    let id: UUID
    let kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

enum MarkdownParser {
    private struct ParsedMathBlock {
        let latex: String
        let nextIndex: Int
        let trailingText: String?
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var blocks: [MarkdownBlock] = []
        var i = 0

        func isBlank(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        func flushParagraph(_ buffer: inout [String]) {
            guard !buffer.isEmpty else { return }
            // Preserve single newlines within paragraph as spaces.
            let joined = buffer
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll(keepingCapacity: true)
            guard !joined.isEmpty else { return }
            blocks.append(.init(kind: .paragraph(parseInline(joined))))
        }

        var paragraphBuffer: [String] = []

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isBlank(trimmed) {
                flushParagraph(&paragraphBuffer)
                i += 1
                continue
            }

            // Fenced code blocks
            if trimmed.hasPrefix("```") {
                flushParagraph(&paragraphBuffer)

                let afterTicks = String(trimmed.dropFirst(3))
                let language = afterTicks.trimmingCharacters(in: .whitespacesAndNewlines)
                let lang = language.isEmpty ? nil : language

                var codeLines: [String] = []
                var j = i + 1
                var foundClosing = false
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("```") {
                        foundClosing = true
                        break
                    }
                    codeLines.append(lines[j])
                    j += 1
                }

                if foundClosing {
                    blocks.append(.init(kind: .codeFence(language: lang, code: codeLines.joined(separator: "\n"))))
                    i = j + 1
                    continue
                }

                // Streaming-safe: if unfinished, treat as paragraph text.
                paragraphBuffer.append(line)
                i += 1
                continue
            }

            // Display math blocks: $$ ... $$
            if trimmed.hasPrefix("$$") {
                flushParagraph(&paragraphBuffer)

                if let parsed = parseMathBlock(lines: lines, start: i, openingDelimiter: "$$", closingDelimiter: "$$") {
                    blocks.append(.init(kind: .mathBlock(latex: parsed.latex)))
                    if let trailing = parsed.trailingText, !trailing.isEmpty {
                        paragraphBuffer.append(trailing)
                    }
                    i = parsed.nextIndex
                    continue
                }

                // Streaming-safe: unfinished, treat as paragraph text.
                paragraphBuffer.append(line)
                i += 1
                continue
            }

            // Display math blocks: \[ ... \]
            if trimmed.hasPrefix("\\[") {
                flushParagraph(&paragraphBuffer)

                if let parsed = parseMathBlock(lines: lines, start: i, openingDelimiter: "\\[", closingDelimiter: "\\]") {
                    blocks.append(.init(kind: .mathBlock(latex: parsed.latex)))
                    if let trailing = parsed.trailingText, !trailing.isEmpty {
                        paragraphBuffer.append(trailing)
                    }
                    i = parsed.nextIndex
                    continue
                }

                // Streaming-safe: unfinished, treat as paragraph text.
                paragraphBuffer.append(line)
                i += 1
                continue
            }

            // GFM tables
            if let parsedTable = parseTableBlock(lines: lines, start: i) {
                flushParagraph(&paragraphBuffer)
                blocks.append(parsedTable.block)
                i = parsedTable.nextIndex
                continue
            }

            // Horizontal rules
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(&paragraphBuffer)
                blocks.append(.init(kind: .horizontalRule))
                i += 1
                continue
            }

            // Headings
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }
                let level = min(4, max(1, hashes.count))
                let rest = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    flushParagraph(&paragraphBuffer)
                    blocks.append(.init(kind: .heading(level: level, content: parseInline(rest))))
                    i += 1
                    continue
                }
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flushParagraph(&paragraphBuffer)
                let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(.init(kind: .blockQuote(content: parseInline(rest))))
                i += 1
                continue
            }

            // Lists (consume consecutive list lines)
            if let ul = parseUnorderedListItem(trimmed) {
                flushParagraph(&paragraphBuffer)
                var items: [[MarkdownInlineRun]] = [parseInline(ul)]
                var j = i + 1
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if isBlank(t) { break }
                    if let more = parseUnorderedListItem(t) {
                        items.append(parseInline(more))
                        j += 1
                        continue
                    }
                    break
                }
                blocks.append(.init(kind: .unorderedList(items: items)))
                i = j
                continue
            }

            if let ol = parseOrderedListItem(trimmed) {
                flushParagraph(&paragraphBuffer)
                var items: [[MarkdownInlineRun]] = [parseInline(ol)]
                var j = i + 1
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if isBlank(t) { break }
                    if let more = parseOrderedListItem(t) {
                        items.append(parseInline(more))
                        j += 1
                        continue
                    }
                    break
                }
                blocks.append(.init(kind: .orderedList(items: items)))
                i = j
                continue
            }

            paragraphBuffer.append(line)
            i += 1
        }

        flushParagraph(&paragraphBuffer)
        return blocks
    }

    private static func parseUnorderedListItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] {
            if line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
        }
        return nil
    }

    private static func parseOrderedListItem(_ line: String) -> String? {
        // Very simple: "1. " .. "99. "
        var idx = line.startIndex
        var digits = ""
        while idx < line.endIndex, line[idx].isNumber {
            digits.append(line[idx])
            idx = line.index(after: idx)
        }
        guard !digits.isEmpty else { return nil }
        guard idx < line.endIndex, line[idx] == "." else { return nil }
        idx = line.index(after: idx)
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        idx = line.index(after: idx)
        return String(line[idx...])
    }

    private static func parseMathBlock(
        lines: [String],
        start: Int,
        openingDelimiter: String,
        closingDelimiter: String
    ) -> ParsedMathBlock? {
        let openingLine = lines[start].trimmingCharacters(in: .whitespaces)
        guard openingLine.hasPrefix(openingDelimiter) else { return nil }

        let remainder = String(openingLine.dropFirst(openingDelimiter.count))
        if let closeRange = remainder.range(of: closingDelimiter) {
            let latex = String(remainder[..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let trailing = String(remainder[closeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(latex: latex, nextIndex: start + 1, trailingText: trailing.isEmpty ? nil : trailing)
        }

        var mathLines: [String] = []
        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mathLines.append(remainder)
        }

        var j = start + 1
        while j < lines.count {
            let candidate = lines[j]
            if let closeRange = candidate.range(of: closingDelimiter) {
                let before = String(candidate[..<closeRange.lowerBound])
                if !before.isEmpty {
                    mathLines.append(before)
                }

                let latex = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let trailing = String(candidate[closeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(latex: latex, nextIndex: j + 1, trailingText: trailing.isEmpty ? nil : trailing)
            }

            mathLines.append(candidate)
            j += 1
        }

        return nil
    }

    private static func parseTableBlock(
        lines: [String],
        start: Int
    ) -> (block: MarkdownBlock, nextIndex: Int)? {
        guard start + 1 < lines.count else { return nil }

        guard let headerCells = splitTableRow(lines[start]), !headerCells.isEmpty else { return nil }
        guard let separatorCells = splitTableRow(lines[start + 1]) else { return nil }

        let normalizedSeparator = normalizedTableCells(separatorCells, to: headerCells.count)
        var alignments: [MarkdownTableAlignment] = []
        alignments.reserveCapacity(normalizedSeparator.count)
        for cell in normalizedSeparator {
            guard let alignment = parseTableAlignment(cell) else { return nil }
            alignments.append(alignment)
        }

        let normalizedHeader = normalizedTableCells(headerCells, to: alignments.count)
        let headerRuns = normalizedHeader.map(parseInline)

        var rows: [[[MarkdownInlineRun]]] = []
        var j = start + 2
        while j < lines.count {
            let candidate = lines[j]
            if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
            guard let rowCells = splitTableRow(candidate) else { break }

            let normalizedRow = normalizedTableCells(rowCells, to: alignments.count)
            rows.append(normalizedRow.map(parseInline))
            j += 1
        }

        let block = MarkdownBlock(
            kind: .table(
                header: headerRuns,
                alignments: alignments,
                rows: rows
            )
        )
        return (block, j)
    }

    private static func splitTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var cells: [String] = []
        var current = ""
        var sawDelimiter = false

        var idx = trimmed.startIndex
        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if ch == "|", !isEscaped(in: trimmed, at: idx) {
                cells.append(current)
                current = ""
                sawDelimiter = true
                idx = trimmed.index(after: idx)
                continue
            }

            current.append(ch)
            idx = trimmed.index(after: idx)
        }
        cells.append(current)

        guard sawDelimiter else { return nil }

        if trimmed.first == "|", !cells.isEmpty {
            cells.removeFirst()
        }
        if trimmed.last == "|", !cells.isEmpty {
            cells.removeLast()
        }

        return cells.map {
            unescapeTableCell($0.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func normalizedTableCells(_ cells: [String], to expectedCount: Int) -> [String] {
        guard expectedCount > 0 else { return [] }
        if cells.count == expectedCount { return cells }

        var out = Array(cells.prefix(expectedCount))
        if out.count < expectedCount {
            out.append(contentsOf: Array(repeating: "", count: expectedCount - out.count))
        }
        return out
    }

    private static func parseTableAlignment(_ cell: String) -> MarkdownTableAlignment? {
        var token = cell.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return nil }

        let leftAligned = token.hasPrefix(":")
        let rightAligned = token.hasSuffix(":")

        if leftAligned {
            token.removeFirst()
        }
        if rightAligned, !token.isEmpty {
            token.removeLast()
        }

        token = token.trimmingCharacters(in: .whitespaces)
        guard token.count >= 3, token.allSatisfy({ $0 == "-" }) else { return nil }

        switch (leftAligned, rightAligned) {
        case (true, true): return .center
        case (false, true): return .right
        default: return .left
        }
    }

    private static func unescapeTableCell(_ cell: String) -> String {
        var out = ""
        var idx = cell.startIndex

        while idx < cell.endIndex {
            let ch = cell[idx]
            if ch == "\\" {
                let next = cell.index(after: idx)
                if next < cell.endIndex, cell[next] == "|" {
                    out.append("|")
                    idx = cell.index(after: next)
                    continue
                }
            }

            out.append(ch)
            idx = cell.index(after: idx)
        }

        return out
    }

    private static func isEscaped(in string: String, at index: String.Index) -> Bool {
        guard index > string.startIndex else { return false }

        var slashCount = 0
        var cursor = string.index(before: index)
        while true {
            guard string[cursor] == "\\" else { break }
            slashCount += 1
            guard cursor > string.startIndex else { break }
            cursor = string.index(before: cursor)
        }

        return slashCount % 2 == 1
    }

    private static func firstUnescaped(
        _ target: Character,
        in string: String,
        from start: String.Index
    ) -> String.Index? {
        var idx = start
        while idx < string.endIndex {
            if string[idx] == target, !isEscaped(in: string, at: idx) {
                return idx
            }
            idx = string.index(after: idx)
        }
        return nil
    }

    private static func parseInline(_ s: String) -> [MarkdownInlineRun] {
        var runs: [MarkdownInlineRun] = []
        var i = s.startIndex

        func appendStyled(_ style: MarkdownInlineStyle, _ text: String) {
            guard !text.isEmpty else { return }
            runs.append(.styled(style: style, text: text))
        }

        func appendText(_ text: String) {
            appendStyled(.normal, text)
        }

        while i < s.endIndex {
            // Inline code: `...`
            if s[i] == "`" {
                let start = s.index(after: i)
                if let end = s[start...].firstIndex(of: "`") {
                    let code = String(s[start..<end])
                    runs.append(.styled(style: .code, text: code))
                    i = s.index(after: end)
                    continue
                }
            }

            // Link: [text](url)
            if s[i] == "[" {
                let textStart = s.index(after: i)
                if let textEnd = s[textStart...].firstIndex(of: "]") {
                    let after = s.index(after: textEnd)
                    if after < s.endIndex, s[after] == "(" {
                        let urlStart = s.index(after: after)
                        if let urlEnd = s[urlStart...].firstIndex(of: ")") {
                            let label = String(s[textStart..<textEnd])
                            let url = String(s[urlStart..<urlEnd])
                            runs.append(.styled(style: .link(url: url), text: label))
                            i = s.index(after: urlEnd)
                            continue
                        }
                    }
                }
            }

            // Inline LaTeX: \(...\)
            if s[i] == "\\" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "(" {
                    let start = s.index(after: next)
                    if let end = s[start...].range(of: "\\)")?.lowerBound {
                        let latex = String(s[start..<end])
                        runs.append(.math(latex: latex))
                        i = s.index(end, offsetBy: 2)
                        continue
                    }
                }

                if next < s.endIndex, "\\$|[]`*".contains(s[next]) {
                    appendText(String(s[next]))
                    i = s.index(after: next)
                    continue
                }
            }

            // Inline LaTeX: $...$ (streaming-safe)
            if s[i] == "$", !isEscaped(in: s, at: i) {
                let next = s.index(after: i)
                // avoid $$ here (block math handled elsewhere)
                if next < s.endIndex, s[next] == "$" {
                    // treat as text
                } else {
                    let start = next
                    if let end = firstUnescaped("$", in: s, from: start), end != start {
                        let latex = String(s[start..<end])
                        if !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            runs.append(.math(latex: latex))
                            i = s.index(after: end)
                            continue
                        }
                    }
                }
            }

            // Bold: **...**
            if s[i] == "*" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "*" {
                    let start = s.index(after: next)
                    if let end = s[start...].range(of: "**")?.lowerBound {
                        let inner = String(s[start..<end])
                        runs.append(.styled(style: .bold, text: inner))
                        i = s.index(end, offsetBy: 2)
                        continue
                    }
                }
            }

            // Italic: *...*
            if s[i] == "*" {
                let start = s.index(after: i)
                if let end = s[start...].firstIndex(of: "*"), end != start {
                    let inner = String(s[start..<end])
                    runs.append(.styled(style: .italic, text: inner))
                    i = s.index(after: end)
                    continue
                }
            }

            // Fallback: accumulate plain text until next special marker.
            let specials = "`[$*\\"
            var j = i
            while j < s.endIndex {
                if specials.contains(s[j]) {
                    break
                }
                j = s.index(after: j)
            }
            if j == i {
                appendText(String(s[i]))
                i = s.index(after: i)
            } else {
                appendText(String(s[i..<j]))
                i = j
            }
        }

        // Merge adjacent styled runs with same style.
        var merged: [MarkdownInlineRun] = []
        for run in runs {
            switch (merged.last, run) {
            case (.some(.styled(let s1, let t1)), .styled(let s2, let t2)) where s1 == s2:
                merged.removeLast()
                merged.append(.styled(style: s1, text: t1 + t2))
            default:
                merged.append(run)
            }
        }
        return merged
    }
}
