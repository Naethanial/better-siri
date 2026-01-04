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
    @State private var messagesHeight: CGFloat = 0
    @State private var inputHeight: CGFloat = 44
    @Environment(\.controlActiveState) private var controlActiveState

    private let inputBottomPadding: CGFloat = 12
    private let inputTopPaddingWithMessages: CGFloat = 8

    private var targetWidth: CGFloat {
        viewModel.hasSentFirstMessage ? min(expandedWidth, maxWidth) : initialWidth
    }

    private var hasMessages: Bool {
        !viewModel.messages.isEmpty
    }

    private var isActive: Bool {
        controlActiveState == .key
    }

    private var inputTopPadding: CGFloat {
        hasMessages ? inputTopPaddingWithMessages : 0
    }

    private var inputBlockHeight: CGFloat {
        inputHeight + inputTopPadding + inputBottomPadding
    }

    private var availableMessageHeight: CGFloat {
        max(0, maxHeight - inputBlockHeight)
    }

    private var messageBlockHeight: CGFloat {
        guard hasMessages else { return 0 }
        return min(messagesHeight, availableMessageHeight)
    }

    private var desiredHeight: CGFloat {
        messageBlockHeight + inputBlockHeight
    }

    private var desiredSize: CGSize {
        CGSize(width: targetWidth, height: min(desiredHeight, maxHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages (only show if there are messages)
            if hasMessages {
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
                        .readSize { size in
                            if size.height != messagesHeight {
                                messagesHeight = size.height
                            }
                        }
                    }
                    .frame(height: messageBlockHeight)
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
            .padding(.bottom, inputBottomPadding)
            .padding(.top, inputTopPadding)
        }
        .frame(width: targetWidth)
        .frame(maxHeight: maxHeight)
        .background {
            if hasMessages {
                GlassPanelBackground(cornerRadius: cornerRadius, isActive: isActive)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if hasMessages {
                PanelBorder(cornerRadius: cornerRadius, isActive: isActive)
            }
        }
        .compositingGroup()
        .shadow(
            color: hasMessages ? .black.opacity(isActive ? 0.28 : 0.18) : .clear,
            radius: hasMessages ? (isActive ? 20 : 16) : 0,
            x: 0,
            y: hasMessages ? 10 : 0
        )
        .onAppear {
            onSizeChange(desiredSize)
        }
        .onChange(of: desiredSize) { _, newSize in
            onSizeChange(newSize)
        }
        .onChange(of: viewModel.messages.isEmpty) { _, isEmpty in
            if isEmpty {
                messagesHeight = 0
            }
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }
}

struct GlassPanelBackground: View {
    let cornerRadius: CGFloat
    let isActive: Bool

    var body: some View {
        let highlightOpacity = isActive ? 0.22 : 0.12
        let highlight = LinearGradient(
            colors: [
                .white.opacity(highlightOpacity),
                .white.opacity(0.04),
                .clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        // Try Liquid Glass first, fall back to material
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(isActive ? .regular : .thin, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(highlight)
                        .blendMode(.screen)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(highlight)
                        .blendMode(.screen)
                )
        }
    }
}

struct PanelBorder: View {
    let cornerRadius: CGFloat
    let isActive: Bool

    var body: some View {
        if #available(macOS 26.0, *) {
            EmptyView()
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(isActive ? 0.2 : 0.12), lineWidth: 0.5)
        }
    }
}
