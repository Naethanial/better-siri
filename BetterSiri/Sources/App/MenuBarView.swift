import SwiftUI
import KeyboardShortcuts
import Foundation

struct MenuBarView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    private struct ChatSessionGroup: Identifiable {
        let id: Date
        let label: String
        let sessions: [ChatSession]
    }

    private var chatSessionGroups: [ChatSessionGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        let grouped = Dictionary(grouping: coordinator.chatSessions) {
            calendar.startOfDay(for: $0.updatedAt)
        }

        return grouped
            .keys
            .sorted(by: >)
            .map { day in
                let label: String
                if calendar.isDate(day, inSameDayAs: today) {
                    label = "Today"
                } else if calendar.isDate(day, inSameDayAs: yesterday) {
                    label = "Yesterday"
                } else {
                    label = day.formatted(date: .abbreviated, time: .omitted)
                }

                let sessions = (grouped[day] ?? [])
                    .sorted(by: { $0.updatedAt > $1.updatedAt })

                return ChatSessionGroup(id: day, label: label, sessions: sessions)
            }
    }

    var body: some View {
        Button("Toggle Assistant") {
            coordinator.togglePanel()
        }
        .keyboardShortcut(".", modifiers: .command)

        Divider()

        Button("Settings...") {
            AppLog.shared.log("Settings window requested")
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)

        Menu("Conversations") {
            if coordinator.chatSessions.isEmpty {
                Text("No saved conversations")
                    .foregroundStyle(.secondary)
                    .disabled(true)
            } else {
                ForEach(Array(chatSessionGroups.enumerated()), id: \.offset) { index, group in
                    if index != 0 {
                        Divider()
                    }

                    Text(group.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .disabled(true)

                    ForEach(group.sessions) { session in
                        Button(session.title) {
                            coordinator.openSavedChat(session.id)
                        }
                    }
                }
            }
        }

        Button("Export Logs...") {
            coordinator.exportLogs()
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
