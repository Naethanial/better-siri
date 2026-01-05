import CoreGraphics
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: MessageRole
    var content: String
    let timestamp = Date()

    enum MessageRole {
        case user
        case assistant
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var hasSentFirstMessage: Bool = false

    let screenshot: CGImage
    private var cachedScreenshotBase64: String?
    private let openRouterClient = OpenRouterClient()
    private let perplexityService = PerplexityService()
    private var streamTask: Task<Void, Never>?

    @AppStorage("openrouter_apiKey") private var apiKey: String = ""
    @AppStorage("openrouter_model") private var model: String = "google/gemini-3-flash-preview"
    @AppStorage("perplexity_apiKey") private var perplexityApiKey: String = ""

    init(screenshot: CGImage) {
        self.screenshot = screenshot
    }

    @discardableResult
    func sendMessage() -> Bool {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return false }
        guard !isStreaming else { return false }
        guard !apiKey.isEmpty else {
            // Add error message if no API key
            messages.append(
                ChatMessage(
                    role: .assistant, content: "Please set your OpenRouter API key in Settings."))
            AppLog.shared.log("Send blocked: missing API key", level: .error)
            return false
        }

        // Add user message
        let userMessage = ChatMessage(role: .user, content: trimmedInput)
        messages.append(userMessage)
        AppLog.shared.log("User message queued (chars: \(trimmedInput.count))")

        // Clear input
        inputText = ""

        // Mark that we've sent the first message (triggers width expansion)
        hasSentFirstMessage = true

        // Add empty assistant message that will be filled with streaming content
        let assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        // Start streaming
        isStreaming = true
        AppLog.shared.log("Streaming started")

        streamTask = Task {
            do {
                // Prepare base64 screenshot if not cached
                if cachedScreenshotBase64 == nil {
                    cachedScreenshotBase64 = try await openRouterClient.encodeImageToBase64(
                        screenshot)
                }

                // Fetch web search context if Perplexity API key is configured
                var webContext: String? = nil
                if !perplexityApiKey.isEmpty {
                    do {
                        webContext = try await perplexityService.searchForContext(
                            query: trimmedInput,
                            apiKey: perplexityApiKey
                        )
                    } catch {
                        AppLog.shared.log("Perplexity search failed: \(error)", level: .error)
                        // Continue without web context
                    }
                }

                // Prepare messages for API
                var apiMessages: [OpenRouterMessage] = []

                // Add system prompt for formatting, including web context if available
                var systemPrompt =
                    "Format your responses using Markdown. "
                    + "For mathematical formulas or equations, use LaTeX syntax with $ or $$ delimiters. "
                    + "Be concise and professional."

                if let webContext = webContext {
                    systemPrompt +=
                        "\n\nYou have access to the following recent web search results that may help answer the user's question. Use this information if relevant, and cite sources when appropriate:\n\n\(webContext)"
                }

                apiMessages.append(
                    OpenRouterMessage(role: "system", content: [.text(systemPrompt)]))

                for (index, msg) in messages.enumerated() {
                    // Skip the assistant's empty message we just added at the end (the one we are filling)
                    if index == messages.count - 1 && msg.role == .assistant && msg.content.isEmpty
                    {
                        continue
                    }

                    let role = msg.role == .user ? "user" : "assistant"
                    var content: [OpenRouterMessage.MessageContent] = [.text(msg.content)]

                    // Add screenshot to the first user message
                    if index == 0, let base64 = cachedScreenshotBase64 {
                        content.insert(
                            .imageUrl(.init(url: "data:image/jpeg;base64,\(base64)")), at: 0)
                    }

                    apiMessages.append(OpenRouterMessage(role: role, content: content))
                }

                let stream = await openRouterClient.streamCompletion(
                    messages: apiMessages,
                    apiKey: apiKey,
                    model: model
                )

                for try await token in stream {
                    // Append token to the assistant message
                    messages[assistantIndex].content += token
                }

                isStreaming = false
                AppLog.shared.log("Streaming completed")

            } catch {
                // Update the assistant message with error
                messages[assistantIndex].content = "Error: \(error.localizedDescription)"
                isStreaming = false
                AppLog.shared.log("Streaming failed: \(error)", level: .error)
            }
        }

        return true
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        AppLog.shared.log("Streaming cancelled")
    }
}
