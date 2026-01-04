import SwiftUI

struct PanelContentView: View {
    @ObservedObject var viewModel: ChatViewModel
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let cornerRadius: CGFloat
    let onSizeChange: (CGSize) -> Void
    let onClose: () -> Void
    
    // Width phases
    private let initialWidth: CGFloat = 380
    private let expandedWidth: CGFloat = 520
    
    // Track measured content size
    @State private var contentSize: CGSize = .zero
    @State private var inputHeight: CGFloat = 44
    
    private var targetWidth: CGFloat {
        viewModel.hasSentFirstMessage ? min(expandedWidth, maxWidth) : initialWidth
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Drag handle area
            DragHandleView()
            
            // Messages (only show if there are messages)
            if !viewModel.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: viewModel.messages.last?.content) { _, _ in
                        // Auto-scroll to bottom when content changes
                        if let lastMessage = viewModel.messages.last {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            
            // Input area
            ChatInputView(
                text: $viewModel.inputText,
                isStreaming: viewModel.isStreaming,
                onSubmit: {
                    viewModel.sendMessage()
                },
                onHeightChange: { height in
                    inputHeight = height
                }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, viewModel.messages.isEmpty ? 0 : 8)
        }
        .frame(width: targetWidth)
        .frame(maxHeight: maxHeight)
        .background(
            GlassPanelBackground(cornerRadius: cornerRadius)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            if newSize != contentSize {
                contentSize = newSize
                onSizeChange(newSize)
            }
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }
}

struct DragHandleView: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 20)
            .overlay(
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(width: 36, height: 5)
            )
    }
}

struct GlassPanelBackground: View {
    let cornerRadius: CGFloat
    
    var body: some View {
        // Try Liquid Glass first, fall back to material
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }
}
