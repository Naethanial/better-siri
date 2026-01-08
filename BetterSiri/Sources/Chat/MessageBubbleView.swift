import LaTeXSwiftUI
import MarkdownUI
import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack {
            if isUser {
                Spacer(minLength: 40)
            }

            if !isUser, let activity = message.assistantActivity {
                AssistantActivityView(activity: activity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                MessageRichTextView(
                    text: message.content.isEmpty ? " " : message.content,
                    foregroundColor: isUser ? .white : .primary
                )
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    BubbleBackground(isUser: isUser)
                )
            }

            if !isUser {
                Spacer(minLength: 40)
            }
        }
    }
}

private struct MessageRichTextView: View {
    let text: String
    let foregroundColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MessageMarkupSegmenter.segments(from: text).enumerated()), id: \.offset) {
                _, segment in
                switch segment {
                case .markdown(let markdown):
                    Markdown(markdown)
                        .foregroundStyle(foregroundColor)

                case .latex(let latex):
                    LaTeX(latex)
                        .font(.body)
                        .foregroundStyle(foregroundColor)
                        .parsingMode(.onlyEquations)
                        .blockMode(.blockViews)
                        .renderingStyle(.original)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private enum MessageMarkupSegment: Equatable {
    case markdown(String)
    case latex(String)
}

private enum MessageMarkupSegmenter {
    static func segments(from input: String) -> [MessageMarkupSegment] {
        guard !input.isEmpty else { return [.markdown(" ")] }

        var remaining = input[...]
        var segments: [MessageMarkupSegment] = []

        func appendMarkdown(_ substring: Substring) {
            guard !substring.isEmpty else { return }
            segments.append(.markdown(String(substring)))
        }

        while !remaining.isEmpty {
            let codeFence = remaining.range(of: "```")
            let latexStart = nextLatexStart(in: remaining)

            if let codeFence, latexStart == nil || codeFence.lowerBound <= latexStart!.lowerBound {
                appendMarkdown(remaining[..<codeFence.lowerBound])

                let afterStart = codeFence.upperBound
                if let endFence = remaining.range(of: "```", range: afterStart..<remaining.endIndex)
                {
                    let block = remaining[codeFence.lowerBound..<endFence.upperBound]
                    segments.append(.markdown(String(block)))
                    remaining = remaining[endFence.upperBound...]
                } else {
                    // Unterminated code fence; treat the rest as Markdown.
                    segments.append(.markdown(String(remaining[codeFence.lowerBound...])))
                    break
                }
            } else if let latexStart {
                appendMarkdown(remaining[..<latexStart.lowerBound])

                guard let latexBlock = latexEndRange(forStart: latexStart, in: remaining) else {
                    // Unterminated equation; treat the rest as Markdown.
                    segments.append(.markdown(String(remaining[latexStart.lowerBound...])))
                    break
                }

                segments.append(.latex(String(remaining[latexBlock])))
                remaining = remaining[latexBlock.upperBound...]
            } else {
                appendMarkdown(remaining)
                break
            }
        }

        return coalesceMarkdownSegments(segments)
    }

    private static func nextLatexStart(in input: Substring) -> Range<Substring.Index>? {
        let candidates: [Range<Substring.Index>?] = [
            input.range(of: "$$"),
            input.range(of: "\\["),
            input.range(of: "\\begin{equation*}"),
            input.range(of: "\\begin{equation}"),
        ]

        return candidates.compactMap { $0 }.min(by: { $0.lowerBound < $1.lowerBound })
    }

    private static func latexEndRange(forStart start: Range<Substring.Index>, in input: Substring)
        -> Range<Substring.Index>?
    {
        let startToken = String(input[start])

        let endToken: String
        if startToken == "$$" {
            endToken = "$$"
        } else if startToken == "\\[" {
            endToken = "\\]"
        } else if startToken == "\\begin{equation*}" {
            endToken = "\\end{equation*}"
        } else if startToken == "\\begin{equation}" {
            endToken = "\\end{equation}"
        } else {
            return nil
        }

        let searchStart = start.upperBound
        guard let end = input.range(of: endToken, range: searchStart..<input.endIndex) else {
            return nil
        }
        return start.lowerBound..<end.upperBound
    }

    private static func coalesceMarkdownSegments(_ segments: [MessageMarkupSegment])
        -> [MessageMarkupSegment]
    {
        var output: [MessageMarkupSegment] = []

        for segment in segments {
            switch segment {
            case .markdown(let nextText):
                if case .markdown(let currentText) = output.last {
                    output[output.count - 1] = .markdown(currentText + nextText)
                } else {
                    output.append(segment)
                }

            case .latex:
                output.append(segment)
            }
        }

        return output
    }
}

private struct AssistantActivityView: View {
    let activity: ChatAssistantActivity

    private var titleText: String {
        activity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Thinking"
            : activity.title
    }

    private var logText: String {
        activity.log.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleText)
                .font(.system(size: 16, weight: .thin, design: .default))
                .foregroundStyle(.white.opacity(0.35))
                .shimmering()

            if !logText.isEmpty {
                Text(logText)
                    .font(.system(size: 12, weight: .thin, design: .default))
                    .foregroundStyle(.white.opacity(0.25))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity)
    }
}

struct BubbleBackground: View {
    let isUser: Bool

    private let cornerRadius: CGFloat = 14

    var body: some View {
        if #available(macOS 26.0, *) {
            // Liquid Glass bubbles
            // Pin assistant bubble to .active so it stays vibrant when unfocused
            if isUser {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(.blue.opacity(0.35)).interactive(),
                        in: .rect(cornerRadius: cornerRadius)
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(.gray.opacity(0.2)).interactive(),
                        in: .rect(cornerRadius: cornerRadius)
                    )
                    .environment(\.controlActiveState, .active)
            }
        } else {
            // Fallback for older macOS
            // Pin assistant bubble to .active so it stays vibrant when unfocused
            if isUser {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.blue.opacity(0.8))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.controlActiveState, .active)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                    )
            }
        }
    }
}

private struct ShimmeringModifier: ViewModifier {
    @State private var phase: CGFloat = -1
    let duration: TimeInterval

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    LinearGradient(
                        colors: [
                            .white.opacity(0.05),
                            .white.opacity(0.55),
                            .white.opacity(0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: width * 3)
                    .rotationEffect(.degrees(18))
                    .offset(x: phase * width * 2)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                phase = -1
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    fileprivate func shimmering(duration: TimeInterval = 1.35) -> some View {
        modifier(ShimmeringModifier(duration: duration))
    }
}

#Preview {
    VStack(spacing: 12) {
        MessageBubbleView(message: ChatMessage(role: .user, content: "Hello, what's on my screen?"))
        MessageBubbleView(
            message: ChatMessage(
                role: .assistant,
                content:
                    "I can see you have a code editor open with some Swift code. It looks like you're working on a macOS application."
            ))
    }
    .padding()
    .frame(width: 400)
    .background(.black.opacity(0.5))
}
