import Foundation

enum OpenRouterReasoningEffort: String, CaseIterable, Identifiable {
    case `default` = "default"
    case none = "none"
    case minimal = "minimal"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case xhigh = "xhigh"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: return "Default"
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-High"
        }
    }

    var openRouterEffort: String? {
        switch self {
        case .default: return nil
        case .none, .minimal, .low, .medium, .high, .xhigh: return rawValue
        }
    }
}
