import KeyboardShortcuts
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @AppStorage("browseruse_enabled") private var browserUseEnabled: Bool = false
    @AppStorage("browseruse_chrome_executable_path") private var browserUseChromeExecutablePath:
        String = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    @AppStorage("browseruse_chrome_user_data_dir") private var browserUseChromeUserDataDir: String =
        "~/Library/Application Support/BetterSiri/Chrome"
    @AppStorage("browseruse_chrome_profile_directory") private var browserUseChromeProfileDirectory:
        String = "Default"
    @AppStorage("browseruse_remote_debugging_port") private var browserUseRemoteDebuggingPort: Int =
        9222

    var body: some View {
        Button("Toggle Assistant") {
            coordinator.togglePanel()
        }
        .keyboardShortcut(".", modifiers: .command)

        Divider()

        if browserUseEnabled {
            Button("Open Browser") {
                Task {
                    do {
                        _ = try await ChromeRemoteDebuggingService.shared.ensureAvailable(
                            chromeExecutablePath: browserUseChromeExecutablePath,
                            chromeUserDataDir: browserUseChromeUserDataDir,
                            chromeProfileDirectory: browserUseChromeProfileDirectory,
                            remoteDebuggingPort: browserUseRemoteDebuggingPort,
                            launchIfNeeded: true
                        )
                    } catch {
                        AppLog.shared.log("Failed to open browser: \(error)", level: .error)
                    }
                }
            }

            Divider()
        }

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
