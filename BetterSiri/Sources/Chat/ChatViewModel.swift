import CoreGraphics
import SwiftUI
import AppKit
import PDFKit
import QuickLookThumbnailing

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: MessageRole
    var content: String
    var attachments: [ChatAttachment]
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        attachments: [ChatAttachment] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.timestamp = timestamp
    }

    enum MessageRole: String, Codable {
        case user
        case assistant
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case attachments
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(MessageRole.self, forKey: .role)
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        attachments = (try? c.decode([ChatAttachment].self, forKey: .attachments)) ?? []
        timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if !attachments.isEmpty {
            try c.encode(attachments, forKey: .attachments)
        }
        try c.encode(timestamp, forKey: .timestamp)
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var pendingAttachments: [ChatAttachment] = []
    @Published var isStreaming: Bool = false
    @Published var hasSentFirstMessage: Bool = false
    @Published var thinkingTraces: [ThinkingTraceItem] = []
    @Published var isBrowserModeEnabled: Bool = false
    @Published var isOnShapeModeEnabled: Bool = false
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

    @AppStorage("onshape_enabled") private var onshapeEnabled: Bool = true
    @AppStorage("onshape_apiKey") private var onshapeApiKey: String = ""
    @AppStorage("onshape_secretKey") private var onshapeSecretKey: String = ""
    @AppStorage("onshape_baseUrl") private var onshapeBaseUrl: String = "https://cad.onshape.com/api"
    @AppStorage("onshape_apiVersion") private var onshapeApiVersion: String = "v13"
    @AppStorage("onshape_agent_pythonPath") private var onshapeAgentPythonPath: String = ""

    @AppStorage("onshape_oauthClientId") private var onshapeOauthClientId: String = ""
    @AppStorage("onshape_oauthClientSecret") private var onshapeOauthClientSecret: String = ""
    @AppStorage("onshape_oauthBaseUrl") private var onshapeOauthBaseUrl: String = "https://oauth.onshape.com"
    @AppStorage("onshape_oauthRedirectPort") private var onshapeOauthRedirectPort: Int = 5000

    @AppStorage("gemini_enableUrlContext") private var geminiEnableUrlContext: Bool = true
    @AppStorage("gemini_enableCodeExecution") private var geminiEnableCodeExecution: Bool = true

    private let model = "google/gemini-3-flash-preview"

    private let chatSessionId: UUID

    init(screenshot: CGImage, chatSessionId: UUID) {
        self.screenshot = screenshot
        self.chatSessionId = chatSessionId
    }

    private func attachmentsDirectory() throws -> URL {
        try ChatAttachmentStore.sessionDirectory(sessionId: chatSessionId)
    }

    func addPendingAttachments(fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        do {
            let dir = try attachmentsDirectory()

            for src in fileURLs {
                if let att = importAttachmentFile(at: src, into: dir) {
                    pendingAttachments.append(att)
                }
            }
        } catch {
            AppLog.shared.log("Failed to prepare attachments dir: \(error)", level: .error)
        }
    }

    func removePendingAttachment(_ id: UUID) {
        pendingAttachments.removeAll(where: { $0.id == id })
    }

    func clearPendingAttachments() {
        pendingAttachments.removeAll()
    }

    private func fileURL(for attachment: ChatAttachment) -> URL {
        ChatAttachmentStore.fileURL(for: attachment)
    }

    private func importAttachmentFile(at src: URL, into dir: URL, filenameOverride: String? = nil) -> ChatAttachment? {
        let fm = FileManager.default
        let kind = ChatAttachment.inferKind(for: src)
        let safeName = (filenameOverride ?? src.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = safeName.isEmpty ? "attachment" : safeName
        let unique = UUID().uuidString
        let dst = dir.appendingPathComponent(unique + "_" + name)

        do {
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
        } catch {
            // Fallback for security-scoped URLs.
            do {
                let data = try Data(contentsOf: src)
                try data.write(to: dst, options: [.atomic])
            } catch {
                AppLog.shared.log("Failed to import attachment: \(src): \(error)", level: .error)
                return nil
            }
        }

        let rel = chatSessionId.uuidString + "/" + dst.lastPathComponent
        return ChatAttachment(kind: kind, filename: name, relativePath: rel)
    }

    private func extractExistingFilePaths(fromToolResult toolResult: String) -> [String] {
        let trimmed = toolResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8) else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return [] }

        func walk(_ value: Any) -> [String] {
            var out: [String] = []

            if let dict = value as? [String: Any] {
                for (k, v) in dict {
                    if (k == "path" || k.hasSuffix("_path") || k.hasSuffix("Path")),
                       let s = v as? String,
                       !s.isEmpty {
                        out.append(s)
                    }
                    out.append(contentsOf: walk(v))
                }
                return out
            }

            if let array = value as? [Any] {
                for item in array {
                    out.append(contentsOf: walk(item))
                }
                return out
            }

            return out
        }

        let candidates = walk(obj)
        let fm = FileManager.default
        return candidates.filter { path in
            guard !path.isEmpty else { return false }
            guard path.hasPrefix("/") else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    private func attachToolOutputFilesIfPresent(
        toolName: String,
        toolResult: String,
        assistantMessageId: UUID
    ) {
        let paths = extractExistingFilePaths(fromToolResult: toolResult)
        guard !paths.isEmpty else { return }

        do {
            let dir = try attachmentsDirectory()
            for path in paths {
                let url = URL(fileURLWithPath: path)
                if let att = importAttachmentFile(at: url, into: dir) {
                    if let idx = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                        messages[idx].attachments.append(att)
                    }
                }
            }
        } catch {
            AppLog.shared.log("Failed to attach tool output files for \(toolName): \(error)", level: .debug)
        }
    }

    private func spatialPreviewDataURL(fromToolResult toolResult: String) async -> String? {
        let paths = extractExistingFilePaths(fromToolResult: toolResult)
        guard !paths.isEmpty else { return nil }

        let preferredExts: Set<String> = ["glb", "gltf", "stl", "obj", "step", "stp"]
        let selected = paths.first(where: { preferredExts.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) })
            ?? paths.first
        guard let selected else { return nil }

        let url = URL(fileURLWithPath: selected)
        guard let cg = await quickLookThumbnailCGImage(url: url, size: CGSize(width: 1024, height: 1024)) else {
            return nil
        }
        guard let base64 = try? await openRouterClient.encodeImageToBase64(cg) else { return nil }
        return "data:image/jpeg;base64,\(base64)"
    }

    private func captureLatestBrowserScreenshotForModel() async -> String? {
        guard let url = browserLatestScreenshotURL else { return nil }
        guard let cg = loadCGImage(from: url) else { return nil }
        guard let base64 = try? await openRouterClient.encodeImageToBase64(cg) else { return nil }
        return "data:image/jpeg;base64,\(base64)"
    }

    private func summarizeAttachments(_ attachments: [ChatAttachment]) -> String {
        attachments
            .map { "\($0.filename) (\($0.kind.rawValue))" }
            .joined(separator: ", ")
    }

    private func loadCGImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func cgImageFromPDFFirstPage(url: URL, size: CGSize = CGSize(width: 1024, height: 1024)) -> CGImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let img = page.thumbnail(of: size, for: .cropBox)
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func extractPDFText(url: URL, maxChars: Int = 6000) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars)) + "…"
    }

    private func quickLookThumbnailCGImage(url: URL, size: CGSize = CGSize(width: 1024, height: 1024)) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2.0,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                cont.resume(returning: representation?.cgImage)
            }
        }
    }

    private func buildAttachmentContextForModel(
        _ attachments: [ChatAttachment],
        maxImages: Int = 4
    ) async -> (text: String?, imageDataURLs: [String]) {
        guard !attachments.isEmpty else { return (nil, []) }

        var lines: [String] = []
        var images: [String] = []

        let subset = Array(attachments.prefix(maxImages))
        if attachments.count > subset.count {
            lines.append("Attachments (showing \(subset.count) of \(attachments.count)): \(summarizeAttachments(attachments))")
        } else {
            lines.append("Attachments: \(summarizeAttachments(attachments))")
        }

        for att in subset {
            let url = fileURL(for: att)
            lines.append("- \(att.filename) (\(att.kind.rawValue)) local_path=\(url.path)")
            var cg: CGImage? = nil
            var extraText: String? = nil

            switch att.kind {
            case .image:
                cg = loadCGImage(from: url)

            case .pdf:
                cg = cgImageFromPDFFirstPage(url: url)
                extraText = extractPDFText(url: url)

            case .model, .other:
                cg = await quickLookThumbnailCGImage(url: url)
            }

            if let extraText {
                lines.append("\n--- Extracted PDF text (\(att.filename)) ---\n\(extraText)")
            }

            if let cg {
                if let base64 = try? await openRouterClient.encodeImageToBase64(cg) {
                    images.append("data:image/jpeg;base64,\(base64)")
                }
            } else {
                // Always give the model *something* to go on.
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let sizeNum = attrs[.size] as? NSNumber {
                    lines.append("\(att.filename): file size \(sizeNum.intValue) bytes")
                } else {
                    lines.append("\(att.filename): unable to preview")
                }
            }
        }

        return (lines.joined(separator: "\n"), images)
    }

    @discardableResult
    func sendMessage() -> Bool {
        let trimmedInputRaw = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPendingAttachments = !pendingAttachments.isEmpty
        guard !trimmedInputRaw.isEmpty || hasPendingAttachments else { return false }
        guard !isStreaming else { return false }
        guard !apiKey.isEmpty else {
            // Add error message if no API key
            messages.append(
                ChatMessage(
                    role: .assistant, content: "Please set your OpenRouter API key in Settings."))
            AppLog.shared.log("Send blocked: missing API key", level: .error)
            return false
        }

        let textToSend = trimmedInputRaw.isEmpty && hasPendingAttachments ? "Attached file(s)." : trimmedInputRaw

        // Add user message
        let userMessage = ChatMessage(role: .user, content: textToSend, attachments: pendingAttachments)
        let userMessageId = userMessage.id
        messages.append(userMessage)
        AppLog.shared.log("User message queued (chars: \(textToSend.count), attachments: \(pendingAttachments.count))")

        // Clear input
        inputText = ""
        clearPendingAttachments()

        // Mark that we've sent the first message (triggers width expansion)
        hasSentFirstMessage = true

        // Add empty assistant message that will be filled with streaming content
        let assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantMessageId = assistantMessage.id

        // Seed transient thinking UI (shown while assistant bubble is still empty)
        let shouldUseBrowser = isBrowserModeEnabled
        let shouldUseOnShape = onshapeEnabled && isOnShapeModeEnabled
        let interleavedMode = shouldUseBrowser && shouldUseOnShape
        if shouldUseBrowser {
            browserActivityItems.removeAll()
            browserLatestScreenshotURL = nil
        }
        thinkingTraces = makeInitialThinkingTraces(
            shouldSearchWeb: !perplexityApiKey.isEmpty,
            shouldUseBrowser: shouldUseBrowser
        )

        activeOperation = .chat

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

                // Browser automation is now exposed as a tool call (browser_run_task).

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

                if shouldUseBrowser {
                    systemPrompt += "\n\nBrowser automation tools:\n"
                    systemPrompt += "- browser_run_task: Run an autonomous browser task and return a transcript/output.\n"
                    systemPrompt += "- browser_close_browser: Close the agent-controlled browser window/session.\n"
                    systemPrompt += "- browser_close_all_windows: Close all agent-controlled browser windows (optionally keeping the session).\n"
                    systemPrompt += "\nRules: Only call browser_run_task when needed (slow)."
                    if onshapeEnabled {
                        systemPrompt += " Prefer extracting any visible OnShape URLs from the screenshot first."
                    }

                    if shouldUseOnShape {
                        systemPrompt += "\n\nInterleaved mode: Browser + OnShape are both enabled. Prefer short browser_run_task calls (max_steps ~3-5) so you can alternate: browse → verify via screenshot → apply OnShape tool edits → browse again to confirm." 
                    }

                    if browserUseApiKey.isEmpty {
                        systemPrompt += "\n\nNote: Browser Use API key is not configured in Settings; local browser automation may still run, but cloud LLM features may be limited."
                    }
                }

                if shouldUseOnShape {
                    systemPrompt += "\n\nOnShape CAD tools (primitives):\n"
                    systemPrompt += "- cad_create_sketch: Create sketch with lines, circles, arcs, rectangles, points, ellipses, splines (specify plane, mm).\n"
                    systemPrompt += "- cad_extrude: Extrude regions (NEW/ADD/REMOVE/INTERSECT, NORMAL/SYMMETRIC/THROUGH_ALL).\n"
                    systemPrompt += "- cad_revolve: Revolve sketch regions around an axis.\n"
                    systemPrompt += "- cad_sweep: Sweep a profile along a path.\n"
                    systemPrompt += "- cad_loft: Create a loft between multiple profiles.\n"
                    systemPrompt += "- cad_fillet/cad_chamfer: Add fillets or chamfers to edges.\n"
                    systemPrompt += "- cad_shell: Hollow out a part (specify faces to remove).\n"
                    systemPrompt += "- cad_boolean: Union, Subtract, or Intersect parts.\n"
                    systemPrompt += "- cad_pattern_linear/cad_pattern_circular: Create patterns of parts.\n"
                    systemPrompt += "- cad_mirror: Mirror parts across a plane.\n"
                    systemPrompt += "- cad_hole: Create holes at specified points.\n"
                    systemPrompt += "- cad_draft: Add draft angles to faces.\n"
                    systemPrompt += "- cad_thicken: Thicken surfaces or faces.\n"
                    systemPrompt += "- cad_split: Split parts using a tool.\n"
                    systemPrompt += "- cad_transform_part: Translate parts in XYZ.\n"
                    systemPrompt += "- cad_create_plane: Create offset construction planes.\n"
                    systemPrompt += "\nOnShape document/context tools:\n"
                    systemPrompt += "- onshape_parse_url: Extract did/wvm/wvmid/eid from an OnShape URL.\n"
                    systemPrompt += "- onshape_set_context: Persist active context for later calls.\n"
                    systemPrompt += "- onshape_list_elements: List elements/tabs in a document.\n"
                    systemPrompt += "- onshape_snapshot_element: Spatial snapshot (bounding boxes + mass properties + exported glTF path) for Part Studios and Assemblies.\n"
                    systemPrompt += "- onshape_create_assembly/cad_create_partstudio: Create new elements.\n"
                    systemPrompt += "- onshape_switch_to_element: Switch the active element (tab) by ID.\n"
                    systemPrompt += "- onshape_insert_instance: Insert Part Studio or Part into an Assembly.\n"
                    systemPrompt += "- onshape_transform_instance: Move/Rotate instance in an Assembly (4x4 matrix).\n"
                    systemPrompt += "- onshape_add_mate: Add assembly mates (FASTENED, REVOLUTE, SLIDER, etc.).\n"
                    systemPrompt += "- onshape_get_assembly_definition: Fetch assembly structure.\n"
                    systemPrompt += "- onshape_get_parts: List parts in a Part Studio.\n"
                    systemPrompt += "\nWorkflow for assemblies:\n"
                    systemPrompt += "1. Create Part Studios for each unique part.\n"
                    systemPrompt += "2. Note the new element ID. Use onshape_switch_to_element to change focus before creating features.\n"
                    systemPrompt += "3. Create an Assembly and switch to it.\n"
                    systemPrompt += "4. Insert instances and use onshape_add_mate or onshape_transform_instance to position them.\n"
                    systemPrompt += "\nWorkflow for complex shapes:\n"
                    systemPrompt += "1. Parse URL and set context.\n"
                    systemPrompt += "2. Use sketches and extrude/revolve/sweep/loft to build geometry.\n"
                    systemPrompt += "3. Use patterns/mirror for repetitive features.\n"
                    systemPrompt += "4. Use onshape_snapshot_element to visually sanity-check.\n"
                    systemPrompt += "\nIf the user provides drawings (images/PDF) or reference models as attachments, interpret them first and then create parametric sketches/features. Prefer dimensioned geometry and validation loops.\n"
                    systemPrompt += "\nRules: Always parse URL and set context first. IMPORTANT: When calling onshape_set_context, include the base_url from onshape_parse_url (e.g. 'https://cteinccsd.onshape.com/api') to connect to the correct OnShape server. Use plane ids Top/Front/Right (or xy/xz/yz)."
                    systemPrompt += "\nUnits: For any non-zero length/coordinate, always include explicit units like '10 mm' or '0.25 in'. Only use bare numbers for exact 0."
                    systemPrompt += "\nSketching: Avoid mixing an outer profile + hole circles in one sketch when you plan to extrude, since cad_extrude selects all sketch regions. Instead: extrude the outer profile, then make separate hole sketches and extrude REMOVE/CUT with direction='THROUGH_ALL'."

                    if onshapeApiKey.isEmpty || onshapeSecretKey.isEmpty {
                        systemPrompt += "\n\nNote: OnShape API credentials are not configured in Settings, so authenticated API calls will fail until you set them."
                    }

                    let tokenFile = OnShapeOAuthService.defaultTokenFileURL()
                    if onshapeOauthClientId.isEmpty || onshapeOauthClientSecret.isEmpty {
                        if !FileManager.default.fileExists(atPath: tokenFile.path) {
                            systemPrompt += "\n\nNote: OnShape OAuth is not configured (and no OAuth token file exists). If API keys are disabled, authorize OAuth in Settings → OnShape."
                        }
                    }

                    do {
                        try await OnShapeMcpWorker.shared.startIfNeeded(
                            accessKey: onshapeApiKey,
                            secretKey: onshapeSecretKey,
                            baseURL: onshapeBaseUrl,
                            apiVersion: onshapeApiVersion,
                            pythonPath: onshapeAgentPythonPath,
                            oauthClientId: onshapeOauthClientId,
                            oauthClientSecret: onshapeOauthClientSecret,
                            oauthBaseURL: onshapeOauthBaseUrl,
                            oauthTokenFilePath: tokenFile.path
                        )
                        try await OnShapeMcpWorker.shared.ping()
                    } catch {
                        AppLog.shared.log("OnShape MCP server failed to start: \(error)", level: .error)
                        systemPrompt += "\n\nWarning: OnShape MCP server failed to start (\(error.localizedDescription)). Tool calls may fail."
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

                    var content: [OpenRouterMessage.MessageContent] = []

                    // For older messages, keep attachment context lightweight (text only).
                    if msg.id != userMessageId, !msg.attachments.isEmpty {
                        content.append(.text("Attachments: \(summarizeAttachments(msg.attachments))"))
                    }

                    // Add screenshot + full attachment context to the current user message.
                    if msg.id == userMessageId {
                        let (attText, attImages) = await buildAttachmentContextForModel(msg.attachments)
                        for dataURL in attImages {
                            content.append(.imageUrl(.init(url: dataURL)))
                        }
                        content.append(.imageUrl(.init(url: "data:image/jpeg;base64,\(screenshotBase64)")))
                        if let attText {
                            content.append(.text(attText))
                        }
                    }

                    content.append(.text(msg.content))

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

                if shouldUseBrowser {
                    for tool in browserToolSpecs() {
                        enabledTools.append(.function(tool))
                    }
                }

                if shouldUseOnShape {
                    for tool in onshapeToolSpecs() {
                        enabledTools.append(.function(tool))
                    }
                }

                updateTrace(.startingResponse, status: .active)

                let maxToolIterations = (shouldUseOnShape || shouldUseBrowser) ? 50 : 3
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
                        thinkingLevel: shouldUseOnShape ? "high" : "low",
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
                            let toolResultRaw = await executeToolCall(call, userQuery: textToSend)
                            let toolResultForModel = clipToolResult(toolResultRaw, maxChars: 60_000)
                            apiMessages.append(
                                OpenRouterMessage(
                                    role: "tool",
                                    content: [.text(toolResultForModel)],
                                    toolCallId: call.id
                                )
                            )

                            if call.function.name.hasPrefix("onshape_") || call.function.name.hasPrefix("cad_") {
                                let fileProducingTools: Set<String> = [
                                    "onshape_export_partstudio_gltf",
                                    "onshape_snapshot_partstudio",
                                    "onshape_snapshot_element",
                                    "cad_svg_to_dxf",
                                    "cad_write_dxf",
                                ]

                                if fileProducingTools.contains(call.function.name) {
                                    attachToolOutputFilesIfPresent(
                                        toolName: call.function.name,
                                        toolResult: toolResultRaw,
                                        assistantMessageId: assistantMessageId
                                    )
                                }

                                if call.function.name == "onshape_export_partstudio_gltf"
                                    || call.function.name == "onshape_snapshot_partstudio"
                                    || call.function.name == "onshape_snapshot_element" {
                                    if let dataURL = await spatialPreviewDataURL(fromToolResult: toolResultRaw) {
                                        apiMessages.append(
                                            OpenRouterMessage(
                                                role: "user",
                                                content: [
                                                    .text("Context only: spatial snapshot from OnShape. Use this image to verify geometry before making further edits."),
                                                    .imageUrl(.init(url: dataURL)),
                                                ]
                                            )
                                        )
                                    }
                                }
                            }

                            // Attach the latest browser screenshot to the assistant message (UI visibility).
                            if call.function.name == "browser_run_task", let screenshotURL = browserLatestScreenshotURL {
                                do {
                                    let dir = try attachmentsDirectory()
                                    let ext = screenshotURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let name = ext.isEmpty ? "browser_screenshot" : "browser_screenshot.\(ext)"
                                    if let att = importAttachmentFile(at: screenshotURL, into: dir, filenameOverride: name) {
                                        if let idx = messages.firstIndex(where: { $0.id == assistantMessageId }) {
                                            messages[idx].attachments.append(att)
                                        }
                                    }
                                } catch {
                                    AppLog.shared.log("Failed to attach browser screenshot: \(error)", level: .debug)
                                }
                            }

                            // Interleaved mode: feed the browser screenshot back into the orchestrator as vision context.
                            if interleavedMode, call.function.name == "browser_run_task" {
                                if let dataURL = await captureLatestBrowserScreenshotForModel() {
                                    apiMessages.append(
                                        OpenRouterMessage(
                                            role: "user",
                                            content: [
                                                .text("Context only: screenshot captured from the browser automation tool output. Use it to verify page state before issuing any OnShape changes."),
                                                .imageUrl(.init(url: dataURL)),
                                            ]
                                        )
                                    )
                                }
                            }
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

                if shouldUseBrowser {
                    if let idx = thinkingTraces.firstIndex(where: { $0.id == .openingBrowser }),
                       thinkingTraces[idx].status == .pending {
                        updateTrace(.openingBrowser, status: .done, detail: "Not used")
                    }
                    if let idx = thinkingTraces.firstIndex(where: { $0.id == .browsing }),
                       thinkingTraces[idx].status == .pending {
                        updateTrace(.browsing, status: .done, detail: "Not used")
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
                if Task.isCancelled || error is CancellationError || urlError?.code == .cancelled || isCancellationLikeError(error) {
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

    private func clipToolResult(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars {
            return trimmed
        }
        return String(trimmed.prefix(maxChars)) + "\n… (truncated)"
    }

    private func isCancellationLikeError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        if let openRouterError = error as? OpenRouterError {
            // In case errors are bridged via NSError, cancellation can still bubble up.
            let ns = openRouterError as NSError
            if ns.domain == NSURLErrorDomain, ns.code == URLError.cancelled.rawValue {
                return true
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == URLError.cancelled.rawValue {
            return true
        }
        return false
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

    private func onshapeToolSpecs() -> [OpenRouterFunctionTool] {
        let emptyObjectSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])

        let wvmEnum: JSONValue = .array([.string("w"), .string("v"), .string("m")])
        let cadOperationEnum: JSONValue = .array([.string("NEW"), .string("ADD"), .string("REMOVE"), .string("CUT"), .string("INTERSECT")])
        let cadDirectionEnum: JSONValue = .array([.string("NORMAL"), .string("SYMMETRIC"), .string("THROUGH_ALL")])
        let variableTypeEnum: JSONValue = .array([
            .string("LENGTH"),
            .string("ANGLE"),
            .string("NUMBER"),
            .string("ANY"),
            .string("UNKNOWN"),
        ])

        return [
            OpenRouterFunctionTool(
                name: "onshape_parse_url",
                description: "Extract did/wvm/wvmid/eid from an OnShape URL.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object([
                            "type": .string("string"),
                            "description": .string("Full OnShape URL")
                        ])
                    ]),
                    "required": .array([.string("url")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_set_context",
                description: "Set active did/wvm/wvmid/eid for subsequent OnShape calls.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "base_url": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_get_context",
                description: "Return current OnShape context.",
                parameters: emptyObjectSchema
            ),
            OpenRouterFunctionTool(
                name: "onshape_get_document",
                description: "Get document metadata.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_request",
                description: "Low-level REST call wrapper for any OnShape endpoint (GET/POST/DELETE).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "method": .object([
                            "type": .string("string"),
                            "enum": .array([.string("GET"), .string("POST"), .string("DELETE")])
                        ]),
                        "path": .object(["type": .string("string")]),
                        "query": .object(["type": .string("object")]),
                        "body": .object(["type": .string("object")]),
                        "accept": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("method"), .string("path")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_get_translation",
                description: "Fetch translation status by translation_id.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "translation_id": .object(["type": .string("string")]),
                        "id": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_import_file",
                description: "Import a local file into an OnShape document via translations (workspace).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "path": .object(["type": .string("string")]),
                        "store_in_document": .object(["type": .string("boolean")]),
                        "translate": .object(["type": .string("boolean")]),
                        "flatten_assemblies": .object(["type": .string("boolean")]),
                        "format_name": .object(["type": .string("string")]),
                        "wait": .object(["type": .string("boolean")]),
                        "timeout_s": .object(["type": .string("number")]),
                        "poll_interval_s": .object(["type": .string("number")])
                    ]),
                    "required": .array([.string("path")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_list_elements",
                description: "List elements/tabs in a document context.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_get_features_summary",
                description: "Summarize Part Studio feature list (compact).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_get_partstudio_feature",
                description: "Fetch a full serialized feature definition by feature_id.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "feature_id": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("feature_id")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_add_partstudio_feature",
                description: "Add a feature to a Part Studio feature list (workspace context).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "feature": .object(["type": .string("object")]),
                        "call": .object(["type": .string("object")]),
                        "library_version": .object(["type": .string("integer")]),
                        "serialization_version": .object(["type": .string("string")]),
                        "source_microversion": .object(["type": .string("string")]),
                        "reject_microversion_skew": .object(["type": .string("boolean")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_update_partstudio_feature",
                description: "Update an existing feature definition in a Part Studio workspace.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "feature_id": .object(["type": .string("string")]),
                        "feature": .object(["type": .string("object")]),
                        "call": .object(["type": .string("object")]),
                        "library_version": .object(["type": .string("integer")]),
                        "serialization_version": .object(["type": .string("string")]),
                        "source_microversion": .object(["type": .string("string")]),
                        "reject_microversion_skew": .object(["type": .string("boolean")])
                    ]),
                    "required": .array([.string("feature_id")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_eval_featurescript",
                description: "Evaluate a FeatureScript snippet in a Part Studio.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "script": .object(["type": .string("string")]),
                        "queries": .object(["type": .string("object")]),
                        "configuration": .object(["type": .string("string")]),
                        "rollback_bar_index": .object(["type": .string("integer")]),
                        "element_microversion_id": .object(["type": .string("string")]),
                        "reject_microversion_skew": .object(["type": .string("boolean")]),
                        "call": .object(["type": .string("object")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_get_partstudio_featurespecs",
                description: "Get feature spec definitions for a Part Studio.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_patch_partstudio_feature_params",
                description: "Fetch a feature, patch specific params, and update it in a workspace.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "feature_id": .object(["type": .string("string")]),
                        "patches": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("object")])
                        ])
                    ]),
                    "required": .array([.string("feature_id"), .string("patches")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_get_partstudio_bounding_boxes",
                description: "Get Part Studio bounding boxes for validation.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_get_partstudio_mass_properties",
                description: "Get Part Studio mass properties for validation.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "configuration": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_get_partstudio_shaded_views",
                description: "Get shaded view metadata for a Part Studio.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_export_partstudio_gltf",
                description: "Export Part Studio glTF/glb to a local file.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_snapshot_partstudio",
                description: "Spatial snapshot: bounding boxes + mass properties + exported glTF path.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "configuration": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_svg_to_sketch",
                description: "Parse SVG (<path>/<polyline>/<polygon>), flatten curves into line segments, and create an Onshape sketch (1 SVG unit = 1 mm by default).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "svg": .object(["type": .string("string")]),
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")]),
                        "plane": .object(["type": .string("string")]),
                        "tolerance_mm": .object(["type": .string("number")]),
                        "max_segments": .object(["type": .string("integer")]),
                        "scale_mm_per_unit": .object(["type": .string("number")]),
                        "center": .object(["type": .string("boolean")]),
                        "flip_y": .object(["type": .string("boolean")])
                    ]),
                    "required": .array([.string("svg")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_svg_to_dxf",
                description: "Parse SVG and write a minimal ASCII DXF to a local temp file (mm units).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "svg": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")]),
                        "tolerance_mm": .object(["type": .string("number")]),
                        "max_segments": .object(["type": .string("integer")]),
                        "scale_mm_per_unit": .object(["type": .string("number")]),
                        "center": .object(["type": .string("boolean")]),
                        "flip_y": .object(["type": .string("boolean")])
                    ]),
                    "required": .array([.string("svg")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_write_dxf",
                description: "Write model-generated DXF text to a local temp file.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "dxf": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("dxf")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_create_cube",
                description: "Create a cube feature (workspace). side_length must include explicit units like '25 mm'.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")]),
                        "side_length": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("side_length")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_create_circle_sketch",
                description: "Create a circle sketch (workspace).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")]),
                        "plane": .object(["type": .string("string")]),
                        "radius": .object(["type": .string("string")]),
                        "x_center": .object(["type": .string("string")]),
                        "y_center": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("radius")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_extrude_from_sketch",
                description: "Extrude all regions of a sketch feature (workspace). For through cuts use direction='THROUGH_ALL'. For symmetric extrudes set direction='SYMMETRIC' and pass depth as half-thickness.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")]),
                        "sketch_feature_id": .object(["type": .string("string")]),
                        "depth": .object(["type": .string("string")]),
                        "operation": .object([
                            "type": .string("string"),
                            "enum": cadOperationEnum
                        ]),
                        "direction": .object([
                            "type": .string("string"),
                            "enum": cadDirectionEnum
                        ])
                    ]),
                    "required": .array([.string("sketch_feature_id")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_create_cylinder",
                description: "Create a circle sketch and extrude it into a cylinder (workspace).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "plane": .object(["type": .string("string")]),
                        "radius": .object(["type": .string("string")]),
                        "x_center": .object(["type": .string("string")]),
                        "y_center": .object(["type": .string("string")]),
                        "depth": .object(["type": .string("string")]),
                        "operation": .object([
                            "type": .string("string"),
                            "enum": cadOperationEnum
                        ]),
                        "direction": .object([
                            "type": .string("string"),
                            "enum": cadDirectionEnum
                        ])
                    ]),
                    "required": .array([.string("radius"), .string("depth")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_create_sketch",
                description: "Create a sketch with lines, circles, and rectangles. Prefer unit-suffixed strings like '10 mm' for non-zero values.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")]),
                        "plane": .object(["type": .string("string"), "description": .string("Top, Front, Right, or xy/xz/yz")]),
                        "lines": .object([
                            "type": .string("array"),
                            "description": .string("Lines: [{x1, y1, x2, y2}, ...]"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "x1": .object(["type": .string("string")]),
                                    "y1": .object(["type": .string("string")]),
                                    "x2": .object(["type": .string("string")]),
                                    "y2": .object(["type": .string("string")])
                                ]),
                                "required": .array([.string("x1"), .string("y1"), .string("x2"), .string("y2")]),
                                "additionalProperties": .bool(false)
                            ])
                        ]),
                        "circles": .object([
                            "type": .string("array"),
                            "description": .string("Circles: [{cx, cy, radius}, ...]"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "cx": .object(["type": .string("string")]),
                                    "cy": .object(["type": .string("string")]),
                                    "radius": .object(["type": .string("string")])
                                ]),
                                "required": .array([.string("cx"), .string("cy"), .string("radius")]),
                                "additionalProperties": .bool(false)
                            ])
                        ]),
                        "rectangles": .object([
                            "type": .string("array"),
                            "description": .string("Rectangles: [{x1, y1, x2, y2}, ...]"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "x1": .object(["type": .string("string")]),
                                    "y1": .object(["type": .string("string")]),
                                    "x2": .object(["type": .string("string")]),
                                    "y2": .object(["type": .string("string")])
                                ]),
                                "required": .array([.string("x1"), .string("y1"), .string("x2"), .string("y2")]),
                                "additionalProperties": .bool(false)
                            ])
                        ])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_extrude",
                description: "Extrude sketch regions. Operations: NEW, ADD, REMOVE/CUT, INTERSECT. Directions: NORMAL, SYMMETRIC, THROUGH_ALL.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "sketch_feature_id": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")]),
                        "depth": .object(["type": .string("string")]),
                        "operation": .object([
                            "type": .string("string"),
                            "enum": cadOperationEnum
                        ]),
                        "direction": .object([
                            "type": .string("string"),
                            "enum": cadDirectionEnum
                        ])
                    ]),
                    "required": .array([.string("sketch_feature_id")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_fillet",
                description: "Add fillets to all edges of a feature.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "feature_id": .object(["type": .string("string")]),
                        "radius": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("feature_id"), .string("radius")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "cad_chamfer",
                description: "Add chamfers to all edges of a feature.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "feature_id": .object(["type": .string("string")]),
                        "distance": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("feature_id"), .string("distance")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_get_variables",
                description: "Get variables in a Part Studio or Variable Studio element.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wvm": .object([
                            "type": .string("string"),
                            "enum": wvmEnum
                        ]),
                        "wvmid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "configuration": .object(["type": .string("string")])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "onshape_set_variables",
                description: "Update variables in a workspace (typically a Variable Studio element).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "did": .object(["type": .string("string")]),
                        "wid": .object(["type": .string("string")]),
                        "eid": .object(["type": .string("string")]),
                        "updates": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "name": .object(["type": .string("string")]),
                                    "type": .object([
                                        "type": .string("string"),
                                        "enum": variableTypeEnum
                                    ]),
                                    "expression": .object(["type": .string("string")]),
                                    "description": .object(["type": .string("string")])
                                ]),
                                "required": .array([.string("name"), .string("expression")]),
                                "additionalProperties": .bool(false)
                            ])
                        ])
                    ]),
                    "required": .array([.string("updates")]),
                    "additionalProperties": .bool(false)
                ])
            ),
        ]
    }

    private func browserToolSpecs() -> [OpenRouterFunctionTool] {
        let emptyObjectSchema: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false)
        ])

        return [
            OpenRouterFunctionTool(
                name: "browser_run_task",
                description: "Run an autonomous browser task and return transcript/output.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "task": .object([
                            "type": .string("string"),
                            "description": .string("What to do in the browser")
                        ]),
                        "max_steps": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum browser steps (optional)")
                        ]),
                        "keep_session": .object([
                            "type": .string("boolean"),
                            "description": .string("Whether to keep the browser session alive between calls (optional)")
                        ])
                    ]),
                    "required": .array([.string("task")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            OpenRouterFunctionTool(
                name: "browser_close_browser",
                description: "Close the agent-controlled browser window/session.",
                parameters: emptyObjectSchema
            ),
            OpenRouterFunctionTool(
                name: "browser_close_all_windows",
                description: "Close all agent-controlled browser windows (optionally keeping session).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "keep_session": .object([
                            "type": .string("boolean"),
                            "description": .string("If false, also clears the session profile (optional)")
                        ])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ),
        ]
    }

    private struct PerplexitySearchArgs: Decodable {
        let query: String
        let max_results: Int?
    }

    private struct BrowserRunTaskArgs: Decodable {
        let task: String
        let max_steps: Int?
        let keep_session: Bool?
    }

    private struct BrowserCloseAllWindowsArgs: Decodable {
        let keep_session: Bool?
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

        case "browser_run_task":
            do {
                let argsData = Data(call.function.arguments.utf8)
                let args = (try? JSONDecoder().decode(BrowserRunTaskArgs.self, from: argsData))
                    ?? BrowserRunTaskArgs(task: userQuery, max_steps: nil, keep_session: nil)

                let keepSession = args.keep_session ?? browserAgentKeepSession
                let isInterleavedMode = isBrowserModeEnabled && onshapeEnabled && isOnShapeModeEnabled
                let maxSteps = args.max_steps ?? (isInterleavedMode ? 5 : nil)

                browserActivityItems.removeAll()
                browserLatestScreenshotURL = nil
                isBrowserPaused = false

                updateTrace(.openingBrowser, status: .active)
                updateTrace(.browsing, status: .active, detail: "Starting")
                activeOperation = .browser

                let userDataDir = try ensureBrowserUserDataDirectory(keepSession: keepSession)
                let output = try await BrowserUseWorker.shared.runTask(
                    browserUseApiKey: browserUseApiKey,
                    userDataDir: userDataDir,
                    keepSession: keepSession,
                    task: args.task,
                    maxSteps: maxSteps,
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

                let clippedOutput = output.count > 20000 ? String(output.prefix(20000)) + "…" : output

                updateTrace(.openingBrowser, status: .done)
                updateTrace(.browsing, status: .done)
                activeOperation = .chat

                var payload: [String: Any] = [
                    "ok": true,
                    "tool": "browser_run_task",
                    "task": args.task,
                    "output": clippedOutput,
                ]
                if let maxSteps {
                    payload["max_steps"] = maxSteps
                }
                let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                return String(data: data, encoding: .utf8) ?? clippedOutput

            } catch {
                AppLog.shared.log("Browser tool failed: \(error)", level: .error)
                let detail = error.localizedDescription
                updateTrace(.openingBrowser, status: .failed, detail: detail)
                updateTrace(.browsing, status: .failed, detail: detail)
                activeOperation = .chat
                isBrowserPaused = false

                let payload: [String: Any] = [
                    "ok": false,
                    "tool": "browser_run_task",
                    "error": detail,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                   let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return "{\"ok\":false,\"tool\":\"browser_run_task\",\"error\":\"\(detail)\"}"
            }

        case "browser_close_browser":
            do {
                try await BrowserUseWorker.shared.closeBrowser()
                let payload: [String: Any] = ["ok": true, "tool": "browser_close_browser"]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                return String(data: data, encoding: .utf8) ?? "{\"ok\":true}"
            } catch {
                let payload: [String: Any] = [
                    "ok": false,
                    "tool": "browser_close_browser",
                    "error": error.localizedDescription,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                   let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return "{\"ok\":false,\"tool\":\"browser_close_browser\",\"error\":\"\(error.localizedDescription)\"}"
            }

        case "browser_close_all_windows":
            do {
                let argsData = Data(call.function.arguments.utf8)
                let args = try? JSONDecoder().decode(BrowserCloseAllWindowsArgs.self, from: argsData)
                let keepSession = args?.keep_session ?? browserAgentKeepSession
                try await BrowserUseWorker.shared.closeAllWindows(keepSession: keepSession)
                let payload: [String: Any] = [
                    "ok": true,
                    "tool": "browser_close_all_windows",
                    "keep_session": keepSession,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                return String(data: data, encoding: .utf8) ?? "{\"ok\":true}"
            } catch {
                let payload: [String: Any] = [
                    "ok": false,
                    "tool": "browser_close_all_windows",
                    "error": error.localizedDescription,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                   let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return "{\"ok\":false,\"tool\":\"browser_close_all_windows\",\"error\":\"\(error.localizedDescription)\"}"
            }

        case let toolName where toolName.hasPrefix("onshape_") || toolName.hasPrefix("cad_"):
            do {
                let argsData = Data(call.function.arguments.utf8)
                let args = (try? JSONDecoder().decode([String: JSONValue].self, from: argsData)) ?? [:]

                try await OnShapeMcpWorker.shared.startIfNeeded(
                    accessKey: onshapeApiKey,
                    secretKey: onshapeSecretKey,
                    baseURL: onshapeBaseUrl,
                    apiVersion: onshapeApiVersion,
                    pythonPath: onshapeAgentPythonPath,
                    oauthClientId: onshapeOauthClientId,
                    oauthClientSecret: onshapeOauthClientSecret,
                    oauthBaseURL: onshapeOauthBaseUrl,
                    oauthTokenFilePath: OnShapeOAuthService.defaultTokenFileURL().path
                )

                let text = try await OnShapeMcpWorker.shared.callTool(name: toolName, arguments: args)
                return text

            } catch let err as OnShapeMcpWorkerError {
                if case .toolError(let text) = err {
                    return text
                }
                let payload: [String: Any] = [
                    "tool": toolName,
                    "error": err.localizedDescription
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                   let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return "{\"tool\":\"\(toolName)\",\"error\":\"\(err.localizedDescription)\"}"

            } catch {
                let payload: [String: Any] = [
                    "tool": toolName,
                    "error": error.localizedDescription
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                   let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return "{\"tool\":\"\(toolName)\",\"error\":\"\(error.localizedDescription)\"}"
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

    private func ensureBrowserUserDataDirectory(keepSession: Bool) throws -> URL {
        let fileManager = FileManager.default
        let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        let profileDir = baseDir
            .appendingPathComponent("BetterSiri", isDirectory: true)
            .appendingPathComponent("BrowserAgentProfile", isDirectory: true)

        if keepSession {
            try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)
            return profileDir
        }

        let sessionDir = profileDir
            .appendingPathComponent(chatSessionId.uuidString, isDirectory: true)

        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        return sessionDir
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
