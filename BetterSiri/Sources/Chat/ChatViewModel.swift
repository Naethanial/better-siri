import CoreGraphics
import SwiftUI

struct ChatAssistantActivity: Equatable {
    var title: String
    var log: String
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: MessageRole
    var content: String
    var assistantActivity: ChatAssistantActivity? = nil
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
    private let assistantActivityLogMaxCharacters = 12_000
    private let openRouterClient = OpenRouterClient()
    private let perplexityService = PerplexityService()
    private let browserUseService = BrowserUseService()
    private let chromeRemoteDebuggingService = ChromeRemoteDebuggingService.shared
    private var streamTask: Task<Void, Never>?

    @AppStorage("openrouter_apiKey") private var apiKey: String = ""
    @AppStorage("openrouter_model") private var model: String = "google/gemini-3-flash-preview"
    @AppStorage("perplexity_apiKey") private var perplexityApiKey: String = ""

    @AppStorage("browseruse_enabled") private var browserUseEnabled: Bool = false
    @AppStorage("browseruse_python") private var browserUsePython: String =
        "~/.bettersiri-browseruse-venv/bin/python"
    @AppStorage("browseruse_chrome_executable_path") private var browserUseChromeExecutablePath:
        String =
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    @AppStorage("browseruse_chrome_user_data_dir") private var browserUseChromeUserDataDir: String =
        "~/Library/Application Support/BetterSiri/Chrome"
    @AppStorage("browseruse_chrome_profile_directory") private var browserUseChromeProfileDirectory:
        String = "Default"
    @AppStorage("browseruse_max_steps") private var browserUseMaxSteps: Int = 50
    @AppStorage("browseruse_headless") private var browserUseHeadless: Bool = false
    @AppStorage("browseruse_use_vision") private var browserUseUseVision: Bool = true
    @AppStorage("browseruse_auto_invoke") private var browserUseAutoInvoke: Bool = true
    @AppStorage("browseruse_keep_browser_open") private var browserUseKeepBrowserOpen: Bool = true
    @AppStorage("browseruse_remote_debugging_port") private var browserUseRemoteDebuggingPort: Int =
        9222
    @AppStorage("browseruse_attach_only") private var browserUseAttachOnly: Bool = false

    init(screenshot: CGImage) {
        self.screenshot = screenshot
    }

    private func setAssistantActivity(
        at index: Int,
        title: String? = nil,
        appendLog: String? = nil
    ) {
        guard messages.indices.contains(index) else { return }
        guard messages[index].role == .assistant else { return }

        let defaultTitle = title ?? messages[index].assistantActivity?.title ?? "Thinking"
        var activity =
            messages[index].assistantActivity
            ?? ChatAssistantActivity(title: defaultTitle, log: "")

        if let title {
            activity.title = title
        }

        if let appendLog, !appendLog.isEmpty {
            activity.log += appendLog
            if activity.log.count > assistantActivityLogMaxCharacters {
                activity.log = String(activity.log.suffix(assistantActivityLogMaxCharacters))
            }
        }

        messages[index].assistantActivity = activity
    }

    private func finishAssistantMessage(at index: Int, content: String) {
        guard messages.indices.contains(index) else { return }
        guard messages[index].role == .assistant else { return }
        messages[index].assistantActivity = nil
        messages[index].content = content
    }

    private enum BrowserPlannedAction: Equatable {
        case chat
        case browserTask(String)
        case browserStart
        case browserStop
    }

    private struct BrowserRouteDecision: Decodable {
        let route: String
        let task: String?
    }

    private func parseBrowserCommand(from input: String) -> BrowserPlannedAction? {
        guard input.hasPrefix("/browser") else { return nil }

        let remainder = input.dropFirst("/browser".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if remainder.isEmpty || remainder == "start" || remainder == "open" {
            return .browserStart
        }
        if remainder == "stop" || remainder == "close" {
            return .browserStop
        }

        return .browserTask(remainder)
    }

    private func decideBrowserAction(for input: String) async throws -> BrowserPlannedAction {
        let prompt = """
            You are a routing assistant for a macOS chat app.

            Decide whether the user's message should be handled by:
            - chat: answer normally (no browser automation)
            - browser_start: start/prepare a shared Chrome window for co-navigation
            - browser_stop: stop the shared Chrome window (if the app started it)
            - browser: run a browser automation agent to perform actions in the shared Chrome window

            Use browser when the user wants you to *do something in a browser* (visit/open URLs, search, click, type, fill forms, navigate sites, download, etc).
            Use chat when the user is asking for an explanation or information that does not require interacting with a website.
            Use browser_start when the user asks to open/start Chrome or “open the browser window”.
            Use browser_stop when the user asks to close/stop the browser window.

            Respond with ONLY a single-line JSON object:
            {"route":"chat"|"browser"|"browser_start"|"browser_stop","task":"<browser task if route=browser, else empty>"}
            """

        let routerMessages: [OpenRouterMessage] = [
            OpenRouterMessage(role: "system", content: [.text(prompt)]),
            OpenRouterMessage(role: "user", content: [.text(input)]),
        ]

        let raw = try await openRouterClient.completion(
            messages: routerMessages, apiKey: apiKey, model: model)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let jsonString: String
        if trimmed.hasPrefix("{") {
            jsonString = trimmed
        } else if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            jsonString = String(trimmed[start...end])
        } else {
            return .chat
        }

        guard let data = jsonString.data(using: .utf8) else { return .chat }

        let decision: BrowserRouteDecision
        do {
            decision = try JSONDecoder().decode(BrowserRouteDecision.self, from: data)
        } catch {
            AppLog.shared.log("Browser route decode failed: \(error)", level: .error)
            return .chat
        }

        switch decision.route.lowercased() {
        case "browser_start":
            return .browserStart
        case "browser_stop":
            return .browserStop
        case "browser":
            let task = (decision.task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .browserTask(task.isEmpty ? input : task)
        default:
            return .chat
        }
    }

    @discardableResult
    func sendMessage() -> Bool {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return false }
        guard !isStreaming else { return false }

        let explicitBrowserAction = parseBrowserCommand(from: trimmedInput)

        if explicitBrowserAction != nil, !browserUseEnabled {
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: "Browser agent is disabled. Enable it in Settings → Browser Agent."
                )
            )
            return false
        }

        let requiresApiKey: Bool = {
            guard let explicitBrowserAction else { return true }
            switch explicitBrowserAction {
            case .browserStart, .browserStop:
                return false
            case .browserTask, .chat:
                return true
            }
        }()

        if requiresApiKey, apiKey.isEmpty {
            messages.append(
                ChatMessage(
                    role: .assistant, content: "Please set your OpenRouter API key in Settings."
                ))
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
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            assistantActivity: ChatAssistantActivity(title: "Thinking", log: "")
        )
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        // Start streaming
        isStreaming = true
        AppLog.shared.log("Streaming started")

        streamTask = Task {
            defer {
                isStreaming = false
            }

            var bufferedFinalContent = ""
            do {
                var plannedBrowserAction: BrowserPlannedAction = .chat

                if let explicitBrowserAction {
                    plannedBrowserAction = explicitBrowserAction
                } else if browserUseEnabled, browserUseAutoInvoke {
                    setAssistantActivity(
                        at: assistantIndex, title: "Thinking", appendLog: "Planning…\n")
                    plannedBrowserAction = try await decideBrowserAction(for: trimmedInput)
                }

                if plannedBrowserAction == .browserStart {
                    setAssistantActivity(
                        at: assistantIndex,
                        title: "Browsing",
                        appendLog: "Opening browser window…\n"
                    )

                    _ = try await chromeRemoteDebuggingService.ensureAvailable(
                        chromeExecutablePath: browserUseChromeExecutablePath,
                        chromeUserDataDir: browserUseChromeUserDataDir,
                        chromeProfileDirectory: browserUseChromeProfileDirectory,
                        remoteDebuggingPort: browserUseRemoteDebuggingPort,
                        launchIfNeeded: true
                    )

                    bufferedFinalContent = "Browser window ready."
                    finishAssistantMessage(at: assistantIndex, content: bufferedFinalContent)
                    AppLog.shared.log("Browser window started")
                    return
                }

                if plannedBrowserAction == .browserStop {
                    setAssistantActivity(
                        at: assistantIndex,
                        title: "Browsing",
                        appendLog: "Stopping browser window…\n"
                    )
                    await chromeRemoteDebuggingService.stop()
                    bufferedFinalContent = "Browser window stopped."
                    finishAssistantMessage(at: assistantIndex, content: bufferedFinalContent)
                    AppLog.shared.log("Browser window stopped")
                    return
                }

                if case .browserTask(let task) = plannedBrowserAction, !task.isEmpty {
                    setAssistantActivity(
                        at: assistantIndex,
                        title: "Browsing",
                        appendLog: "Task: \(task)\n"
                    )
                    AppLog.shared.log("Browser agent started (maxSteps: \(browserUseMaxSteps))")

                    let cdpURL = try await chromeRemoteDebuggingService.ensureAvailable(
                        chromeExecutablePath: browserUseChromeExecutablePath,
                        chromeUserDataDir: browserUseChromeUserDataDir,
                        chromeProfileDirectory: browserUseChromeProfileDirectory,
                        remoteDebuggingPort: browserUseRemoteDebuggingPort,
                        launchIfNeeded: !browserUseAttachOnly
                    )

                    setAssistantActivity(at: assistantIndex, appendLog: "Connected to Chrome.\n")

                    let stream = await browserUseService.runAgent(
                        task: task,
                        pythonCommand: browserUsePython,
                        cdpURL: cdpURL,
                        openRouterApiKey: apiKey,
                        openRouterModel: model,
                        maxSteps: browserUseMaxSteps,
                        useVision: browserUseUseVision
                    )

                    for try await chunk in stream {
                        if chunk.hasPrefix("BETTER_SIRI_FINAL_RESULT: ") {
                            let json = chunk.replacingOccurrences(
                                of: "BETTER_SIRI_FINAL_RESULT: ",
                                with: ""
                            ).trimmingCharacters(in: .whitespacesAndNewlines)
                            if let data = json.data(using: .utf8),
                                let object = try? JSONSerialization.jsonObject(with: data)
                                    as? [String: Any],
                                let final = object["final"] as? String
                            {
                                bufferedFinalContent = final
                            }
                        } else {
                            setAssistantActivity(at: assistantIndex, appendLog: chunk)
                        }
                    }

                    AppLog.shared.log("Browser agent completed")

                    if !browserUseKeepBrowserOpen {
                        await chromeRemoteDebuggingService.stop()
                        AppLog.shared.log("Browser window stopped (keep-open disabled)")
                    }

                    finishAssistantMessage(
                        at: assistantIndex,
                        content: bufferedFinalContent.isEmpty ? "Done." : bufferedFinalContent
                    )
                    return
                }

                // Prepare base64 screenshot if not cached
                if cachedScreenshotBase64 == nil {
                    cachedScreenshotBase64 = try await openRouterClient.encodeImageToBase64(
                        screenshot)
                }

                // Fetch web search context if Perplexity API key is configured
                var webContext: String? = nil
                if !perplexityApiKey.isEmpty {
                    setAssistantActivity(
                        at: assistantIndex,
                        title: "Researching",
                        appendLog: "Searching the web…\n"
                    )
                    do {
                        webContext = try await perplexityService.searchForContext(
                            query: trimmedInput,
                            apiKey: perplexityApiKey
                        )
                        if webContext != nil {
                            setAssistantActivity(
                                at: assistantIndex, appendLog: "Web context ready.\n")
                        } else {
                            setAssistantActivity(at: assistantIndex, appendLog: "No results.\n")
                        }
                    } catch {
                        AppLog.shared.log("Perplexity search failed: \(error)", level: .error)
                        setAssistantActivity(
                            at: assistantIndex,
                            appendLog: "Web search failed; continuing without it.\n"
                        )
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

                setAssistantActivity(
                    at: assistantIndex,
                    title: "Thinking",
                    appendLog: "Composing response…\n"
                )
                for try await token in stream {
                    bufferedFinalContent += token
                }

                finishAssistantMessage(at: assistantIndex, content: bufferedFinalContent)
                AppLog.shared.log("Streaming completed")

            } catch is CancellationError {
                finishAssistantMessage(
                    at: assistantIndex,
                    content: bufferedFinalContent.isEmpty ? "Cancelled." : bufferedFinalContent
                )
                AppLog.shared.log("Streaming cancelled")
                return
            } catch {
                let errorText = "Error: \(error.localizedDescription)"
                finishAssistantMessage(at: assistantIndex, content: errorText)
                AppLog.shared.log("Streaming failed: \(error)", level: .error)
            }
        }

        return true
    }

    func cancelStreaming() {
        let wasStreaming = isStreaming || streamTask != nil
        stopAllActivity()
        if wasStreaming {
            AppLog.shared.log("Streaming cancelled")
        }
    }

    func stopAllActivity() {
        streamTask?.cancel()
        streamTask = nil
        Task { await browserUseService.cancelCurrentRun() }
        isStreaming = false
    }
}
