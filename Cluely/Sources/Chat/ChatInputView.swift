import SwiftUI
import AppKit

struct ChatInputView: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSubmit: () -> Void
    let onHeightChange: (CGFloat) -> Void
    
    @State private var textHeight: CGFloat = 22
    
    // Maximum 3 lines
    private let minHeight: CGFloat = 22
    private let maxHeight: CGFloat = 66  // ~3 lines
    private let verticalPadding: CGFloat = 11
    
    private var totalHeight: CGFloat {
        min(max(textHeight, minHeight), maxHeight) + (verticalPadding * 2)
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            GrowingTextEditor(
                text: $text,
                minHeight: minHeight,
                maxHeight: maxHeight,
                onHeightChange: { height in
                    textHeight = height
                    onHeightChange(totalHeight)
                },
                onSubmit: {
                    if !isStreaming {
                        onSubmit()
                    }
                }
            )
            .frame(height: min(max(textHeight, minHeight), maxHeight))
            .padding(.horizontal, 12)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    )
            )
            
            // Send button
            Button(action: {
                if !isStreaming {
                    onSubmit()
                }
            }) {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(text.isEmpty || isStreaming ? .white.opacity(0.3) : .white)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty || isStreaming)
        }
    }
}

struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onHeightChange: (CGFloat) -> Void
    let onSubmit: () -> Void
    
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
        var onSubmit: (() -> Void)?
        
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
    }
}

// Custom NSTextView to handle key events
class InputTextView: NSTextView {
    var onSubmitAction: (() -> Void)?
    
    override func keyDown(with event: NSEvent) {
        // Check for Return key
        if event.keyCode == 36 {  // Return key
            // Check if Shift is NOT pressed
            if !event.modifierFlags.contains(.shift) {
                // Submit
                if let coordinator = self.delegate as? GrowingTextEditor.Coordinator {
                    coordinator.onSubmit?()
                }
                return
            }
            // Shift+Return: insert newline (default behavior)
        }
        
        super.keyDown(with: event)
    }
}
