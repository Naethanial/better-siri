import SwiftUI
import CoreGraphics

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
    private let openRouterClient = OpenRouterClient()
    private var streamTask: Task<Void, Never>?

    @AppStorage("openrouter_apiKey") private var apiKey: String = ""
    @AppStorage("openrouter_model") private var model: String = "anthropic/claude-sonnet-4"

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
            messages.append(ChatMessage(role: .assistant, content: "Please set your OpenRouter API key in Settings."))
            return false
        }

        // Add user message
        let userMessage = ChatMessage(role: .user, content: trimmedInput)
        messages.append(userMessage)

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

        streamTask = Task {
            do {
                let stream = await openRouterClient.streamCompletion(
                    prompt: trimmedInput,
                    screenshot: screenshot,
                    apiKey: apiKey,
                    model: model
                )

                for try await token in stream {
                    // Append token to the assistant message
                    messages[assistantIndex].content += token
                }

                isStreaming = false

            } catch {
                // Update the assistant message with error
                messages[assistantIndex].content = "Error: \(error.localizedDescription)"
                isStreaming = false
            }
        }

        return true
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }
}
