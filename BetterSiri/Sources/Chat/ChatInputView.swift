import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ChatInputView: View {
    @Binding var text: String
    @Binding var attachments: [ChatAttachment]
    @Binding var isBrowserModeEnabled: Bool
    @Binding var isOnShapeModeEnabled: Bool
    let isStreaming: Bool
    let onAddAttachments: ([URL]) -> Void
    let onStop: () -> Void
    let onSubmit: () -> Bool
    let onHeightChange: (CGFloat) -> Void

    @AppStorage("onshape_enabled") private var onshapeEnabled: Bool = true

    @State private var textHeight: CGFloat = 22
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme

    // Maximum 3 lines
    private let minHeight: CGFloat = 22
    private let maxHeight: CGFloat = 66  // ~3 lines
    private let verticalPadding: CGFloat = 11
    private let trailingControlWidth: CGFloat = 76
    private let trailingControlInset: CGFloat = 10
    private let attachmentRowHeight: CGFloat = 30
    private let attachmentHeaderHeight: CGFloat = 16
    private let attachmentStripInnerSpacing: CGFloat = 6

    private var attachmentStripHeight: CGFloat {
        attachmentHeaderHeight + attachmentStripInnerSpacing + attachmentRowHeight
    }

    private var totalHeight: CGFloat {
        let base = min(max(textHeight, minHeight), maxHeight) + (verticalPadding * 2)
        // +8 accounts for the VStack spacing between attachment strip and text editor.
        return attachments.isEmpty ? base : base + attachmentStripHeight + 8
    }

    private var clampedTextHeight: CGFloat {
        min(max(textHeight, minHeight), maxHeight)
    }

    private var isActive: Bool {
        controlActiveState == .key
    }

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                attachmentStrip
            }

            GrowingTextEditor(
                text: $text,
                colorScheme: colorScheme,
                minHeight: minHeight,
                maxHeight: maxHeight,
                onHeightChange: { height in
                    textHeight = height
                    onHeightChange(totalHeight)
                },
                onSubmit: {
                    guard !isStreaming else { return false }
                    return onSubmit()
                },
                onPasteFileURLs: { urls in
                    guard !isStreaming else { return }
                    onAddAttachments(urls)
                    onHeightChange(totalHeight)
                }
            )
            .blendMode(.difference)
            .frame(height: clampedTextHeight)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12 + trailingControlWidth + trailingControlInset)
        .padding(.vertical, verticalPadding)
        .background(
            ZStack {
                // Exclusion layer rendered BELOW the liquid glass
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white)
                    .blendMode(.exclusion)
                    .opacity(0.2)  // Subtle intensity

                GlassInputBackground(cornerRadius: 12, isActive: isActive)
            }
        )
        .overlay(alignment: .trailing) {
            trailingControl
                .padding(.trailing, trailingControlInset)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard !isStreaming else { return false }
            var urls: [URL] = []
            let group = DispatchGroup()

            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        DispatchQueue.main.async {
                            group.leave()
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        urls.append(url)
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                if !urls.isEmpty {
                    onAddAttachments(urls)
                    onHeightChange(totalHeight)
                }
            }

            return true
        }
    }

    private var attachmentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Attachments (\(attachments.count))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { att in
                        AttachmentChip(
                            attachment: att,
                            onRemove: {
                                attachments.removeAll(where: { $0.id == att.id })
                                onHeightChange(totalHeight)
                            }
                        )
                    }
                }
                .frame(height: attachmentRowHeight)
            }
            .frame(height: attachmentRowHeight)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isStreaming {
            StopControlButton(action: onStop)
        } else {
            HStack(spacing: 8) {
                if onshapeEnabled {
                    OnShapeToggleButton(isOn: $isOnShapeModeEnabled)
                }
                BrowserToggleButton(isOn: $isBrowserModeEnabled)
            }
        }
    }
}

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    private var fileURL: URL {
        ChatAttachmentStore.fileURL(for: attachment)
    }

    private func iconImage() -> NSImage? {
        if attachment.kind == .image {
            return NSImage(contentsOf: fileURL)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return NSWorkspace.shared.icon(forFile: fileURL.path)
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if let img = iconImage() {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: attachment.kind == .image ? .fill : .fit)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: "doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(attachment.kind.rawValue.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(0.10))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                )
        )
    }
}

private struct OnShapeToggleButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle().fill(isOn ? Color.green.opacity(0.16) : Color.clear)
                    )
                    .overlay(
                        Circle().strokeBorder(
                            isOn ? Color.green.opacity(0.55) : Color.white.opacity(0.14),
                            lineWidth: 0.8
                        )
                    )

                Image(systemName: "cube")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isOn ? .white : .secondary)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("OnShape")
        .accessibilityHint(isOn ? "On" : "Off")
    }
}

private struct BrowserToggleButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle().fill(isOn ? Color.blue.opacity(0.16) : Color.clear)
                    )
                    .overlay(
                        Circle().strokeBorder(
                            isOn ? Color.blue.opacity(0.55) : Color.white.opacity(0.14),
                            lineWidth: 0.8
                        )
                    )

                Image(systemName: "safari")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isOn ? .white : .secondary)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browser")
        .accessibilityHint(isOn ? "On" : "Off")
    }
}

private struct StopControlButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle().fill(Color.red.opacity(0.18))
                    )
                    .overlay(
                        Circle().strokeBorder(Color.red.opacity(0.60), lineWidth: 0.8)
                    )
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
    }
}

struct GlassInputBackground: View {
    let cornerRadius: CGFloat
    let isActive: Bool

    var body: some View {
        let borderOpacity = isActive ? 0.2 : 0.12

        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(borderOpacity), lineWidth: 0.6)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(isActive ? 0.08 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(borderOpacity), lineWidth: 0.5)
                )
        }
    }
}

struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    let colorScheme: ColorScheme
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onHeightChange: (CGFloat) -> Void
    let onSubmit: () -> Bool
    let onPasteFileURLs: (([URL]) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = InputTextView()
        textView.delegate = context.coordinator
        textView.onPasteFileURLs = onPasteFileURLs
        textView.registerForDraggedTypes([
            .fileURL,
            .URL,
            .tiff,
            .png,
        ])
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero

        // Set initial text color based on colorScheme
        let textColor: NSColor = colorScheme == .dark ? .white : .black
        textView.textColor = textColor
        textView.insertionPointColor = textColor

        // Configure text container for wrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)

        // Store references
        context.coordinator.textView = textView
        context.coordinator.onSubmit = onSubmit

        scrollView.documentView = textView

        // Focus the text view after a brief delay to ensure the window is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Update text color based on SwiftUI colorScheme (respects preferredColorScheme)
        let textColor: NSColor = colorScheme == .dark ? .white : .black
        textView.textColor = textColor
        textView.insertionPointColor = textColor

        if textView.string != text {
            textView.string = text
            context.coordinator.updateHeight()
        }
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextEditor
        var textView: NSTextView?
        var onSubmit: (() -> Bool)?

        init(_ parent: GrowingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView = textView else { return }

            // Calculate the height needed for the text
            guard let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)

            let newHeight = max(parent.minHeight, min(usedRect.height, parent.maxHeight))
            parent.onHeightChange(newHeight)
        }

        func submitIfPossible() {
            guard let didSubmit = onSubmit?(), didSubmit else { return }
            parent.text = ""
            textView?.string = ""
            updateHeight()
        }
    }
}

// Custom NSTextView to handle key events
class InputTextView: NSTextView {
    var onSubmitAction: (() -> Void)?
    var onPasteFileURLs: (([URL]) -> Void)?

    private func writeTempFile(_ data: Data, ext: String) -> URL? {
        let safeExt = ext.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileExt = safeExt.isEmpty ? "bin" : safeExt
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bettersiri_drop_\(UUID().uuidString).\(fileExt)")
        do {
            try data.write(to: tmp, options: [.atomic])
            return tmp
        } catch {
            return nil
        }
    }

    private func extractFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    private func extractImageAsTempFile(from pasteboard: NSPasteboard) -> URL? {
        // Prefer explicit PNG if present.
        if let png = pasteboard.data(forType: .png) {
            return writeTempFile(png, ext: "png")
        }

        // Fall back to TIFF.
        if let tiff = pasteboard.data(forType: .tiff) {
            return writeTempFile(tiff, ext: "tiff")
        }

        // Last resort: try NSImage conversion.
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = images.first,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return writeTempFile(png, ext: "png")
        }

        return nil
    }

    private func canExtractImage(from pasteboard: NSPasteboard) -> Bool {
        if pasteboard.data(forType: .png) != nil { return true }
        if pasteboard.data(forType: .tiff) != nil { return true }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        return false
    }

    override func keyDown(with event: NSEvent) {
        // Check for Return key
        if event.keyCode == 36 || event.keyCode == 76 {  // Return or keypad Enter
            // Check if Shift is NOT pressed
            if !event.modifierFlags.contains(.shift) {
                // Submit
                if let coordinator = self.delegate as? GrowingTextEditor.Coordinator {
                    coordinator.submitIfPossible()
                }
                return
            }
            // Shift+Return: insert newline (default behavior)
        }

        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        // Prefer turning pasted files/images into attachments, instead of inserting junk text.
        let pb = NSPasteboard.general

        let urls = extractFileURLs(from: pb)
        if !urls.isEmpty {
            onPasteFileURLs?(urls)
            return
        }

        // Pasted image data (e.g., from Preview/Chrome) -> write temp file and attach.
        if let tmp = extractImageAsTempFile(from: pb) {
            onPasteFileURLs?([tmp])
            return
        }

        // Pasted PDF data -> write temp file and attach.
        if let pdfData = pb.data(forType: .pdf) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("bettersiri_paste_\(UUID().uuidString).pdf")
            do {
                try pdfData.write(to: tmp, options: [.atomic])
                onPasteFileURLs?([tmp])
                return
            } catch {
                // Fall through.
            }
        }

        super.paste(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if !extractFileURLs(from: pb).isEmpty {
            return .copy
        }
        if canExtractImage(from: pb) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if !extractFileURLs(from: pb).isEmpty {
            return true
        }
        if canExtractImage(from: pb) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        let urls = extractFileURLs(from: pb)
        if !urls.isEmpty {
            onPasteFileURLs?(urls)
            return true
        }

        if let tmp = extractImageAsTempFile(from: pb) {
            onPasteFileURLs?([tmp])
            return true
        }

        return super.performDragOperation(sender)
    }
}
