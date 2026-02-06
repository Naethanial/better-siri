import AppKit
import SwiftUI

private struct FlowLayout: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude

        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                totalHeight += lineHeight
                usedWidth = max(usedWidth, lineWidth)
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }

        totalHeight += lineHeight
        usedWidth = max(usedWidth, lineWidth)
        return CGSize(width: min(usedWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width

        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        var lineSubviews: [(Subviews.Element, CGSize)] = []

        func flushLine() {
            guard !lineSubviews.isEmpty else { return }
            var cursorX = bounds.minX
            for (idx, item) in lineSubviews.enumerated() {
                let sv = item.0
                let size = item.1
                if idx > 0 {
                    cursorX += spacing
                }
                let offsetY = (lineHeight - size.height) / 2
                sv.place(
                    at: CGPoint(x: cursorX, y: y + offsetY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                cursorX += size.width
            }
            y += lineHeight
            x = bounds.minX
            lineHeight = 0
            lineSubviews.removeAll(keepingCapacity: true)
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > bounds.minX, x + spacing + size.width > bounds.minX + maxWidth {
                flushLine()
            }

            if x > bounds.minX {
                x += spacing
            }
            lineSubviews.append((subview, size))
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }

        flushLine()
    }
}

private struct InlineToken: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case text(style: MarkdownInlineStyle, text: String)
        case math(latex: String)
    }

    let id: UUID
    let kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

private enum InlineTokenizer {
    static func tokenize(_ runs: [MarkdownInlineRun]) -> [InlineToken] {
        var tokens: [InlineToken] = []
        for run in runs {
            switch run {
            case .math(let latex):
                tokens.append(.init(kind: .math(latex: latex)))

            case .styled(let style, let text):
                for piece in splitKeepingWhitespace(text) {
                    tokens.append(.init(kind: .text(style: style, text: piece)))
                }
            }
        }
        return tokens
    }

    private static func splitKeepingWhitespace(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var currentIsSpace: Bool? = nil

        for ch in s {
            let isSpace = ch.isWhitespace
            if currentIsSpace == nil {
                currentIsSpace = isSpace
                current.append(ch)
                continue
            }

            if currentIsSpace == isSpace {
                current.append(ch)
            } else {
                out.append(current)
                current = String(ch)
                currentIsSpace = isSpace
            }
        }

        if !current.isEmpty {
            out.append(current)
        }
        return out
    }
}

private struct InlineRunsView: View {
    let runs: [MarkdownInlineRun]
    let foregroundColor: Color
    let latexColor: NSColor
    let latexFontSize: CGFloat
    let baseFont: Font
    let colorScheme: ColorScheme

    private var tokens: [InlineToken] {
        InlineTokenizer.tokenize(runs)
    }

    var body: some View {
        FlowLayout(spacing: 0) {
            ForEach(tokens) { token in
                switch token.kind {
                case .math(let latex):
                    LatexInlineView(
                        latex: latex,
                        fontSize: latexFontSize,
                        color: latexColor
                    )

                case .text(let style, let text):
                    styledText(style: style, text: text)
                }
            }
        }
        .font(baseFont)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func styledText(style: MarkdownInlineStyle, text: String) -> some View {
        switch style {
        case .normal:
            Text(text)
                .foregroundStyle(foregroundColor)

        case .bold:
            Text(text)
                .fontWeight(.semibold)
                .foregroundStyle(foregroundColor)

        case .italic:
            Text(text)
                .italic()
                .foregroundStyle(foregroundColor)

        case .code:
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(colorScheme == .dark ? 0.35 : 0.08))
                )

        case .link(let url):
            Text(text)
                .foregroundStyle(.blue)
                .underline()
                .onTapGesture {
                    guard let u = URL(string: url) else { return }
                    NSWorkspace.shared.open(u)
                }
                .accessibilityLabel("Link")
                .accessibilityHint(url)
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    let colorScheme: ColorScheme
    let foregroundColor: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(foregroundColor)
                    .textSelection(.enabled)
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(colorScheme == .dark ? 0.35 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
                )
        )
    }
}

private struct TableBlockView: View {
    let header: [[MarkdownInlineRun]]
    let alignments: [MarkdownTableAlignment]
    let rows: [[[MarkdownInlineRun]]]
    let colorScheme: ColorScheme
    let foregroundColor: Color
    let latexColor: NSColor

    private var columnCount: Int {
        max(alignments.count, header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                if columnCount > 0 {
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { columnIndex in
                            tableCell(
                                runs: runsForHeader(columnIndex),
                                alignment: alignmentForColumn(columnIndex),
                                isHeader: true
                            )
                            .gridColumnAlignment(gridColumnAlignment(for: alignmentForColumn(columnIndex)))
                        }
                    }

                    tableDivider

                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(0..<columnCount, id: \.self) { columnIndex in
                                tableCell(
                                    runs: runsForRow(row, columnIndex),
                                    alignment: alignmentForColumn(columnIndex),
                                    isHeader: false
                                )
                            }
                        }

                        if rowIndex < rows.count - 1 {
                            tableDivider
                        }
                    }
                }
            }
            .padding(1)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(colorScheme == .dark ? 0.24 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(colorScheme == .dark ? 0.10 : 0.08), lineWidth: 0.5)
                )
        )
    }

    private var tableDivider: some View {
        Rectangle()
            .fill(.white.opacity(colorScheme == .dark ? 0.10 : 0.08))
            .frame(height: 1)
            .gridCellColumns(columnCount)
    }

    @ViewBuilder
    private func tableCell(
        runs: [MarkdownInlineRun],
        alignment: MarkdownTableAlignment,
        isHeader: Bool
    ) -> some View {
        InlineRunsView(
            runs: runs,
            foregroundColor: foregroundColor,
            latexColor: latexColor,
            latexFontSize: 14,
            baseFont: .system(size: 14, weight: isHeader ? .semibold : .regular),
            colorScheme: colorScheme
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minWidth: 90, alignment: frameAlignment(for: alignment))
        .background(
            isHeader
                ? .white.opacity(colorScheme == .dark ? 0.07 : 0.04)
                : .clear
        )
    }

    private func alignmentForColumn(_ index: Int) -> MarkdownTableAlignment {
        guard alignments.indices.contains(index) else { return .left }
        return alignments[index]
    }

    private func runsForHeader(_ index: Int) -> [MarkdownInlineRun] {
        guard header.indices.contains(index) else { return [] }
        return header[index]
    }

    private func runsForRow(_ row: [[MarkdownInlineRun]], _ index: Int) -> [MarkdownInlineRun] {
        guard row.indices.contains(index) else { return [] }
        return row[index]
    }

    private func frameAlignment(for alignment: MarkdownTableAlignment) -> Alignment {
        switch alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func gridColumnAlignment(for alignment: MarkdownTableAlignment) -> HorizontalAlignment {
        switch alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

struct MarkdownMathView: View {
    let text: String
    let foregroundColor: Color
    let latexColor: NSColor

    @Environment(\.colorScheme) private var colorScheme
    @State private var parsed: [MarkdownBlock] = []
    @State private var parseTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(parsed) { block in
                blockView(block)
            }
        }
        .onAppear {
            scheduleParse()
        }
        .onChange(of: text) { _, _ in
            scheduleParse()
        }
        .onDisappear {
            parseTask?.cancel()
            parseTask = nil
        }
    }

    private func scheduleParse() {
        let snapshot = text
        parseTask?.cancel()
        parseTask = Task {
            // Debounce to reduce churn during streaming.
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled { return }
            let blocks = MarkdownParser.parse(snapshot)
            await MainActor.run {
                if snapshot == text {
                    parsed = blocks
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph(let runs):
            InlineRunsView(
                runs: runs,
                foregroundColor: foregroundColor,
                latexColor: latexColor,
                latexFontSize: 15,
                baseFont: .system(size: 15),
                colorScheme: colorScheme
            )

        case .heading(let level, let runs):
            let font: Font = {
                switch level {
                case 1: return .system(size: 20, weight: .semibold)
                case 2: return .system(size: 18, weight: .semibold)
                case 3: return .system(size: 16, weight: .semibold)
                default: return .system(size: 15, weight: .semibold)
                }
            }()

            InlineRunsView(
                runs: runs,
                foregroundColor: foregroundColor,
                latexColor: latexColor,
                latexFontSize: level == 1 ? 18 : (level == 2 ? 17 : (level == 3 ? 16 : 15)),
                baseFont: font,
                colorScheme: colorScheme
            )

        case .codeFence(let language, let code):
            CodeBlockView(
                language: language,
                code: code,
                colorScheme: colorScheme,
                foregroundColor: foregroundColor
            )

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, itemRuns in
                    HStack(alignment: .top, spacing: 8) {
                        Text("-")
                            .foregroundStyle(foregroundColor)
                            .padding(.top, 2)
                        InlineRunsView(
                            runs: itemRuns,
                            foregroundColor: foregroundColor,
                            latexColor: latexColor,
                            latexFontSize: 15,
                            baseFont: .system(size: 15),
                            colorScheme: colorScheme
                        )
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, itemRuns in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).")
                            .foregroundStyle(foregroundColor)
                            .padding(.top, 2)
                        InlineRunsView(
                            runs: itemRuns,
                            foregroundColor: foregroundColor,
                            latexColor: latexColor,
                            latexFontSize: 15,
                            baseFont: .system(size: 15),
                            colorScheme: colorScheme
                        )
                    }
                }
            }

        case .blockQuote(let runs):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(colorScheme == .dark ? 0.25 : 0.15))
                    .frame(width: 3)
                InlineRunsView(
                    runs: runs,
                    foregroundColor: foregroundColor.opacity(0.9),
                    latexColor: latexColor,
                    latexFontSize: 15,
                    baseFont: .system(size: 15),
                    colorScheme: colorScheme
                )
            }
            .padding(.vertical, 4)

        case .table(let header, let alignments, let rows):
            TableBlockView(
                header: header,
                alignments: alignments,
                rows: rows,
                colorScheme: colorScheme,
                foregroundColor: foregroundColor,
                latexColor: latexColor
            )

        case .horizontalRule:
            Rectangle()
                .fill(.white.opacity(colorScheme == .dark ? 0.14 : 0.10))
                .frame(height: 1)

        case .mathBlock(let latex):
            LatexBlockView(
                latex: latex,
                fontSize: 16,
                color: latexColor
            )
        }
    }
}
