import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
class AppCoordinator: ObservableObject {
    @Published var isPanelOpen = false
    @Published var isCapturing = false

    private let screenCaptureService = ScreenCaptureService()
    private let panelController = FloatingPanelController()
    private var chatViewModel: ChatViewModel?

    init() {
        // Set up panel close callback
        panelController.onClose = { [weak self] in
            self?.isPanelOpen = false
            self?.chatViewModel = nil
            AppLog.shared.log("Panel closed")
        }
        AppLog.shared.log("App coordinator initialized")
    }

    func togglePanel() {
        // Always open/refresh when the shortcut is pressed
        openPanel()
    }

    func closePanel() {
        panelController.close()
        isPanelOpen = false
        chatViewModel = nil
        AppLog.shared.log("Panel close requested")
    }

    private func openPanel() {
        guard !isCapturing else { return }

        isCapturing = true
        AppLog.shared.log("Panel open requested")

        Task {
            do {
                // Capture the screen first
                let screenshot = try await screenCaptureService.captureDisplayUnderCursor()
                AppLog.shared.log("Screen captured")

                // Create the chat view model with the screenshot
                let viewModel = ChatViewModel(screenshot: screenshot)
                self.chatViewModel = viewModel

                // Get cursor position for panel placement
                let cursorPosition = NSEvent.mouseLocation

                // Get the screen containing the cursor
                let screen = NSScreen.screens.first { $0.frame.contains(cursorPosition) } ?? NSScreen.main!

                // Show the panel
                panelController.show(
                    at: cursorPosition,
                    on: screen,
                    viewModel: viewModel
                )

                isPanelOpen = true
                isCapturing = false
                AppLog.shared.log("Panel opened")

            } catch ScreenCaptureError.permissionDenied {
                isCapturing = false
                AppLog.shared.log("Screen capture permission denied", level: .error)
                showPermissionAlert()
            } catch {
                isCapturing = false
                AppLog.shared.log("Screen capture failed: \(error)", level: .error)
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Better Siri needs screen recording permission to capture context. Please enable it in System Settings > Privacy & Security > Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
                AppLog.shared.log("Opened System Settings for screen recording permission")
            }
        }
    }

    func cleanup() {
        closePanel()
    }

    func exportLogs() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "bettersiri.log"
        savePanel.canCreateDirectories = true

        let response = savePanel.runModal()
        guard response == .OK, let destinationURL = savePanel.url else { return }

        do {
            try AppLog.shared.export(to: destinationURL)
            AppLog.shared.log("Logs exported to \(destinationURL.path)")
        } catch {
            AppLog.shared.log("Failed to export logs: \(error)", level: .error)
        }
    }
}
