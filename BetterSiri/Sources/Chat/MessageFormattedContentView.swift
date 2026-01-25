import SwiftUI

struct MessageFormattedContentView: View {
    let text: String
    let foregroundColor: Color

    var body: some View {
        MarkdownMathView(
            text: text.isEmpty ? " " : text,
            foregroundColor: foregroundColor,
            latexColor: NSColor(foregroundColor)
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}
