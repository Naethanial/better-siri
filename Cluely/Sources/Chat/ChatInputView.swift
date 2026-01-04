import SwiftUI
import AppKit

struct ChatInputView: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSubmit: () -> Bool
    let onHeightChange: (CGFloat) -> Void

    @State private var textHeight: CGFloat = 22
    @Environment(\.controlActiveState) private var controlActiveState

    // Maximum 3 lines
    private let minHeight: CGFloat = 22
    private let maxHeight: CGFloat = 66  // ~3 lines
    private let verticalPadding: CGFloat = 11

    private var totalHeight: CGFloat {
        min(max(textHeight, minHeight), maxHeight) + (verticalPadding * 2)
    }

    private var isActive: Bool {
        controlActiveState == .key
    }

    var body: some View {
        GrowingTextEditor(
            text: $text,
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
        .frame(height: min(max(textHeight, minHeight), maxHeight))
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .background(
            GlassInputBackground(cornerRadius: 12, isActive: isActive)
        )
    }
}

struct GlassInputBackground: View {
    let cornerRadius: CGFloat
    let isActive: Bool

    var body: some View {
        let highlightOpacity = isActive ? 0.16 : 0.08
        let borderOpacity = isActive ? 0.2 : 0.12
        let highlight = LinearGradient(
            colors: [
                .white.opacity(highlightOpacity),
                .white.opacity(0.04),
                .clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(isActive ? .regular : .thin, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(highlight)
                        .blendMode(.screen)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(borderOpacity), lineWidth: 0.6)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(isActive ? 0.1 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(highlight)
                        .blendMode(.screen)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(borderOpacity), lineWidth: 0.5)
                )
        }
    }
}

struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
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
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero

        // Configure text container for wrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

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
                  let textContainer = textView.textContainer else { return }

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
