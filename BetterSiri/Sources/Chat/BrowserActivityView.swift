import AppKit
import SwiftUI

struct BrowserActivityItem: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let kind: String
    let step: Int?
    let summary: String
    let memory: String?
    let url: String?
    let title: String?
    let screenshotPath: String?
    let screenshotThumbPath: String?
}

struct BrowserActivityView: View {
    let items: [BrowserActivityItem]
    let latestScreenshotURL: URL?
    let isPaused: Bool

    @State private var isExpanded: Bool = true
    @Environment(\.controlActiveState) private var controlActiveState

    private var isActive: Bool {
        controlActiveState == .key
    }

    private var statusText: String {
        isPaused ? "Paused" : "Running"
    }

    private var lastSummary: String? {
        items.last?.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isExpanded {
                Divider().opacity(0.35)

                if let latestScreenshotURL, let image = NSImage(contentsOf: latestScreenshotURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 0.6)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items.suffix(6)) { item in
                        row(item)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(BrowserCardBackground(isActive: isActive))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.12)) {
                isExpanded.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Browser activity")
        .accessibilityHint("Tap to expand browser activity")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "safari")
                .font(.caption.weight(.semibold))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Browser")
                        .font(.subheadline.weight(.semibold))

                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isPaused ? .orange : .secondary)
                }

                if let lastSummary {
                    Text(lastSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
    }

    @ViewBuilder
    private func row(_ item: BrowserActivityItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.7))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let memory = item.memory, !memory.isEmpty, item.kind == "model_output" {
                    Text(memory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

private struct BrowserCardBackground: View {
    let isActive: Bool

    var body: some View {
        let cornerRadius: CGFloat = 14
        let borderOpacity = isActive ? 0.16 : 0.10

        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(.orange.opacity(0.16)).interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .environment(\.controlActiveState, .active)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.controlActiveState, .active)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(borderOpacity), lineWidth: 0.5)
                )
        }
    }
}
