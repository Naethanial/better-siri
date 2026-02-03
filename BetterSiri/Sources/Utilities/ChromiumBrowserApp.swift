import Foundation

enum ChromiumBrowserAppId: String, CaseIterable, Identifiable, Codable {
    case chrome
    case chromeBeta
    case chromium
    case brave
    case edge
    case arc
    case helium
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .chromeBeta: return "Chrome Beta"
        case .chromium: return "Chromium"
        case .brave: return "Brave"
        case .edge: return "Microsoft Edge"
        case .arc: return "Arc"
        case .helium: return "Helium"
        case .custom: return "Custom…"
        }
    }

    func resolveExecutablePath(customExecutablePath: String) -> String? {
        let trimmedCustom = customExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if self == .custom {
            return trimmedCustom.isEmpty ? nil : trimmedCustom
        }

        for candidate in executablePathCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func defaultUserDataDirURL() -> URL? {
        for candidate in userDataDirCandidates {
            let url = URL(fileURLWithPath: candidate, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Fall back to the first candidate even if it doesn't exist yet.
        guard let first = userDataDirCandidates.first else { return nil }
        return URL(fileURLWithPath: first, isDirectory: true)
    }

    private var executablePathCandidates: [String] {
        switch self {
        case .chrome:
            return ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
        case .chromeBeta:
            return ["/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta"]
        case .chromium:
            return ["/Applications/Chromium.app/Contents/MacOS/Chromium"]
        case .brave:
            return ["/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"]
        case .edge:
            return ["/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"]
        case .arc:
            return ["/Applications/Arc.app/Contents/MacOS/Arc"]
        case .helium:
            return ["/Applications/Helium.app/Contents/MacOS/Helium"]
        case .custom:
            return []
        }
    }

    private var userDataDirCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .path

        switch self {
        case .chrome:
            return ["\(appSupport)/Google/Chrome"]
        case .chromeBeta:
            return ["\(appSupport)/Google/Chrome Beta"]
        case .chromium:
            return ["\(appSupport)/Chromium"]
        case .brave:
            return ["\(appSupport)/BraveSoftware/Brave-Browser"]
        case .edge:
            return ["\(appSupport)/Microsoft Edge"]
        case .arc:
            return [
                "\(appSupport)/Arc/User Data",
                "\(appSupport)/Arc",
            ]
        case .helium:
            return ["\(appSupport)/net.imput.helium"]
        case .custom:
            return []
        }
    }
}
