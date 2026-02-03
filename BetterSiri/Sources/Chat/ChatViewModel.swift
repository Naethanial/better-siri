import CoreGraphics
import SwiftUI

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date

    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    enum MessageRole: String, Codable {
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
    @Published var isBrowserModeEnabled: Bool = false
    @Published var isBrowserPaused: Bool = false
    @Published var browserActivityItems: [BrowserActivityItem] = []
    @Published var browserLatestScreenshotURL: URL?

    enum ActiveOperation: Equatable {
        case chat
        case browser
    }

    @Published private(set) var activeOperation: ActiveOperation? = nil

    let screenshot: CGImage
    private let openRouterClient = OpenRouterClient()
    private let perplexityService = PerplexityService()
    private var streamTask: Task<Void, Never>?

    private var pendingAssistantAppend: String = ""
    private var pendingAssistantMessageId: UUID?
    private var pendingFlushTask: Task<Void, Never>?

    @AppStorage("openrouter_apiKey") private var apiKey: String = ""
    @AppStorage("perplexity_apiKey") private var perplexityApiKey: String = ""
    @AppStorage("browser_use_apiKey") private var browserUseApiKey: String = ""
    @AppStorage("browser_agent_keepSession") private var browserAgentKeepSession: Bool = true
    @AppStorage("browser_agent_browserAppId") private var browserAgentBrowserAppId: String = ChromiumBrowserAppId.chrome.rawValue
    @AppStorage("browser_agent_customExecutablePath") private var browserAgentCustomExecutablePath: String = ""
    @AppStorage("browser_agent_profileRootMode") private var browserAgentProfileRootMode: String = "real"
    @AppStorage("browser_agent_customUserDataDir") private var browserAgentCustomUserDataDir: String = ""
    @AppStorage("browser_agent_profileDirectory") private var browserAgentProfileDirectory: String = "Default"
    @AppStorage("browser_agent_autoOpenDevTools") private var browserAgentAutoOpenDevTools: Bool = true
    @AppStorage("browser_agent_includeTabContext") private var browserAgentIncludeTabContext: Bool = false
    @AppStorage("browser_agent_includeActiveTabText") private var browserAgentIncludeActiveTabText: Bool = false
    @AppStorage("browser_use_cloud_model") private var browserUseCloudModel: String = "bu-2-0"
    @AppStorage("gemini_enableUrlContext") private var geminiEnableUrlContext: Bool = true
    @AppStorage("gemini_enableCodeExecution") private var geminiEnableCodeExecution: Bool = true

    private let model = "google/gemini-3-flash-preview"

    private let chatSessionId: UUID

    init(screenshot: CGImage, chatSessionId: UUID) {
        self.screenshot = screenshot
        self.chatSessionId = chatSessionId
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
        let userMessageId = userMessage.id
        messages.append(userMessage)
        AppLog.shared.log("User message queued (chars: \(trimmedInput.count))")

        // Clear input
        inputText = ""

        // Mark that we've sent the first message (triggers width expansion)
        hasSentFirstMessage = true

        // Add empty assistant message that will be filled with streaming content
        let assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantMessageId = assistantMessage.id

        // Seed transient thinking UI (shown while assistant bubble is still empty)
        let shouldUseBrowser = isBrowserModeEnabled
        if shouldUseBrowser {
            browserActivityItems.removeAll()
            browserLatestScreenshotURL = nil
        }
        thinkingTraces = makeInitialThinkingTraces(
            shouldSearchWeb: !perplexityApiKey.isEmpty,
            shouldUseBrowser: shouldUseBrowser
        )

        activeOperation = shouldUseBrowser ? .browser : .chat

        // Start processing
        isStreaming = true
        AppLog.shared.log("Streaming started")

        streamTask = Task {
            do {
                var didReceiveFirstToken = false

                updateTrace(.processingScreen, status: .active)
                let screenshotBase64 = try await openRouterClient.encodeImageToBase64(screenshot)
                updateTrace(.processingScreen, status: .done)

                // Fetch web search context if Perplexity API key is configured
                // Web search is now a tool the model can request (Perplexity).

                // Run browser agent (optional)
                var browserContext: String? = nil
                if shouldUseBrowser {
                    do {
                        updateTrace(.openingBrowser, status: .active)
                        let cfg = try resolveBrowserAgentLaunchConfig()
                        updateTrace(.browsing, status: .active, detail: "Starting")
                        browserContext = try await BrowserUseWorker.shared.runTask(
                            browserUseApiKey: browserUseApiKey,
                            userDataDir: cfg.userDataDir,
                            keepSession: cfg.keepSession,
                            chromeExecutablePath: cfg.chromeExecutablePath,
                            profileDirectory: cfg.profileDirectory,
                            chromeArgs: cfg.chromeArgs,
                            browserUseModel: cfg.browserUseModel,
                            task: trimmedInput,
                            onEvent: { [weak self] event in
                                Task { @MainActor in
                                    guard let self else { return }

                                    if event.event == "started" {
                                        self.updateTrace(.openingBrowser, status: .done)
                                    }

                                    if let detail = event.detail {
                                        self.updateTrace(.browsing, status: .active, detail: detail)
                                    }

                                    let item = BrowserActivityItem(
                                        kind: event.event,
                                        step: event.step,
                                        summary: event.detail ?? event.event,
                                        memory: event.memory,
                                        url: event.url,
                                        title: event.title,
                                        screenshotPath: event.screenshotPath,
                                        screenshotThumbPath: event.screenshotThumbPath
                                    )
                                    self.browserActivityItems.append(item)
                                    if self.browserActivityItems.count > 80 {
                                        self.browserActivityItems.removeFirst(self.browserActivityItems.count - 80)
                                    }

                                    if event.event == "screenshot" {
                                        if let thumb = event.screenshotThumbPath {
                                            self.browserLatestScreenshotURL = URL(fileURLWithPath: thumb)
                                        } else if let path = event.screenshotPath {
                                            self.browserLatestScreenshotURL = URL(fileURLWithPath: path)
                                        }
                                    }
                                }
                            }
                        )
                        updateTrace(.openingBrowser, status: .done)
                        updateTrace(.browsing, status: .done)
                    } catch {
                        AppLog.shared.log("Browser task failed: \(error)", level: .error)
                        let detail = error.localizedDescription
                        updateTrace(.openingBrowser, status: .failed, detail: detail)
                        updateTrace(.browsing, status: .failed, detail: detail)
                        // Continue without browser context
                    }
                }

                // Read-only browser tab context (Assistant Browser), even when automation is off.
                var tabContext: BrowserTabContext? = nil
                if browserAgentIncludeTabContext {
                    do {
                        let cfg = try resolveBrowserAgentLaunchConfig()
                        tabContext = try await BrowserUseWorker.shared.getTabContext(
                            browserUseApiKey: browserUseApiKey,
                            userDataDir: cfg.userDataDir,
                            keepSession: cfg.keepSession,
                            chromeExecutablePath: cfg.chromeExecutablePath,
                            profileDirectory: cfg.profileDirectory,
                            chromeArgs: cfg.chromeArgs,
                            includeActiveText: browserAgentIncludeActiveTabText,
                            maxChars: 1800
                        )
                    } catch {
                        AppLog.shared.log("Failed to read browser tab context: \(error)", level: .error)
                    }
                }

                // Prepare messages for API
                var apiMessages: [OpenRouterMessage] = []

                // Add system prompt for formatting, including web context if available
                var systemPrompt =
                    "Format your responses using Markdown. Be concise and professional."

                if geminiEnableUrlContext || geminiEnableCodeExecution {
                    systemPrompt += "\n\nAvailable tools:\n"
                    if geminiEnableUrlContext {
                        systemPrompt += "- url_context: Fetch and read the content of URLs mentioned in the conversation when needed. Cite the URL(s) you used.\n"
                    }
                    if geminiEnableCodeExecution {
                        systemPrompt += "- code_execution: Run code to verify calculations or logic when helpful.\n"
                    }
                }

                if !perplexityApiKey.isEmpty {
                    systemPrompt += "\n\nIf you need up-to-date web information, call the perplexity_search tool. Use URLs from the tool output as citations."
                }

                if let browserContext = browserContext {
                    systemPrompt +=
                        "\n\nYou also have the following browser automation transcript/output. Use it as factual context for what happened in the browser. If it includes URLs or page titles, you can cite them.\n\n\(browserContext)"
                }

                if let tabContext {
                    systemPrompt += "\n\nBrowser Tabs Context (Assistant Browser):\n"
                    if let active = tabContext.activeIndex {
                        systemPrompt += "- Active tab index: \(active)\n"
                    }
                    if !tabContext.tabs.isEmpty {
                        systemPrompt += "- Tabs:\n"
                        for tab in tabContext.tabs.prefix(24) {
                            let title = (tab.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            let url = (tab.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if !title.isEmpty && !url.isEmpty {
                                systemPrompt += "  [\(tab.index)] \(title) — \(url)\n"
                            } else if !title.isEmpty {
                                systemPrompt += "  [\(tab.index)] \(title)\n"
                            } else if !url.isEmpty {
                                systemPrompt += "  [\(tab.index)] \(url)\n"
                            } else {
                                systemPrompt += "  [\(tab.index)] (untitled)\n"
                            }
                        }
                        if tabContext.tabs.count > 24 {
                            systemPrompt += "  …and \(tabContext.tabs.count - 24) more\n"
                        }
                    }
                    if let excerpt = tabContext.activeTextExcerpt,
                       !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        systemPrompt += "\nActive tab text excerpt:\n\(excerpt)\n"
                    }
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

                    // Add screenshot to the user message being sent.
                    if msg.id == userMessageId {
                        content.insert(
                            .imageUrl(.init(url: "data:image/jpeg;base64,\(screenshotBase64)")), at: 0)
                    }

                    apiMessages.append(OpenRouterMessage(role: role, content: content))
                }

                var enabledTools: [OpenRouterTool] = []
                if geminiEnableUrlContext {
                    enabledTools.append(.urlContext)
                }
                if geminiEnableCodeExecution {
                    enabledTools.append(.codeExecution)
                }

                if !perplexityApiKey.isEmpty {
                    enabledTools.append(.function(perplexitySearchToolSpec()))
                }
                if browserAgentIncludeTabContext {
                    enabledTools.append(.function(browserListTabsToolSpec()))
                    enabledTools.append(.function(browserReadTabToolSpec()))
                }

                updateTrace(.startingResponse, status: .active)

                let maxToolIterations = 3
                var iteration = 0
                var didReceiveAnyReasoning = false

                while iteration < maxToolIterations {
                    var requestedToolCalls: [OpenRouterToolCall]? = nil

                    flushPendingAssistantDelta()

                    guard let assistantIdx = messages.firstIndex(where: { $0.id == assistantMessageId }) else {
                        break
                    }
                    let assistantStartCount = messages[assistantIdx].content.count

                    let stream = await openRouterClient.streamCompletion(
                        messages: apiMessages,
                        apiKey: apiKey,
                        model: model,
                        // OpenRouter only allows one of `reasoning.effort` or `reasoning.max_tokens`.
                        reasoning: OpenRouterReasoning(maxTokens: 2000, enabled: true),
                        thinkingLevel: "low",
                        tools: enabledTools.isEmpty ? nil : enabledTools
                    )

                    for try await token in stream {
                        if Task.isCancelled {
                            break
                        }

                        switch token {
                        case .content(let text):
                            if !didReceiveFirstToken {
                                didReceiveFirstToken = true
                                updateTrace(.startingResponse, status: .done)
                            }

                            queueAssistantDelta(text, messageId: assistantMessageId)

                        case .reasoning(let text):
                            didReceiveAnyReasoning = true
                            appendModelReasoning(text)

                        case .toolCalls(let calls):
                            requestedToolCalls = calls
                        }
                    }

                    flushPendingAssistantDelta()

                    // If we got tool calls, execute them and continue the loop.
                    if let calls = requestedToolCalls, !calls.isEmpty {
                        // Roll back any streamed content from the tool-call request.
                        if let idx = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                            messages[idx].content = String(messages[idx].content.prefix(assistantStartCount))
                        }

                        apiMessages.append(OpenRouterMessage(role: "assistant", content: nil, toolCalls: calls))

                        for call in calls {
                            let toolResult = await executeToolCall(call, userQuery: trimmedInput)
                            apiMessages.append(
                                OpenRouterMessage(
                                    role: "tool",
                                    content: [.text(toolResult)],
                                    toolCallId: call.id
                                )
                            )
                        }

                        iteration += 1
                        continue
                    }

                    break
                }

                // If the web search tool was available but never used, mark it as such.
                if !perplexityApiKey.isEmpty {
                    if let idx = thinkingTraces.firstIndex(where: { $0.id == .searchingWeb }),
                       thinkingTraces[idx].status == .pending {
                        updateTrace(.searchingWeb, status: .done, detail: "Not used")
                    }
                }

                if didReceiveAnyReasoning {
                    updateTrace(.modelReasoning, status: .done)
                } else {
                    updateTrace(
                        .modelReasoning,
                        status: .done,
                        detail: "No reasoning tokens returned by model/provider"
                    )
                }

                // If the stream produced no output, remove the placeholder message.
                flushPendingAssistantDelta()
                if let idx = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    if messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        messages.remove(at: idx)
                    }
                }

                isStreaming = false
                thinkingTraces.removeAll()
                activeOperation = nil
                isBrowserPaused = false
                AppLog.shared.log("Streaming completed")

            } catch {
                let urlError = error as? URLError
                if Task.isCancelled || error is CancellationError || urlError?.code == .cancelled {
                    // User-initiated cancel; do not show an error.
                    isStreaming = false
                    thinkingTraces.removeAll()
                    activeOperation = nil
                    isBrowserPaused = false
                    AppLog.shared.log("Streaming cancelled")
                    return
                }

                // Update the assistant message with error
                flushPendingAssistantDelta()
                if let idx = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    messages[idx].content = "Error: \(error.localizedDescription)"
                } else {
                    messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
                }
                isStreaming = false
                thinkingTraces.removeAll()
                activeOperation = nil
                isBrowserPaused = false
                AppLog.shared.log("Streaming failed: \(error)", level: .error)
            }
        }

        return true
    }

    private func queueAssistantDelta(_ text: String, messageId: UUID) {
        guard !text.isEmpty else { return }
        pendingAssistantMessageId = messageId
        pendingAssistantAppend += text

        if pendingFlushTask != nil {
            return
        }

        pendingFlushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            flushPendingAssistantDelta()
        }
    }

    private func flushPendingAssistantDelta() {
        pendingFlushTask = nil

        guard !pendingAssistantAppend.isEmpty else { return }
        guard let messageId = pendingAssistantMessageId,
              let idx = messages.firstIndex(where: { $0.id == messageId }) else {
            pendingAssistantAppend = ""
            pendingAssistantMessageId = nil
            return
        }

        messages[idx].content += pendingAssistantAppend
        pendingAssistantAppend = ""
        pendingAssistantMessageId = nil
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil

        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        pendingAssistantAppend = ""
        pendingAssistantMessageId = nil

        if activeOperation == .browser {
            Task {
                try? await BrowserUseWorker.shared.stop()
            }
        }

        isStreaming = false
        thinkingTraces.removeAll()
        activeOperation = nil
        isBrowserPaused = false

        // If we never received any output, remove the empty assistant placeholder.
        if let last = messages.last,
           last.role == .assistant,
           last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.removeLast()
        }
        AppLog.shared.log("Streaming cancelled")
    }

    private func makeInitialThinkingTraces(shouldSearchWeb: Bool, shouldUseBrowser: Bool) -> [ThinkingTraceItem] {
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
                    title: "Web search (tool)",
                    detail: nil,
                    status: .pending
                )
            )
        }

        if shouldUseBrowser {
            items.append(
                ThinkingTraceItem(
                    id: .openingBrowser,
                    title: "Opening browser",
                    detail: nil,
                    status: .pending
                )
            )

            items.append(
                ThinkingTraceItem(
                    id: .browsing,
                    title: "Browsing",
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

        items.append(
            ThinkingTraceItem(
                id: .modelReasoning,
                title: "Model reasoning",
                detail: nil,
                status: .pending
            )
        )

        return items
    }

    private func appendModelReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        guard let index = thinkingTraces.firstIndex(where: { $0.id == .modelReasoning }) else { return }

        if thinkingTraces[index].status == .pending {
            thinkingTraces[index].status = .active
        }

        let existing = thinkingTraces[index].detail ?? ""
        var next = existing + text

        // Keep the UI responsive by trimming very large streams.
        let maxChars = 6000
        if next.count > maxChars {
            next = String(next.suffix(maxChars))
        }

        thinkingTraces[index].detail = next
    }

    private func perplexitySearchToolSpec() -> OpenRouterFunctionTool {
        // OpenAI-function-style tool spec for OpenRouter tool calling.
        OpenRouterFunctionTool(
            name: "perplexity_search",
            description: "Search the web for up-to-date information and return top results with snippets and URLs.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The search query")
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of results (optional)")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        )
    }

    private struct PerplexitySearchArgs: Decodable {
        let query: String
        let max_results: Int?
    }

    private func browserListTabsToolSpec() -> OpenRouterFunctionTool {
        OpenRouterFunctionTool(
            name: "browser_list_tabs",
            description: "List open tabs in the Assistant Browser (titles + URLs).",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "include_active_text": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether to include an excerpt of the active tab text")
                    ])
                ])
            ])
        )
    }

    private func browserReadTabToolSpec() -> OpenRouterFunctionTool {
        OpenRouterFunctionTool(
            name: "browser_read_tab",
            description: "Read visible text from a specific tab index in the Assistant Browser.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "index": .object([
                        "type": .string("integer"),
                        "description": .string("Tab index to read")
                    ]),
                    "max_chars": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum characters to return (optional)")
                    ])
                ]),
                "required": .array([.string("index")])
            ])
        )
    }

    private struct BrowserListTabsArgs: Decodable {
        let include_active_text: Bool?
    }

    private struct BrowserReadTabArgs: Decodable {
        let index: Int
        let max_chars: Int?
    }

    private struct ToolResultPayload: Codable {
        let ok: Bool
        let tool: String
        let query: String?
        let result: String?
        let error: String?
    }

    private func executeToolCall(_ call: OpenRouterToolCall, userQuery: String) async -> String {
        switch call.function.name {
        case "perplexity_search":
            do {
                let argsData = Data(call.function.arguments.utf8)
                let args = (try? JSONDecoder().decode(PerplexitySearchArgs.self, from: argsData))
                    ?? PerplexitySearchArgs(query: userQuery, max_results: nil)

                updateTrace(.searchingWeb, status: .active, detail: args.query)

                let context = try await perplexityService.searchForContext(query: args.query, apiKey: perplexityApiKey)
                updateTrace(.searchingWeb, status: .done)

                let payload = ToolResultPayload(
                    ok: true,
                    tool: "perplexity_search",
                    query: args.query,
                    result: context,
                    error: nil
                )

                let data = try JSONEncoder().encode(payload)
                return String(data: data, encoding: .utf8) ?? (context ?? "")

            } catch {
                AppLog.shared.log("Perplexity tool failed: \(error)", level: .error)
                updateTrace(.searchingWeb, status: .failed, detail: "Search failed")

                let payload = ToolResultPayload(
                    ok: false,
                    tool: "perplexity_search",
                    query: nil,
                    result: nil,
                    error: error.localizedDescription
                )

                if let data = try? JSONEncoder().encode(payload) {
                    return String(data: data, encoding: .utf8) ?? payload.error ?? "Search failed"
                }
                return "{\"ok\":false,\"tool\":\"perplexity_search\",\"error\":\"Search failed\"}"
            }

        case "browser_list_tabs":
            do {
                let argsData = Data(call.function.arguments.utf8)
                let args = (try? JSONDecoder().decode(BrowserListTabsArgs.self, from: argsData))
                let includeText = args?.include_active_text ?? browserAgentIncludeActiveTabText

                let cfg = try resolveBrowserAgentLaunchConfig()
                let context = try await BrowserUseWorker.shared.getTabContext(
                    browserUseApiKey: browserUseApiKey,
                    userDataDir: cfg.userDataDir,
                    keepSession: cfg.keepSession,
                    chromeExecutablePath: cfg.chromeExecutablePath,
                    profileDirectory: cfg.profileDirectory,
                    chromeArgs: cfg.chromeArgs,
                    includeActiveText: includeText,
                    maxChars: 1800
                )

                let tabsSummary = context.tabs
                    .sorted(by: { $0.index < $1.index })
                    .map { tab -> String in
                        let title = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let url = tab.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !title.isEmpty && !url.isEmpty { return "[\(tab.index)] \(title) — \(url)" }
                        if !title.isEmpty { return "[\(tab.index)] \(title)" }
                        if !url.isEmpty { return "[\(tab.index)] \(url)" }
                        return "[\(tab.index)] (untitled)"
                    }
                    .joined(separator: "\n")

                var result = "Open tabs:\n\(tabsSummary)"
                if includeText, let excerpt = context.activeTextExcerpt, !excerpt.isEmpty {
                    result += "\n\nActive tab text excerpt:\n\(excerpt)"
                }

                let payload = ToolResultPayload(
                    ok: true,
                    tool: "browser_list_tabs",
                    query: nil,
                    result: result,
                    error: nil
                )
                let data = try JSONEncoder().encode(payload)
                return String(data: data, encoding: .utf8) ?? result

            } catch {
                AppLog.shared.log("Browser tool failed: \(error)", level: .error)
                let payload = ToolResultPayload(
                    ok: false,
                    tool: "browser_list_tabs",
                    query: nil,
                    result: nil,
                    error: error.localizedDescription
                )
                if let data = try? JSONEncoder().encode(payload) {
                    return String(data: data, encoding: .utf8) ?? payload.error ?? "Browser tool failed"
                }
                return "{\"ok\":false,\"tool\":\"browser_list_tabs\",\"error\":\"Browser tool failed\"}"
            }

        case "browser_read_tab":
            do {
                let argsData = Data(call.function.arguments.utf8)
                let args = try JSONDecoder().decode(BrowserReadTabArgs.self, from: argsData)
                let maxChars = min(max(args.max_chars ?? 4000, 200), 16000)

                // Ensure the assistant browser is open with the selected profile.
                let cfg = try resolveBrowserAgentLaunchConfig()
                try await BrowserUseWorker.shared.openBrowser(
                    browserUseApiKey: browserUseApiKey,
                    userDataDir: cfg.userDataDir,
                    keepSession: cfg.keepSession,
                    chromeExecutablePath: cfg.chromeExecutablePath,
                    profileDirectory: cfg.profileDirectory,
                    chromeArgs: cfg.chromeArgs
                )

                let text = try await BrowserUseWorker.shared.readTabText(index: args.index, maxChars: maxChars)
                let payload = ToolResultPayload(
                    ok: true,
                    tool: "browser_read_tab",
                    query: nil,
                    result: text,
                    error: nil
                )
                let data = try JSONEncoder().encode(payload)
                return String(data: data, encoding: .utf8) ?? text

            } catch {
                AppLog.shared.log("Browser tool failed: \(error)", level: .error)
                let payload = ToolResultPayload(
                    ok: false,
                    tool: "browser_read_tab",
                    query: nil,
                    result: nil,
                    error: error.localizedDescription
                )
                if let data = try? JSONEncoder().encode(payload) {
                    return String(data: data, encoding: .utf8) ?? payload.error ?? "Browser tool failed"
                }
                return "{\"ok\":false,\"tool\":\"browser_read_tab\",\"error\":\"Browser tool failed\"}"
            }

        default:
            let payload = ToolResultPayload(
                ok: false,
                tool: call.function.name,
                query: nil,
                result: nil,
                error: "Unknown tool"
            )
            if let data = try? JSONEncoder().encode(payload) {
                return String(data: data, encoding: .utf8) ?? "Unknown tool"
            }
            return "{\"ok\":false,\"tool\":\"\(call.function.name)\",\"error\":\"Unknown tool\"}"
        }
    }

    private func updateTrace(_ id: ThinkingTraceKind, status: ThinkingTraceStatus, detail: String? = nil) {
        guard let index = thinkingTraces.firstIndex(where: { $0.id == id }) else { return }
        thinkingTraces[index].status = status
        if let detail {
            thinkingTraces[index].detail = detail
        }
    }

    private func ensureBrowserUserDataDirectory() throws -> URL {
        let fileManager = FileManager.default
        let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        let userDataRoot = baseDir
            .appendingPathComponent("BetterSiri", isDirectory: true)
            .appendingPathComponent("BrowserAgentUserData", isDirectory: true)

        if browserAgentKeepSession {
            try fileManager.createDirectory(at: userDataRoot, withIntermediateDirectories: true)
            return userDataRoot
        }

        let sessionDir = userDataRoot
            .appendingPathComponent(chatSessionId.uuidString, isDirectory: true)

        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        return sessionDir
    }

    private struct BrowserAgentLaunchConfig {
        let userDataDir: URL
        let keepSession: Bool
        let chromeExecutablePath: String?
        let profileDirectory: String?
        let chromeArgs: [String]
        let browserUseModel: String
    }

    private func resolveBrowserAgentLaunchConfig() throws -> BrowserAgentLaunchConfig {
        let appId = ChromiumBrowserAppId(rawValue: browserAgentBrowserAppId) ?? .chrome

        let profileRootMode = browserAgentProfileRootMode.trimmingCharacters(in: .whitespacesAndNewlines)
        let userDataDir: URL = try {
            switch profileRootMode {
            case "custom":
                let trimmed = browserAgentCustomUserDataDir.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    throw NSError(
                        domain: "BetterSiri",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Custom user-data-dir is empty"]
                    )
                }
                return URL(fileURLWithPath: trimmed, isDirectory: true)

            case "real":
                return appId.defaultUserDataDirURL() ?? FileManager.default.temporaryDirectory
            default:
                // app_managed
                return (try? ensureBrowserUserDataDirectory()) ?? FileManager.default.temporaryDirectory
            }
        }()

        let keepSession: Bool = {
            switch profileRootMode {
            case "app_managed":
                return browserAgentKeepSession
            default:
                // Real/custom profile roots must keep the same user-data-dir for persistence.
                return true
            }
        }()

        let executablePath = appId.resolveExecutablePath(customExecutablePath: browserAgentCustomExecutablePath)
        let profileDir = browserAgentProfileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileDirectory = profileDir.isEmpty ? "Default" : profileDir

        var chromeArgs: [String] = []
        if browserAgentAutoOpenDevTools {
            chromeArgs.append("--auto-open-devtools-for-tabs")
        }

        let model = browserUseCloudModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let browserUseModel = model.isEmpty ? "bu-2-0" : model

        return BrowserAgentLaunchConfig(
            userDataDir: userDataDir,
            keepSession: keepSession,
            chromeExecutablePath: executablePath,
            profileDirectory: profileDirectory,
            chromeArgs: chromeArgs,
            browserUseModel: browserUseModel
        )
    }

    func pauseBrowser() {
        guard activeOperation == .browser else { return }
        guard isStreaming else { return }
        guard !isBrowserPaused else { return }

        isBrowserPaused = true
        updateTrace(.browsing, status: .active, detail: "Paused")
        Task {
            try? await BrowserUseWorker.shared.pause()
        }
    }

    func resumeBrowser() {
        guard activeOperation == .browser else { return }
        guard isStreaming else { return }
        guard isBrowserPaused else { return }

        isBrowserPaused = false
        updateTrace(.browsing, status: .active, detail: "Resuming")
        Task {
            try? await BrowserUseWorker.shared.resume()
        }
    }
}
