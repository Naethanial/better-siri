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

struct MarkdownBlock: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case paragraph([MarkdownInlineRun])
        case heading(level: Int, content: [MarkdownInlineRun])
        case codeFence(language: String?, code: String)
        case unorderedList(items: [[MarkdownInlineRun]])
        case orderedList(items: [[MarkdownInlineRun]])
        case blockQuote(content: [MarkdownInlineRun])
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

                let remainder = String(trimmed.dropFirst(2))
                if remainder.contains("$$") {
                    // One-liner: $$ ... $$
                    let parts = remainder.split(separator: "$$", maxSplits: 1, omittingEmptySubsequences: false)
                    let latex = String(parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    blocks.append(.init(kind: .mathBlock(latex: latex)))
                    i += 1
                    continue
                }

                var mathLines: [String] = []
                if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    mathLines.append(remainder)
                }

                var j = i + 1
                var foundClosing = false
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("$$") {
                        let tail = String(t.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !tail.isEmpty {
                            mathLines.append(tail)
                        }
                        foundClosing = true
                        break
                    }
                    mathLines.append(lines[j])
                    j += 1
                }

                if foundClosing {
                    let latex = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    blocks.append(.init(kind: .mathBlock(latex: latex)))
                    i = j + 1
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

                let remainder = String(trimmed.dropFirst(2))
                if remainder.contains("\\]") {
                    let parts = remainder.split(separator: "\\]", maxSplits: 1, omittingEmptySubsequences: false)
                    let latex = String(parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    blocks.append(.init(kind: .mathBlock(latex: latex)))
                    i += 1
                    continue
                }

                var mathLines: [String] = []
                if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    mathLines.append(remainder)
                }

                var j = i + 1
                var foundClosing = false
                while j < lines.count {
                    if let range = lines[j].range(of: "\\]") {
                        let before = String(lines[j][..<range.lowerBound])
                        mathLines.append(before)
                        foundClosing = true
                        break
                    }
                    mathLines.append(lines[j])
                    j += 1
                }

                if foundClosing {
                    let latex = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    blocks.append(.init(kind: .mathBlock(latex: latex)))
                    i = j + 1
                    continue
                }

                // Streaming-safe: unfinished, treat as paragraph text.
                paragraphBuffer.append(line)
                i += 1
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
            }

            // Inline LaTeX: $...$ (streaming-safe)
            if s[i] == "$" {
                let next = s.index(after: i)
                // avoid $$ here (block math handled elsewhere)
                if next < s.endIndex, s[next] == "$" {
                    // treat as text
                } else {
                    let start = next
                    if let end = s[start...].firstIndex(of: "$"), end != start {
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
