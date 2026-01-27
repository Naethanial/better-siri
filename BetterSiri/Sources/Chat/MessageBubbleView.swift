import AppKit
import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    var isStreamingThisMessage: Bool = false

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .top) {
            if isUser {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                MessageFormattedContentView(
                    text: message.content.isEmpty ? " " : message.content,
                    foregroundColor: isUser ? .white : .primary
                )
                .animation(.easeOut(duration: 0.12), value: message.content.count)
                .textSelection(.enabled)

                if !message.attachments.isEmpty {
                    AttachmentPreviewRow(attachments: message.attachments)
                    AttachmentRow(attachments: message.attachments, isUser: isUser)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(BubbleBackground(isUser: isUser))

            if !isUser {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

private struct AttachmentPreviewRow: View {
    let attachments: [ChatAttachment]

    private let maxShown: Int = 6

    var body: some View {
        let subset = Array(attachments.prefix(maxShown))

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(subset) { att in
                    AttachmentPreviewTile(attachment: att)
                }

                if attachments.count > subset.count {
                    Text("+\(attachments.count - subset.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.6)
                                )
                        )
                }
            }
        }
        .frame(height: 70)
    }
}

private struct AttachmentPreviewTile: View {
    let attachment: ChatAttachment

    private var url: URL {
        ChatAttachmentStore.fileURL(for: attachment)
    }

    private func previewImage() -> NSImage? {
        if attachment.kind == .image {
            return NSImage(contentsOf: url)
        }
        // For non-images, use the system file icon (more recognizable than generic symbols).
        if FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    var body: some View {
        let img = previewImage()

        return Button {
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.06))

                    if let img {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: attachment.kind == .image ? .fill : .fit)
                            .padding(attachment.kind == .image ? 0 : 10)
                    } else {
                        Image(systemName: "doc")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 90, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.6)
                )

                Text(attachment.filename)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 90, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") {
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button("Open") {
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .accessibilityLabel(attachment.filename)
    }
}

private struct AttachmentRow: View {
    let attachments: [ChatAttachment]
    let isUser: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { att in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: att.kind))
                            .font(.caption.weight(.semibold))
                        Text(att.filename)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isUser ? .white.opacity(0.95) : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isUser ? .white.opacity(0.14) : .white.opacity(0.10))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(.white.opacity(isUser ? 0.18 : 0.12), lineWidth: 0.6)
                            )
                    )
                }
            }
        }
        .frame(height: 28)
    }

    private func icon(for kind: ChatAttachment.Kind) -> String {
        switch kind {
        case .image:
            return "photo"
        case .pdf:
            return "doc.richtext"
        case .model:
            return "cube"
        case .other:
            return "doc"
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

#Preview {
    VStack(spacing: 12) {
        MessageBubbleView(message: ChatMessage(role: .user, content: "Hello, what's on my screen?"))
        MessageBubbleView(message: ChatMessage(role: .assistant, content: "I can see you have a code editor open with some Swift code. It looks like you're working on a macOS application."))
    }
    .padding()
    .frame(width: 400)
    .background(.black.opacity(0.5))
}
