import AppKit
import SwiftUI

@MainActor
class FloatingPanelController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    
    // Anchors for resize behavior
    private var anchorLeftX: CGFloat = 0
    private var anchorBottomY: CGFloat = 0
    
    // Size constraints
    private let initialWidth: CGFloat = 380
    private let expandedWidth: CGFloat = 520
    private let minHeight: CGFloat = 70
    private let cornerRadius: CGFloat = 16
    
    var onClose: (() -> Void)?
    
    func show(at cursorPosition: CGPoint, on screen: NSScreen, viewModel: ChatViewModel) {
        close()
        
        // Calculate initial position (bottom-left at cursor + offset)
        let offsetX: CGFloat = 12
        let offsetY: CGFloat = -12
        let initialX = cursorPosition.x + offsetX
        let initialY = cursorPosition.y + offsetY
        
        // Calculate max dimensions based on screen
        let maxWidth = min(expandedWidth, screen.visibleFrame.width * 0.6)
        let maxHeight = screen.visibleFrame.height * 0.5
        
        // The bottom-left corner of the panel is at (initialX, initialY - minHeight)
        // because in macOS coordinates, y increases upward
        let panelBottomY = initialY - minHeight
        
        // Store anchors (these are where the panel's origin is)
        anchorLeftX = initialX
        anchorBottomY = panelBottomY
        
        // Create the panel
        let panel = FloatingPanel(
            contentRect: NSRect(x: initialX, y: panelBottomY, width: initialWidth, height: minHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        
        // Create the content view
        let panelContentView = PanelContentView(
            viewModel: viewModel,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            cornerRadius: cornerRadius,
            onSizeChange: { [weak self] newSize in
                self?.updatePanelSize(newSize)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        
        let hostingView = NSHostingView(rootView: AnyView(panelContentView))
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        
        panel.contentView = hostingView
        
        // Store references
        self.panel = panel
        self.hostingView = hostingView
        
        // Set up window move observer to update anchors
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateAnchorsAfterMove()
            }
        }
        
        // Show the panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func close() {
        panel?.close()
        panel = nil
        hostingView = nil
        onClose?()
    }
    
    private func updateAnchorsAfterMove() {
        guard let panel = panel else { return }
        anchorLeftX = panel.frame.minX
        anchorBottomY = panel.frame.minY
    }
    
    private func updatePanelSize(_ newSize: CGSize) {
        guard let panel = panel else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        
        // Calculate new frame with anchors (grow up and right)
        var newFrame = NSRect(
            x: anchorLeftX,
            y: anchorBottomY,
            width: newSize.width,
            height: newSize.height
        )
        
        // Clamp to screen visible frame
        let visibleFrame = screen.visibleFrame
        
        // If would go off right edge, shift left
        if newFrame.maxX > visibleFrame.maxX {
            newFrame.origin.x = visibleFrame.maxX - newFrame.width
        }
        
        // If would go off left edge, shift right
        if newFrame.minX < visibleFrame.minX {
            newFrame.origin.x = visibleFrame.minX
        }
        
        // If would go above top of screen, shift down
        if newFrame.maxY > visibleFrame.maxY {
            newFrame.origin.y = visibleFrame.maxY - newFrame.height
        }
        
        // If would go below bottom of screen, shift up
        if newFrame.minY < visibleFrame.minY {
            newFrame.origin.y = visibleFrame.minY
        }
        
        // Only animate if the change is significant
        let currentFrame = panel.frame
        let widthDelta = abs(newFrame.width - currentFrame.width)
        let heightDelta = abs(newFrame.height - currentFrame.height)
        
        if widthDelta > 8 || heightDelta > 8 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else if widthDelta > 0 || heightDelta > 0 {
            panel.setFrame(newFrame, display: true)
        }
    }
}

// Custom NSPanel subclass for additional control
class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    
    override func keyDown(with event: NSEvent) {
        // Handle Escape to close
        if event.keyCode == 53 { // Escape key
            close()
            return
        }
        super.keyDown(with: event)
    }
}
