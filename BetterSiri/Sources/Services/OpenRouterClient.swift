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
    let error: APIError?

    struct APIError: Codable {
        let message: String?
        let type: String?
        let code: String?
    }

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

    private struct HTTPFailure: Error {
        let statusCode: Int
        let message: String?
        let body: String?
    }

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

                    let maxAttempts = 3
                    var attempt = 0
                    var didYieldAnyTokens = false

                    while true {
                        do {
                            var request = URLRequest(url: baseURL)
                            request.httpMethod = "POST"
                            request.timeoutInterval = 300
                            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                            request.setValue("BetterSiri/1.0", forHTTPHeaderField: "HTTP-Referer")
                            request.setValue("Better Siri", forHTTPHeaderField: "X-Title")
                            request.httpBody = try JSONEncoder().encode(requestBody)

                            // Start the streaming request
                            let (bytes, response) = try await URLSession.shared.bytes(for: request)

                            guard let httpResponse = response as? HTTPURLResponse else {
                                throw OpenRouterError.invalidResponse
                            }

                            guard httpResponse.statusCode == 200 else {
                                let body = try? await readAll(bytes: bytes, limitBytes: 64_000)
                                let msg = body.flatMap { parseOpenRouterErrorMessage(from: $0) }
                                AppLog.shared.log("OpenRouter HTTP error: \(httpResponse.statusCode)\(msg.map { ": \($0)" } ?? "")", level: .error)
                                throw HTTPFailure(statusCode: httpResponse.statusCode, message: msg, body: body)
                            }

                            // Process the SSE stream
                    struct ToolCallBuilder {
                        var id: String?
                        var name: String?
                        var arguments: String = ""
                    }

                    var toolCallBuilders: [Int: ToolCallBuilder] = [:]

                            for try await line in bytes.lines {
                                if Task.isCancelled {
                                    break
                                }
                                if line.hasPrefix("data: ") {
                                    let jsonString = String(line.dropFirst(6))

                                    if jsonString == "[DONE]" {
                                        break
                                    }

                                    guard let data = jsonString.data(using: .utf8) else { continue }
                                    guard let streamResponse = try? JSONDecoder().decode(OpenRouterStreamResponse.self, from: data) else { continue }

                                    if let apiError = streamResponse.error {
                                        let message = apiError.message ?? "Unknown streaming error"
                                        throw OpenRouterError.apiError(message: message, type: apiError.type, code: apiError.code)
                                    }

                                    guard let choice = streamResponse.choices?.first else { continue }
                                    guard let delta = choice.delta else { continue }

                                    if let content = delta.content, !content.isEmpty {
                                        didYieldAnyTokens = true
                                        continuation.yield(.content(content))
                                    }

                                    if let reasoningText = extractReasoningText(from: delta), !reasoningText.isEmpty {
                                        didYieldAnyTokens = true
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

                                        didYieldAnyTokens = true
                                        continuation.yield(.toolCalls(calls))
                                        break
                                    }
                                }
                            }

                            continuation.finish()
                            AppLog.shared.log("OpenRouter stream finished")
                            break
                        } catch let failure as HTTPFailure {
                            attempt += 1
                            let err = OpenRouterError.httpError(statusCode: failure.statusCode, message: failure.message, body: failure.body)
                            if attempt < maxAttempts, !didYieldAnyTokens, isRetriable(err) {
                                let delay = retryDelaySeconds(forAttempt: attempt)
                                AppLog.shared.log("OpenRouter retrying after HTTP \(failure.statusCode) (attempt \(attempt + 1)/\(maxAttempts), delay \(delay)s)", level: .debug)
                                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                                continue
                            }
                            throw err
                        } catch {
                            attempt += 1
                            if attempt < maxAttempts, !didYieldAnyTokens, isRetriable(error) {
                                let delay = retryDelaySeconds(forAttempt: attempt)
                                AppLog.shared.log("OpenRouter retrying after error (attempt \(attempt + 1)/\(maxAttempts), delay \(delay)s): \(error)", level: .debug)
                                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                                continue
                            }
                            throw error
                        }
                    }

                } catch {
                    AppLog.shared.log("OpenRouter stream failed: \(error)", level: .error)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func isRetriable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
                 .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
                 .secureConnectionFailed, .cannotLoadFromNetwork:
                return true
            case .cancelled:
                return false
            default:
                return false
            }
        }

        if let err = error as? OpenRouterError {
            switch err {
            case .httpError(let statusCode, _, _):
                return [429, 500, 502, 503, 504].contains(statusCode)
            case .apiError:
                return true
            case .invalidResponse:
                return true
            case .imageEncodingFailed, .imageTooLarge:
                return false
            }
        }

        return false
    }

    private func retryDelaySeconds(forAttempt attempt: Int) -> Double {
        // attempt: 1 => ~1s, 2 => ~2s
        let base = pow(2.0, Double(max(0, attempt - 1)))
        let jitter = Double.random(in: 0.0...0.25)
        return min(8.0, base + jitter)
    }

    private func readAll(bytes: URLSession.AsyncBytes, limitBytes: Int) async throws -> String {
        var data = Data()
        data.reserveCapacity(min(4096, limitBytes))

        for try await b in bytes {
            if data.count >= limitBytes {
                break
            }
            data.append(b)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseOpenRouterErrorMessage(from body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }

        struct Envelope: Decodable {
            struct APIError: Decodable {
                let message: String?
            }
            let error: APIError?
        }

        if let env = try? JSONDecoder().decode(Envelope.self, from: data) {
            return env.error?.message
        }

        // Fallback: keep only the first line if it's not JSON.
        return trimmed.split(separator: "\n").first.map(String.init)
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
        // OpenRouter payloads can get huge when tool mode adds extra screenshots.
        // Downscale + compress aggressively to reduce flaky HTTP failures.
        let resized = downscale(image: image, maxDimension: 1280)
        let maxBytes = 2_500_000

        let qualities: [CGFloat] = [0.65, 0.5, 0.35]
        var lastData: Data? = nil

        for q in qualities {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw OpenRouterError.imageEncodingFailed
            }

            let options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: q
            ]
            CGImageDestinationAddImage(destination, resized, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw OpenRouterError.imageEncodingFailed
            }

            let data = out as Data
            lastData = data
            if data.count <= maxBytes {
                return data.base64EncodedString()
            }
        }

        if let lastData {
            throw OpenRouterError.imageTooLarge(byteCount: lastData.count)
        }
        throw OpenRouterError.imageEncodingFailed
    }

    private func downscale(image: CGImage, maxDimension: Int) -> CGImage {
        let w = image.width
        let h = image.height
        let maxSide = max(w, h)
        guard maxSide > maxDimension, maxSide > 0 else { return image }

        let scale = CGFloat(maxDimension) / CGFloat(maxSide)
        let newW = max(1, Int((CGFloat(w) * scale).rounded(.toNearestOrAwayFromZero)))
        let newH = max(1, Int((CGFloat(h) * scale).rounded(.toNearestOrAwayFromZero)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }
}

enum OpenRouterError: Error, LocalizedError, CustomNSError {
    case invalidResponse
    case httpError(statusCode: Int, message: String? = nil, body: String? = nil)
    case apiError(message: String, type: String? = nil, code: String? = nil)
    case imageEncodingFailed
    case imageTooLarge(byteCount: Int)

    static var errorDomain: String { "BetterSiri.OpenRouter" }

    var errorCode: Int {
        switch self {
        case .invalidResponse:
            return 1
        case .httpError(let statusCode, _, _):
            return statusCode
        case .apiError:
            return 2
        case .imageEncodingFailed:
            return 3
        case .imageTooLarge:
            return 4
        }
    }

    var errorUserInfo: [String: Any] {
        switch self {
        case .httpError(_, let message, let body):
            var info: [String: Any] = [:]
            if let message { info[NSLocalizedDescriptionKey] = message }
            if let body { info["body"] = body }
            return info
        case .apiError(let message, let type, let code):
            var info: [String: Any] = [NSLocalizedDescriptionKey: message]
            if let type { info["type"] = type }
            if let code { info["code"] = code }
            return info
        case .imageTooLarge(let byteCount):
            return ["byteCount": byteCount]
        default:
            return [:]
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenRouter: invalid response from server."
        case .httpError(let statusCode, let message, _):
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "OpenRouter: HTTP \(statusCode) - \(message)"
            }
            return "OpenRouter: HTTP \(statusCode)."
        case .apiError(let message, _, _):
            return "OpenRouter: \(message)"
        case .imageEncodingFailed:
            return "Failed to encode image for the model."
        case .imageTooLarge(let byteCount):
            let mb = Double(byteCount) / 1_000_000.0
            return String(format: "Image is too large to send (%.1f MB).", mb)
        }
    }
}
