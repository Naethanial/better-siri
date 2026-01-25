import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct OpenRouterMessage: Codable {
    let role: String
    let content: [MessageContent]?

    // Tool calling (OpenAI-compatible)
    let toolCalls: [OpenRouterToolCall]?
    let toolCallId: String?

    init(
        role: String,
        content: [MessageContent]?,
        toolCalls: [OpenRouterToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    enum MessageContent: Codable {
        case text(String)
        case imageUrl(ImageUrlContent)

        struct ImageUrlContent: Codable {
            let url: String
        }

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case image_url
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .imageUrl(let content):
                try container.encode("image_url", forKey: .type)
                try container.encode(content, forKey: .image_url)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)
            case "image_url":
                let content = try container.decode(ImageUrlContent.self, forKey: .image_url)
                self = .imageUrl(content)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type")
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

struct OpenRouterRequest: Codable {
    let model: String
    let messages: [OpenRouterMessage]
    let stream: Bool
    let reasoning: OpenRouterReasoning?
    let thinkingLevel: String?
    let tools: [OpenRouterTool]?
    let toolChoice: OpenRouterToolChoice?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case reasoning
        case thinkingLevel = "thinking_level"
        case tools
        case toolChoice = "tool_choice"
    }
}

enum OpenRouterToolChoice: Codable, Sendable, Equatable {
    case auto
    case none
    case function(name: String)

    enum CodingKeys: String, CodingKey {
        case type
        case function
    }

    struct FunctionChoice: Codable, Sendable, Equatable {
        let name: String
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .auto:
            var container = encoder.singleValueContainer()
            try container.encode("auto")
        case .none:
            var container = encoder.singleValueContainer()
            try container.encode("none")
        case .function(let name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("function", forKey: .type)
            try container.encode(FunctionChoice(name: name), forKey: .function)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            switch string {
            case "auto":
                self = .auto
            case "none":
                self = .none
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown tool_choice")
            }
            return
        }

        let obj = try decoder.container(keyedBy: CodingKeys.self)
        let type = try obj.decode(String.self, forKey: .type)
        if type == "function" {
            let fn = try obj.decode(FunctionChoice.self, forKey: .function)
            self = .function(name: fn.name)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: obj, debugDescription: "Unsupported tool_choice")
        }
    }
}

struct OpenRouterFunctionTool: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let parameters: JSONValue
}

enum OpenRouterTool: Codable, Sendable, Equatable {
    case urlContext
    case codeExecution
    case function(OpenRouterFunctionTool)

    private enum CodingKeys: String, CodingKey {
        case urlContext = "url_context"
        case codeExecution = "code_execution"
        case type
        case function
    }

    private struct EmptyObject: Codable, Sendable, Equatable {}

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .urlContext:
            try container.encode(EmptyObject(), forKey: .urlContext)

        case .codeExecution:
            try container.encode(EmptyObject(), forKey: .codeExecution)

        case .function(let fn):
            try container.encode("function", forKey: .type)
            try container.encode(fn, forKey: .function)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.urlContext) {
            self = .urlContext
            return
        }

        if container.contains(.codeExecution) {
            self = .codeExecution
            return
        }

        if (try? container.decode(String.self, forKey: .type)) == "function" {
            let fn = try container.decode(OpenRouterFunctionTool.self, forKey: .function)
            self = .function(fn)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: container.codingPath, debugDescription: "Unknown tool spec")
        )
    }
}

struct OpenRouterToolCall: Codable, Sendable, Equatable {
    let type: String
    let index: Int?
    let id: String
    let function: ToolFunction

    struct ToolFunction: Codable, Sendable, Equatable {
        let name: String
        let arguments: String
    }
}

struct OpenRouterReasoning: Codable {
    enum Effort: String, Codable {
        case none
        case minimal
        case low
        case medium
        case high
        case xhigh
    }

    let effort: Effort?
    let maxTokens: Int?
    let exclude: Bool?
    let enabled: Bool?

    init(effort: Effort? = nil, maxTokens: Int? = nil, exclude: Bool? = nil, enabled: Bool? = nil) {
        self.effort = effort
        self.maxTokens = maxTokens
        self.exclude = exclude
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case effort
        case maxTokens = "max_tokens"
        case exclude
        case enabled
    }
}

struct OpenRouterStreamResponse: Codable {
    let choices: [Choice]?

    struct Choice: Codable {
        let delta: Delta?
        let finish_reason: String?
    }

    struct Delta: Codable {
        let content: String?
        let reasoning: String?
        let reasoningDetails: JSONValue?
        let toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoning
            case reasoningDetails = "reasoning_details"
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Codable {
        let index: Int?
        let id: String?
        let type: String?
        let function: FunctionDelta?
    }

    struct FunctionDelta: Codable {
        let name: String?
        let arguments: String?
    }
}

enum OpenRouterStreamToken: Sendable, Equatable {
    case content(String)
    case reasoning(String)
    case toolCalls([OpenRouterToolCall])
}

actor OpenRouterClient {
    private let baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    func streamCompletion(
        messages: [OpenRouterMessage],
        apiKey: String,
        model: String,
        reasoning: OpenRouterReasoning? = nil,
        thinkingLevel: String? = nil,
        tools: [OpenRouterTool]? = nil,
        toolChoice: OpenRouterToolChoice? = nil
    ) -> AsyncThrowingStream<OpenRouterStreamToken, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    AppLog.shared.log("OpenRouter request started (model: \(model), messages: \(messages.count))")

                    let requestBody = OpenRouterRequest(
                        model: model,
                        messages: messages,
                        stream: true,
                        reasoning: reasoning,
                        thinkingLevel: thinkingLevel,
                        tools: tools,
                        toolChoice: toolChoice
                    )

                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("BetterSiri/1.0", forHTTPHeaderField: "HTTP-Referer")
                    request.setValue("Better Siri", forHTTPHeaderField: "X-Title")
                    request.httpBody = try JSONEncoder().encode(requestBody)

                    // Start the streaming request
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw OpenRouterError.invalidResponse
                    }

                    guard httpResponse.statusCode == 200 else {
                        AppLog.shared.log("OpenRouter HTTP error: \(httpResponse.statusCode)", level: .error)
                        throw OpenRouterError.httpError(httpResponse.statusCode)
                    }

                    // Process the SSE stream
                    struct ToolCallBuilder {
                        var id: String?
                        var name: String?
                        var arguments: String = ""
                    }

                    var toolCallBuilders: [Int: ToolCallBuilder] = [:]

                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

                            if jsonString == "[DONE]" {
                                break
                            }

                            guard let data = jsonString.data(using: .utf8) else { continue }
                            guard let streamResponse = try? JSONDecoder().decode(OpenRouterStreamResponse.self, from: data) else { continue }
                            guard let choice = streamResponse.choices?.first else { continue }
                            guard let delta = choice.delta else { continue }

                            if let content = delta.content, !content.isEmpty {
                                continuation.yield(.content(content))
                            }

                            if let reasoningText = extractReasoningText(from: delta), !reasoningText.isEmpty {
                                continuation.yield(.reasoning(reasoningText))
                            }

                            if let toolCallDeltas = delta.toolCalls {
                                for callDelta in toolCallDeltas {
                                    let idx = callDelta.index ?? 0
                                    var builder = toolCallBuilders[idx] ?? ToolCallBuilder()
                                    if let id = callDelta.id {
                                        builder.id = id
                                    }
                                    if let name = callDelta.function?.name {
                                        builder.name = name
                                    }
                                    if let args = callDelta.function?.arguments {
                                        builder.arguments += args
                                    }
                                    toolCallBuilders[idx] = builder
                                }
                            }

                            if choice.finish_reason == "tool_calls" {
                                let calls: [OpenRouterToolCall] = toolCallBuilders
                                    .sorted(by: { $0.key < $1.key })
                                    .compactMap { _, builder in
                                        guard let id = builder.id, let name = builder.name else { return nil }
                                        return OpenRouterToolCall(
                                            type: "function",
                                            index: nil,
                                            id: id,
                                            function: .init(name: name, arguments: builder.arguments)
                                        )
                                    }

                                continuation.yield(.toolCalls(calls))
                                break
                            }
                        }
                    }

                    continuation.finish()
                    AppLog.shared.log("OpenRouter stream finished")

                } catch {
                    AppLog.shared.log("OpenRouter stream failed: \(error)", level: .error)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func extractReasoningText(from delta: OpenRouterStreamResponse.Delta) -> String? {
        if let reasoning = delta.reasoning {
            return reasoning
        }

        guard let details = delta.reasoningDetails else { return nil }
        return flattenReasoningDetails(details)
    }

    private func flattenReasoningDetails(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s):
            return s
        case .array(let array):
            // reasoning_details is typically an array of objects like:
            // { "type": "reasoning.text", "text": "..." }
            let parts = array.compactMap { flattenReasoningDetails($0) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined()
        case .object(let obj):
            // Prefer structured reasoning blocks; avoid dumping encrypted payloads.
            if let type = obj["type"]?.stringValue {
                switch type {
                case "reasoning.text":
                    return obj["text"]?.stringValue
                case "reasoning.summary":
                    return obj["summary"]?.stringValue
                case "reasoning.encrypted":
                    return nil
                default:
                    break
                }
            }

            // Fallbacks for other provider shapes.
            if let text = obj["text"]?.stringValue { return text }
            if let summary = obj["summary"]?.stringValue { return summary }

            return nil
        case .number, .bool, .null:
            return nil
        }
    }

    func encodeImageToBase64(_ image: CGImage) throws -> String {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw OpenRouterError.imageEncodingFailed
        }

        // Compress the image to reduce size
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.7
        ]

        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw OpenRouterError.imageEncodingFailed
        }

        return (data as Data).base64EncodedString()
    }
}

enum OpenRouterError: Error {
    case invalidResponse
    case httpError(Int)
    case imageEncodingFailed
}
