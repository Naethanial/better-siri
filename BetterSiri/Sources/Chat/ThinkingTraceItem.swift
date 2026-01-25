import Foundation

enum ThinkingTraceStatus: String, Equatable {
    case pending
    case active
    case done
    case failed
}

enum ThinkingTraceKind: String, Identifiable, Equatable {
    case processingScreen
    case searchingWeb
    case openingBrowser
    case browsing
    case startingResponse
    case modelReasoning

    var id: String { rawValue }
}

struct ThinkingTraceItem: Identifiable, Equatable {
    let id: ThinkingTraceKind
    var title: String
    var detail: String?
    var status: ThinkingTraceStatus
}
