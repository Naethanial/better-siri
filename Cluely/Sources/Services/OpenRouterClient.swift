import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct OpenRouterMessage: Codable {
    let role: String
    let content: [MessageContent]

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
}

struct OpenRouterRequest: Codable {
    let model: String
    let messages: [OpenRouterMessage]
    let stream: Bool
}

struct OpenRouterStreamResponse: Codable {
    let choices: [Choice]?

    struct Choice: Codable {
        let delta: Delta?
        let finish_reason: String?
    }

    struct Delta: Codable {
        let content: String?
    }
}

actor OpenRouterClient {
    private let baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    func streamCompletion(
        prompt: String,
        screenshot: CGImage,
        apiKey: String,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    AppLog.shared.log("OpenRouter request started (model: \(model), prompt chars: \(prompt.count))")
                    // Convert screenshot to base64
                    let base64Image = try encodeImageToBase64(screenshot)

                    // Build the request
                    let messages: [OpenRouterMessage] = [
                        OpenRouterMessage(
                            role: "user",
                            content: [
                                .imageUrl(.init(url: "data:image/jpeg;base64,\(base64Image)")),
                                .text(prompt)
                            ]
                        )
                    ]

                    let requestBody = OpenRouterRequest(
                        model: model,
                        messages: messages,
                        stream: true
                    )

                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Cluely/1.0", forHTTPHeaderField: "HTTP-Referer")
                    request.setValue("Cluely", forHTTPHeaderField: "X-Title")
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
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

                            if jsonString == "[DONE]" {
                                break
                            }

                            if let data = jsonString.data(using: .utf8),
                               let streamResponse = try? JSONDecoder().decode(OpenRouterStreamResponse.self, from: data),
                               let content = streamResponse.choices?.first?.delta?.content {
                                continuation.yield(content)
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

    private func encodeImageToBase64(_ image: CGImage) throws -> String {
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
