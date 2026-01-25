import SwiftUI

private enum StreamingLayoutKeys {
    struct IsLineBreak: LayoutValueKey {
        static let defaultValue: Bool = false
    }
}

/// A simple flow layout that wraps subviews to the next line.
///
/// Used for per-character streaming effects while still supporting wrapping.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude

        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            if subview[StreamingLayoutKeys.IsLineBreak.self] {
                totalHeight += lineHeight
                usedWidth = max(usedWidth, lineWidth)
                lineWidth = 0
                lineHeight = 0
                continue
            }

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

        for subview in subviews {
            if subview[StreamingLayoutKeys.IsLineBreak.self] {
                y += lineHeight
                x = bounds.minX
                lineHeight = 0
                continue
            }

            let size = subview.sizeThatFits(.unspecified)

            if x > bounds.minX, x + spacing + size.width > bounds.minX + maxWidth {
                y += lineHeight
                x = bounds.minX
                lineHeight = 0
            }

            if x > bounds.minX {
                x += spacing
            }

            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))

            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct StreamingCharacterView: View {
    let character: Character
    let initialBlur: CGFloat
    let duration: Double

    @State private var isVisible: Bool = false

    var body: some View {
        Text(String(character))
            .opacity(isVisible ? 1 : 0)
            .blur(radius: isVisible ? 0 : initialBlur)
            .animation(.easeOut(duration: duration), value: isVisible)
            .onAppear {
                isVisible = true
            }
    }
}

struct StreamingCharacterTextView: View {
    let text: String
    var perCharacterDelay: Double = 0.008
    var maxRevealDurationPerUpdate: Double = 0.35
    var initialBlur: CGFloat = 10
    var characterFadeDuration: Double = 0.22

    @State private var visibleCount: Int = 0
    @State private var revealTask: Task<Void, Never>?

    private var characters: [Character] {
        Array(text)
    }

    var body: some View {
        FlowLayout(spacing: 0) {
            ForEach(0..<min(visibleCount, characters.count), id: \.self) { idx in
                let ch = characters[idx]
                if ch == "\n" {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .layoutValue(key: StreamingLayoutKeys.IsLineBreak.self, value: true)
                } else {
                    StreamingCharacterView(
                        character: ch,
                        initialBlur: initialBlur,
                        duration: characterFadeDuration
                    )
                }
            }
        }
        .onAppear {
            animateRevealIfNeeded()
        }
        .onChange(of: text) { _, _ in
            animateRevealIfNeeded()
        }
        .onDisappear {
            revealTask?.cancel()
            revealTask = nil
        }
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isStaticText)
    }

    private func animateRevealIfNeeded() {
        let target = characters.count
        guard target > visibleCount else { return }

        revealTask?.cancel()

        let start = visibleCount
        let delta = max(1, target - start)
        let effectiveDelay = min(perCharacterDelay, maxRevealDurationPerUpdate / Double(delta))

        revealTask = Task { @MainActor in
            for next in (start + 1)...target {
                if Task.isCancelled {
                    return
                }
                visibleCount = next
                let nanos = UInt64(effectiveDelay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }
}
