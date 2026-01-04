import ScreenCaptureKit
import CoreGraphics
import AppKit

enum ScreenCaptureError: Error {
    case permissionDenied
    case noDisplayFound
    case captureFailure(String)
}

@MainActor
class ScreenCaptureService {
    
    func captureDisplayUnderCursor() async throws -> CGImage {
        // Get cursor position (must be on main actor)
        let mouse = NSEvent.mouseLocation
        
        // Find the screen containing the cursor
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen = screen else {
            throw ScreenCaptureError.noDisplayFound
        }
        
        // Get the display ID from the screen
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ScreenCaptureError.noDisplayFound
        }
        
        // Get available content
        let availableContent: SCShareableContent
        do {
            availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.permissionDenied
        }
        
        // Find the matching SCDisplay
        guard let scDisplay = availableContent.displays.first(where: { $0.displayID == displayID }) else {
            // Fallback to first display
            guard let fallbackDisplay = availableContent.displays.first else {
                throw ScreenCaptureError.noDisplayFound
            }
            return try await captureDisplay(fallbackDisplay)
        }
        
        return try await captureDisplay(scDisplay)
    }
    
    private func captureDisplay(_ display: SCDisplay) async throws -> CGImage {
        // Create the content filter for the entire display
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // Configure the stream
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        
        // Use the screenshot API (macOS 14+, and we're targeting 15+)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }
}
