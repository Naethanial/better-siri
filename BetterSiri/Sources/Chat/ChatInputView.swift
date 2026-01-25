import AppKit
import SwiftUI

struct ChatInputView: View {
    @Binding var text: String
    @Binding var isBrowserModeEnabled: Bool
    let isStreaming: Bool
    let onStop: () -> Void
    let onSubmit: () -> Bool
    let onHeightChange: (CGFloat) -> Void

    @State private var textHeight: CGFloat = 22
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme

    // Maximum 3 lines
    private let minHeight: CGFloat = 22
    private let maxHeight: CGFloat = 66  // ~3 lines
    private let verticalPadding: CGFloat = 11
    private let trailingControlWidth: CGFloat = 34
    private let trailingControlInset: CGFloat = 10

    private var totalHeight: CGFloat {
        min(max(textHeight, minHeight), maxHeight) + (verticalPadding * 2)
    }

    private var clampedTextHeight: CGFloat {
        min(max(textHeight, minHeight), maxHeight)
    }

    private var isActive: Bool {
        controlActiveState == .key
    }

    var body: some View {
        GrowingTextEditor(
            text: $text,
            colorScheme: colorScheme,
            minHeight: minHeight,
            maxHeight: maxHeight,
            onHeightChange: { height in
                textHeight = height
                onHeightChange(totalHeight)
            },
            onSubmit: {
                guard !isStreaming else { return false }
                return onSubmit()
            }
        )
        .blendMode(.difference)
        .frame(height: clampedTextHeight)
        .padding(.leading, 12)
        .padding(.trailing, 12 + trailingControlWidth + trailingControlInset)
        .padding(.vertical, verticalPadding)
        .background(
            ZStack {
                // Exclusion layer rendered BELOW the liquid glass
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white)
                    .blendMode(.exclusion)
                    .opacity(0.2)  // Subtle intensity

                GlassInputBackground(cornerRadius: 12, isActive: isActive)
            }
        )
        .overlay(alignment: .trailing) {
            trailingControl
                .padding(.trailing, trailingControlInset)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isStreaming {
            StopControlButton(action: onStop)
        } else {
            BrowserToggleButton(isOn: $isBrowserModeEnabled)
        }
    }
}

private struct BrowserToggleButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle().fill(isOn ? Color.blue.opacity(0.16) : Color.clear)
                    )
                    .overlay(
                        Circle().strokeBorder(
                            isOn ? Color.blue.opacity(0.55) : Color.white.opacity(0.14),
                            lineWidth: 0.8
                        )
                    )

                Image(systemName: "safari")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isOn ? .white : .secondary)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browser")
        .accessibilityHint(isOn ? "On" : "Off")
    }
}

private struct StopControlButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle().fill(Color.red.opacity(0.18))
                    )
                    .overlay(
                        Circle().strokeBorder(Color.red.opacity(0.60), lineWidth: 0.8)
                    )
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
    }
}

struct GlassInputBackground: View {
    let cornerRadius: CGFloat
    let isActive: Bool

    var body: some View {
        let borderOpacity = isActive ? 0.2 : 0.12

        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(borderOpacity), lineWidth: 0.6)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(isActive ? 0.08 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(borderOpacity), lineWidth: 0.5)
                )
        }
    }
}

struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    let colorScheme: ColorScheme
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onHeightChange: (CGFloat) -> Void
    let onSubmit: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = InputTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero

        // Set initial text color based on colorScheme
        let textColor: NSColor = colorScheme == .dark ? .white : .black
        textView.textColor = textColor
        textView.insertionPointColor = textColor

        // Configure text container for wrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)

        // Store references
        context.coordinator.textView = textView
        context.coordinator.onSubmit = onSubmit

        scrollView.documentView = textView

        // Focus the text view after a brief delay to ensure the window is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Update text color based on SwiftUI colorScheme (respects preferredColorScheme)
        let textColor: NSColor = colorScheme == .dark ? .white : .black
        textView.textColor = textColor
        textView.insertionPointColor = textColor

        if textView.string != text {
            textView.string = text
            context.coordinator.updateHeight()
        }
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextEditor
        var textView: NSTextView?
        var onSubmit: (() -> Bool)?

        init(_ parent: GrowingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView = textView else { return }

            // Calculate the height needed for the text
            guard let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)

            let newHeight = max(parent.minHeight, min(usedRect.height, parent.maxHeight))
            parent.onHeightChange(newHeight)
        }

        func submitIfPossible() {
            guard let didSubmit = onSubmit?(), didSubmit else { return }
            parent.text = ""
            textView?.string = ""
            updateHeight()
        }
    }
}

// Custom NSTextView to handle key events
class InputTextView: NSTextView {
    var onSubmitAction: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Check for Return key
        if event.keyCode == 36 || event.keyCode == 76 {  // Return or keypad Enter
            // Check if Shift is NOT pressed
            if !event.modifierFlags.contains(.shift) {
                // Submit
                if let coordinator = self.delegate as? GrowingTextEditor.Coordinator {
                    coordinator.submitIfPossible()
                }
                return
            }
            // Shift+Return: insert newline (default behavior)
        }

        super.keyDown(with: event)
    }
}
