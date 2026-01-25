import SwiftUI

struct ChatControlBarView: View {
    @Binding var isBrowserModeEnabled: Bool
    let isBusy: Bool
    let activeOperation: ChatViewModel.ActiveOperation?
    let isBrowserPaused: Bool
    let onStop: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TogglePill(
                title: "Browser",
                systemImage: "safari",
                isOn: $isBrowserModeEnabled,
                isDisabled: isBusy
            )

            Spacer(minLength: 8)

            if isBusy, activeOperation == .browser {
                if isBrowserPaused {
                    ControlButton(title: "Resume", systemImage: "play.fill", action: onResume)
                } else {
                    ControlButton(title: "Pause", systemImage: "pause.fill", action: onPause)
                }
            }

            if isBusy {
                StopButton(action: onStop)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(.clear)
    }
}

private struct TogglePill: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    let isDisabled: Bool

    var body: some View {
        Button {
            guard !isDisabled else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isOn ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isOn ? .white.opacity(0.18) : .white.opacity(0.10))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(isOn ? 0.22 : 0.12), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1.0)
        .accessibilityLabel(title)
        .accessibilityHint(isOn ? "On" : "Off")
    }
}

private struct ControlButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.7))
                    .overlay(
                        Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
                    )
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
    }
}
