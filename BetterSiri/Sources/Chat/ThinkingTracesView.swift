import SwiftUI

struct ThinkingTracesView: View {
    let traces: [ThinkingTraceItem]

    // Default to expanded so traces are visible immediately.
    @State private var isExpanded: Bool = true
    @Environment(\.controlActiveState) private var controlActiveState

    private var activeTraceTitle: String? {
        traces.first(where: { $0.status == .active })?.title
    }

    private var isActive: Bool {
        controlActiveState == .key
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isExpanded {
                Divider().opacity(0.35)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(traces) { trace in
                        traceRow(trace)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ThinkingCardBackground(isActive: isActive))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.12)) {
                isExpanded.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thinking")
        .accessibilityHint("Tap to expand thinking traces")
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("Thinking")
                    .font(.subheadline.weight(.semibold))
                if let activeTraceTitle {
                    Text(activeTraceTitle)
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
    private func traceRow(_ trace: ThinkingTraceItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIcon(for: trace.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(trace.title)
                    .font(.caption)
                    .foregroundStyle(trace.status == .failed ? .red : .primary)
                if let detail = trace.detail, !detail.isEmpty {
                    if trace.id == .modelReasoning {
                        StreamingCharacterTextView(
                            text: detail,
                            perCharacterDelay: 0.006,
                            maxRevealDurationPerUpdate: 0.30,
                            initialBlur: 9,
                            characterFadeDuration: 0.18
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func statusIcon(for status: ThinkingTraceStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.8))
                .frame(width: 14)

        case .active:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14)

        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)

        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(width: 14)
        }
    }
}

private struct ThinkingCardBackground: View {
    let isActive: Bool

    var body: some View {
        let cornerRadius: CGFloat = 14
        let borderOpacity = isActive ? 0.16 : 0.10

        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(.gray.opacity(0.18)).interactive(),
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
