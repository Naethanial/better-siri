import SwiftUI
import KeyboardShortcuts

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
        
        Divider()
        
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
