import KeyboardShortcuts
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        Button("Toggle Assistant") {
            coordinator.togglePanel()
        }
        .keyboardShortcut(".", modifiers: .command)

        Divider()

        SettingsLink {
            Text("Settings...")
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
