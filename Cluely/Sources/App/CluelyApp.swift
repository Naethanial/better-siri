import SwiftUI
import KeyboardShortcuts

@main
struct CluelyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menubar icon + menu
        MenuBarExtra("Cluely", systemImage: "sparkles") {
            MenuBarView()
                .environmentObject(appDelegate.coordinator)
        }

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appDelegate.coordinator)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.shared.log("Application launched")
        // Register default shortcut if none exists
        if KeyboardShortcuts.getShortcut(for: .togglePanel) == nil {
            KeyboardShortcuts.setShortcut(.init(.period, modifiers: .command), for: .togglePanel)
        }

        // Set up the global hotkey listener
        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            self?.coordinator.togglePanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.shared.log("Application terminating")
        coordinator.cleanup()
    }
}

// Define the shortcut name
extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel")
}
