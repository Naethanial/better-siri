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
            
            Text(message.content.isEmpty ? " " : message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    BubbleBackground(isUser: isUser)
                )
                .foregroundStyle(isUser ? .white : .primary)
            
            if !isUser {
                Spacer(minLength: 40)
            }
        }
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
                        .regular.tint(.blue.opacity(0.35)),
                        in: .rect(cornerRadius: cornerRadius)
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(.gray.opacity(0.2)),
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

#Preview {
    VStack(spacing: 12) {
        MessageBubbleView(message: ChatMessage(role: .user, content: "Hello, what's on my screen?"))
        MessageBubbleView(message: ChatMessage(role: .assistant, content: "I can see you have a code editor open with some Swift code. It looks like you're working on a macOS application."))
    }
    .padding()
    .frame(width: 400)
    .background(.black.opacity(0.5))
}
