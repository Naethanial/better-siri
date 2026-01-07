import KeyboardShortcuts
import SwiftUI

@main
struct BetterSiriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menubar icon + menu
        MenuBarExtra("Better Siri", systemImage: "sparkles") {
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
        migrateBrowserUserDataDirIfNeeded()
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

    private func migrateBrowserUserDataDirIfNeeded() {
        let key = "browseruse_chrome_user_data_dir"
        guard let current = UserDefaults.standard.string(forKey: key) else { return }

        let oldDefault = "~/Library/Application Support/Google/Chrome"
        let oldDefaultExpanded = NSString(string: oldDefault).expandingTildeInPath
        guard current == oldDefault || current == oldDefaultExpanded else { return }

        let newDefault = "~/Library/Application Support/BetterSiri/Chrome"
        UserDefaults.standard.set(newDefault, forKey: key)
        AppLog.shared.log(
            "Migrated browser-use Chrome user data dir to non-default profile (required for remote debugging)."
        )
    }
}

// Define the shortcut name
extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel")
}
