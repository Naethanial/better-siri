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
    @Published var thinkingTraces: [ThinkingTraceItem] = []

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

        // Seed transient thinking UI (shown while assistant bubble is still empty)
        thinkingTraces = makeInitialThinkingTraces(shouldSearchWeb: !perplexityApiKey.isEmpty)

        // Start streaming
        isStreaming = true
        AppLog.shared.log("Streaming started")

        streamTask = Task {
            do {
                var didReceiveFirstToken = false

                // Prepare base64 screenshot if not cached
                if cachedScreenshotBase64 == nil {
                    updateTrace(.processingScreen, status: .active)
                    cachedScreenshotBase64 = try await openRouterClient.encodeImageToBase64(
                        screenshot)
                    updateTrace(.processingScreen, status: .done)
                } else {
                    updateTrace(.processingScreen, status: .done)
                }

                // Fetch web search context if Perplexity API key is configured
                var webContext: String? = nil
                if !perplexityApiKey.isEmpty {
                    do {
                        updateTrace(.searchingWeb, status: .active)
                        webContext = try await perplexityService.searchForContext(
                            query: trimmedInput,
                            apiKey: perplexityApiKey
                        )
                        updateTrace(.searchingWeb, status: .done)
                    } catch {
                        AppLog.shared.log("Perplexity search failed: \(error)", level: .error)
                        updateTrace(.searchingWeb, status: .failed, detail: "Search failed")
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

                updateTrace(.startingResponse, status: .active)

                for try await token in stream {
                    if !didReceiveFirstToken {
                        didReceiveFirstToken = true
                        thinkingTraces.removeAll()
                    }
                    // Append token to the assistant message
                    messages[assistantIndex].content += token
                }

                // If the stream produced no output, remove the placeholder message.
                if messages[assistantIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.remove(at: assistantIndex)
                }

                isStreaming = false
                thinkingTraces.removeAll()
                AppLog.shared.log("Streaming completed")

            } catch {
                // Update the assistant message with error
                messages[assistantIndex].content = "Error: \(error.localizedDescription)"
                isStreaming = false
                thinkingTraces.removeAll()
                AppLog.shared.log("Streaming failed: \(error)", level: .error)
            }
        }

        return true
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        thinkingTraces.removeAll()

        // If we never received any output, remove the empty assistant placeholder.
        if let last = messages.last,
           last.role == .assistant,
           last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.removeLast()
        }
        AppLog.shared.log("Streaming cancelled")
    }

    private func makeInitialThinkingTraces(shouldSearchWeb: Bool) -> [ThinkingTraceItem] {
        var items: [ThinkingTraceItem] = [
            ThinkingTraceItem(
                id: .processingScreen,
                title: "Processing screen",
                detail: nil,
                status: .active
            )
        ]

        if shouldSearchWeb {
            items.append(
                ThinkingTraceItem(
                    id: .searchingWeb,
                    title: "Searching web",
                    detail: nil,
                    status: .pending
                )
            )
        }

        items.append(
            ThinkingTraceItem(
                id: .startingResponse,
                title: "Starting response",
                detail: nil,
                status: .pending
            )
        )

        return items
    }

    private func updateTrace(_ id: ThinkingTraceKind, status: ThinkingTraceStatus, detail: String? = nil) {
        guard let index = thinkingTraces.firstIndex(where: { $0.id == id }) else { return }
        thinkingTraces[index].status = status
        if let detail {
            thinkingTraces[index].detail = detail
        }
    }
}
