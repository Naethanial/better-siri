import AppKit
import SwiftUI

struct LatexInlineView: View {
    let latex: String
    let fontSize: CGFloat
    let color: NSColor

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: image.size.width, height: image.size.height)
            } else {
                Text("$\(latex)$")
                    .font(.system(size: max(11, fontSize - 2), design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(latex)
        .task(id: cacheKey) {
            image = await LatexRenderer.shared.render(
                latex: latex,
                displayMode: false,
                fontSize: fontSize,
                color: color
            )
        }
    }

    private var cacheKey: String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return "I|\(Int(fontSize.rounded()))|\(Int(rgb.redComponent * 255))_\(Int(rgb.greenComponent * 255))_\(Int(rgb.blueComponent * 255))|\(latex)"
    }
}

struct LatexBlockView: View {
    let latex: String
    let fontSize: CGFloat
    let color: NSColor

    @Environment(\.colorScheme) private var colorScheme

    @State private var image: NSImage?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: image.size.width, height: image.size.height)
                } else {
                    Text("$$\n\(latex)\n$$")
                        .font(.system(size: max(11, fontSize - 2), design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(colorScheme == .dark ? 0.22 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(colorScheme == .dark ? 0.10 : 0.08), lineWidth: 0.5)
                )
        )
        .accessibilityLabel(latex)
        .task(id: cacheKey) {
            image = await LatexRenderer.shared.render(
                latex: latex,
                displayMode: true,
                fontSize: fontSize,
                color: color
            )
        }
    }

    private var cacheKey: String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return "D|\(Int(fontSize.rounded()))|\(Int(rgb.redComponent * 255))_\(Int(rgb.greenComponent * 255))_\(Int(rgb.blueComponent * 255))|\(latex)"
    }
}
