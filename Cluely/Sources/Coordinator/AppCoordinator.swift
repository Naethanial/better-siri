import SwiftUI
import Combine

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
        }
    }
    
    func togglePanel() {
        if isPanelOpen {
            closePanel()
        } else {
            openPanel()
        }
    }
    
    func closePanel() {
        panelController.close()
        isPanelOpen = false
        chatViewModel = nil
    }
    
    private func openPanel() {
        guard !isCapturing else { return }
        
        isCapturing = true
        
        Task {
            do {
                // Capture the screen first
                let screenshot = try await screenCaptureService.captureDisplayUnderCursor()
                
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
                
            } catch ScreenCaptureError.permissionDenied {
                isCapturing = false
                showPermissionAlert()
            } catch {
                isCapturing = false
                print("Capture failed: \(error)")
            }
        }
    }
    
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Cluely needs screen recording permission to capture context. Please enable it in System Settings > Privacy & Security > Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    func cleanup() {
        closePanel()
    }
}
