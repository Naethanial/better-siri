import AppKit
import SwiftUI

/// Root wrapper that applies user's appearance preference to the panel.
struct PanelRootView<Content: View>: View {
    @AppStorage("appearance_mode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some View {
        content()
            .preferredColorScheme(appearanceMode.colorScheme)
    }
}

/// Helper to get the current NSAppearance based on the stored preference
func appearanceFromUserDefault() -> NSAppearance? {
    let raw = UserDefaults.standard.string(forKey: "appearance_mode") ?? AppearanceMode.system.rawValue
    let mode = AppearanceMode(rawValue: raw) ?? .system
    switch mode {
    case .system:
        return nil // follow system
    case .light:
        return NSAppearance(named: .aqua)
    case .dark:
        return NSAppearance(named: .darkAqua)
    }
}

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

        // Calculate initial position (bottom-left at cursor)
        let initialX = cursorPosition.x
        let panelBottomY = cursorPosition.y

        // Calculate max dimensions based on screen
        let maxWidth = min(expandedWidth, screen.visibleFrame.width * 0.6)
        let maxHeight = screen.visibleFrame.height * 0.5

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
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // Apply user's appearance preference to the window itself
        // This ensures AppKit views (like NSTextView) get the correct appearance from the start
        panel.appearance = appearanceFromUserDefault()

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

        // Wrap with appearance handling
        let rootView = PanelRootView {
            panelContentView
        }

        let hostingView = NSHostingView(rootView: AnyView(rootView))
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
