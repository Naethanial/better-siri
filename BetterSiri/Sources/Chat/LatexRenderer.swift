import AppKit
import Foundation
import WebKit

@MainActor
final class LatexRenderer: NSObject, WKNavigationDelegate {
    static let shared = LatexRenderer()

    private let webView: WKWebView
    private var isReady: Bool = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    private let cache = NSCache<NSString, NSImage>()

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2048, height: 2048), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        loadBasePage()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        markReady()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        markReady()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        markReady()
    }

    private func markReady() {
        isReady = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for w in waiters {
            w.resume()
        }
    }

    private func ensureReady() async {
        if isReady { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            readyWaiters.append(cont)
        }
    }

    private func loadBasePage() {
        isReady = false
        guard let htmlURL = locateBaseHTML() else {
            // If resources are missing for some reason, unblock waiters and fall back to plain text.
            AppLog.shared.log("KaTeX resources missing: index.html not found", level: .error)
            isReady = true
            return
        }

        let baseURL = htmlURL.deletingLastPathComponent()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: baseURL)
    }

    private func locateBaseHTML() -> URL? {
        if let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "KaTeX") {
            return url
        }
        if let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Resources/KaTeX") {
            return url
        }
        if let urls = Bundle.module.urls(forResourcesWithExtension: "html", subdirectory: nil) {
            return urls.first(where: { $0.lastPathComponent == "index.html" && $0.path.contains("KaTeX") })
        }
        return nil
    }

    func render(latex: String, displayMode: Bool, fontSize: CGFloat, color: NSColor) async -> NSImage? {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let r = max(0, min(1, rgb.rgbRed))
        let g = max(0, min(1, rgb.rgbGreen))
        let b = max(0, min(1, rgb.rgbBlue))

        let key = "\(displayMode ? "D" : "I")|\(Int(fontSize.rounded()))|\(Int(r * 255))_\(Int(g * 255))_\(Int(b * 255))|\(latex)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        await ensureReady()

        let colorHex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))

        var size = await renderSize(latex: latex, displayMode: displayMode, fontSize: fontSize, colorHex: colorHex)
        if size == nil {
            loadBasePage()
            await ensureReady()
            size = await renderSize(latex: latex, displayMode: displayMode, fontSize: fontSize, colorHex: colorHex)
        }

        guard let size else { return nil }

        let rect = CGRect(x: 0, y: 0, width: min(size.width + 4, 2048), height: min(size.height + 4, 2048))

        let snapshot = await withCheckedContinuation { cont in
            let cfg = WKSnapshotConfiguration()
            cfg.rect = rect
            webView.takeSnapshot(with: cfg) { image, _ in
                cont.resume(returning: image)
            }
        }

        guard let snapshot else { return nil }
        cache.setObject(snapshot, forKey: key)
        return snapshot
    }

    private func renderSize(latex: String, displayMode: Bool, fontSize: CGFloat, colorHex: String) async -> CGSize? {
        let args: [String: Any] = [
            "tex": latex,
            "displayMode": displayMode,
            "fontSize": Double(fontSize),
            "color": colorHex
        ]

        return await withCheckedContinuation { cont in
            webView.callAsyncJavaScript(
                "return window.__renderLatex(tex, displayMode, fontSize, color);",
                arguments: args,
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    if let dict = value as? [String: Any],
                       let w = dict["width"] as? Double,
                       let h = dict["height"] as? Double {
                        cont.resume(returning: CGSize(width: max(1, w), height: max(1, h)))
                    } else {
                        cont.resume(returning: nil)
                    }
                case .failure:
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

private extension NSColor {
    var rgbRed: CGFloat {
        (usingColorSpace(.deviceRGB) ?? self).redComponent
    }

    var rgbGreen: CGFloat {
        (usingColorSpace(.deviceRGB) ?? self).greenComponent
    }

    var rgbBlue: CGFloat {
        (usingColorSpace(.deviceRGB) ?? self).blueComponent
    }
}
