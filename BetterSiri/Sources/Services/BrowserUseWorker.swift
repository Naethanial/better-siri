import Foundation

enum BrowserUseWorkerError: Error, LocalizedError {
    case resourceMissing(String)
    case processNotRunning
    case invalidWorkerResponse
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "Missing BrowserAgent resource: \(name)"
        case .processNotRunning:
            return "Browser agent process is not running"
        case .invalidWorkerResponse:
            return "Invalid response from browser agent"
        case .commandFailed(let message):
            return message
        }
    }
}

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

struct BrowserUseWorkerMessage: Decodable {
    let id: String?
    let type: String
    let payload: [String: JSONValue]?
}

struct BrowserUseEvent: Sendable {
    let event: String
    let step: Int?
    let url: String?
    let title: String?
    let memory: String?
    let actions: [JSONValue]?
    let text: String?
    let screenshotPath: String?
    let screenshotThumbPath: String?

    /// Human-friendly summary for simple UI.
    let detail: String?
}

struct BrowserTab: Sendable, Hashable {
    let index: Int
    let title: String?
    let url: String?
}

struct BrowserTabContext: Sendable {
    let tabs: [BrowserTab]
    let activeIndex: Int?
    let activeTextExcerpt: String?
}

actor BrowserUseWorker {
    static let shared = BrowserUseWorker()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var buffer = Data()
    private var startedBrowserUseApiKey: String?
    private var startedPythonCommand: String?
    private var isReady: Bool = false
    private struct ReadyWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var readyWaiters: [ReadyWaiter] = []
    private var currentUserDataDir: String?
    private var currentChromeExecutablePath: String?
    private var currentProfileDirectory: String?
    private var currentChromeArgs: [String] = []

    private struct PendingRequest {
        let id: String
        let onEvent: (@Sendable (BrowserUseWorkerMessage) -> Void)?
        let continuation: CheckedContinuation<BrowserUseWorkerMessage, Error>
    }

    private var pending: [String: PendingRequest] = [:]

    var isRunning: Bool {
        process?.isRunning == true
    }

    private func resolvePythonCommand(scriptURL: URL) -> (executableURL: URL, arguments: [String], signature: String) {
        let configuredPython = (UserDefaults.standard.string(forKey: "browser_agent_pythonPath") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envPython = (ProcessInfo.processInfo.environment["BETTERSIRI_BROWSER_AGENT_PYTHON"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !configuredPython.isEmpty {
            let signature = "python:\(configuredPython)"
            return (URL(fileURLWithPath: configuredPython), ["-u", scriptURL.path], signature)
        }

        if !envPython.isEmpty {
            let signature = "python:\(envPython)"
            return (URL(fileURLWithPath: envPython), ["-u", scriptURL.path], signature)
        }

        // Local dev convenience: prefer a repo-local venv if present.
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()

        let candidates: [URL] = [
            cwd.appendingPathComponent(".browser-agent-venv/bin/python"),
            cwd.appendingPathComponent("../.browser-agent-venv/bin/python"),
            cwd.appendingPathComponent("../../.browser-agent-venv/bin/python"),
            bundleParent.appendingPathComponent(".browser-agent-venv/bin/python"),
        ]

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path) {
                let signature = "python:\(candidate.path)"
                return (candidate, ["-u", scriptURL.path], signature)
            }
        }

        // Default: PATH python3.
        let signature = "env:python3"
        return (URL(fileURLWithPath: "/usr/bin/env"), ["python3", "-u", scriptURL.path], signature)
    }

    private func resolveWorkerScriptURL() throws -> URL {
        let fileName = "browser_use_worker"
        let ext = "py"

        // Preferred: SwiftPM resources embedded in the module bundle.
        if let url = Bundle.module.url(forResource: fileName, withExtension: ext) {
            return url
        }

        // Fall back to common subdirectory layouts (in case resources are reorganized).
        let subdirs = ["BrowserAgent", "Resources/BrowserAgent"]
        for subdir in subdirs {
            if let url = Bundle.module.url(forResource: fileName, withExtension: ext, subdirectory: subdir) {
                return url
            }
        }

        // Packaging fallback: allow the script to live in the app's main Resources dir.
        if let url = Bundle.main.url(forResource: fileName, withExtension: ext) {
            return url
        }
        for subdir in subdirs {
            if let url = Bundle.main.url(forResource: fileName, withExtension: ext, subdirectory: subdir) {
                return url
            }
        }

        // Last resort: scan Bundle.module for a matching filename.
        // This is intentionally best-effort and only runs on startup.
        let expected = "\(fileName).\(ext)"
        if let enumerator = FileManager.default.enumerator(
            at: Bundle.module.bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == expected {
                    return url
                }
            }
        }

        let pyFiles = (Bundle.module.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
            .map { $0.lastPathComponent }
            .sorted()
        let bundlePath = Bundle.module.bundleURL.path
        let pyList = pyFiles.isEmpty ? "(none)" : pyFiles.joined(separator: ", ")
        AppLog.shared.log(
            "BrowserUseWorker: missing browser_use_worker.py. Bundle.module at \(bundlePath). Found .py files: \(pyList)",
            level: .error
        )

        throw BrowserUseWorkerError.resourceMissing("browser_use_worker.py")
    }

    func startIfNeeded(browserUseApiKey: String?) async throws {
        let scriptURL = try resolveWorkerScriptURL()
        let python = resolvePythonCommand(scriptURL: scriptURL)

        if isRunning {
            // Restart if critical config changed.
            if startedBrowserUseApiKey != browserUseApiKey || startedPythonCommand != python.signature {
                stopProcess()
            } else {
                return
            }
        }

        let process = Process()

        process.executableURL = python.executableURL
        process.arguments = python.arguments

        var env = ProcessInfo.processInfo.environment
        if let browserUseApiKey, !browserUseApiKey.isEmpty {
            env["BROWSER_USE_API_KEY"] = browserUseApiKey
        } else {
            env.removeValue(forKey: "BROWSER_USE_API_KEY")
        }
        process.environment = env

        startedBrowserUseApiKey = browserUseApiKey
        startedPythonCommand = python.signature

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        self.process = process
        isReady = false
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task {
                await self?.handleStdout(data)
            }
        }

        stderrHandle?.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                let trimmed = text.count > 1200 ? String(text.prefix(1200)) + "…" : text
                AppLog.shared.log("BrowserUseWorker stderr: \(trimmed)", level: .debug)
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task {
                await self?.handleTermination(proc)
            }
        }

        AppLog.shared.log("BrowserUseWorker started (\(python.signature))")
        try await waitForReady(timeoutSeconds: 3.0)
    }

    func stopProcess() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdinHandle?.closeFile()
        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        startedBrowserUseApiKey = nil
        startedPythonCommand = nil
        currentUserDataDir = nil
        currentChromeExecutablePath = nil
        currentProfileDirectory = nil
        currentChromeArgs = []
        isReady = false

        for waiter in readyWaiters {
            waiter.continuation.resume(throwing: BrowserUseWorkerError.processNotRunning)
        }
        readyWaiters.removeAll()
    }

    private func handleTermination(_ proc: Process) {
        AppLog.shared.log("BrowserUseWorker terminated (status: \(proc.terminationStatus))", level: .error)
        for (_, req) in pending {
            req.continuation.resume(throwing: BrowserUseWorkerError.processNotRunning)
        }
        pending.removeAll()
        process = nil
        startedBrowserUseApiKey = nil
        startedPythonCommand = nil
        currentUserDataDir = nil
        currentChromeExecutablePath = nil
        currentProfileDirectory = nil
        currentChromeArgs = []
        isReady = false

        for waiter in readyWaiters {
            waiter.continuation.resume(throwing: BrowserUseWorkerError.processNotRunning)
        }
        readyWaiters.removeAll()
    }

    private func handleStdout(_ data: Data) {
        buffer.append(data)
        while true {
            guard let range = buffer.firstRange(of: Data([0x0A])) else { break }
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { continue }

            guard let messageData = line.data(using: .utf8) else { continue }
            guard let msg = try? JSONDecoder().decode(BrowserUseWorkerMessage.self, from: messageData) else {
                AppLog.shared.log("BrowserUseWorker: failed decoding line: \(line)", level: .error)
                continue
            }
            route(msg)
        }
    }

    private func route(_ msg: BrowserUseWorkerMessage) {
        if msg.type == "ready" {
            AppLog.shared.log("BrowserUseWorker ready")
            isReady = true
            for waiter in readyWaiters {
                waiter.continuation.resume()
            }
            readyWaiters.removeAll()
            return
        }

        guard let id = msg.id, let req = pending[id] else {
            // Uncorrelated events are still useful for debugging.
            AppLog.shared.log("BrowserUseWorker unhandled message: \(msg.type)", level: .debug)
            return
        }

        req.onEvent?(msg)

        if msg.type.hasSuffix(".ok") || msg.type.hasSuffix(".error") || msg.type.hasSuffix(".cancelled") || msg.type == "error" {
            pending.removeValue(forKey: id)
            if msg.type.hasSuffix(".error") || msg.type == "error" {
                let message = msg.payload?["message"]?.stringValue ?? "Browser agent command failed"
                if let traceback = msg.payload?["traceback"]?.stringValue, !traceback.isEmpty {
                    let clipped = traceback.count > 2400 ? String(traceback.prefix(2400)) + "…" : traceback
                    AppLog.shared.log("BrowserUseWorker traceback: \n\(clipped)", level: .error)
                }
                req.continuation.resume(throwing: BrowserUseWorkerError.commandFailed(message))
            } else {
                req.continuation.resume(returning: msg)
            }
        }
    }

    private func sendCommand(
        type: String,
        payload: [String: JSONValue],
        onEvent: (@Sendable (BrowserUseWorkerMessage) -> Void)? = nil
    ) async throws -> BrowserUseWorkerMessage {
        guard isRunning else { throw BrowserUseWorkerError.processNotRunning }
        guard let stdinHandle else { throw BrowserUseWorkerError.processNotRunning }

        try await waitForReady(timeoutSeconds: 3.0)

        let id = UUID().uuidString
        let cmd: [String: Any] = [
            "id": id,
            "type": type,
            "payload": payload.mapValues { $0.toAny() },
        ]

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrowserUseWorkerMessage, Error>) in
            let req = PendingRequest(id: id, onEvent: onEvent, continuation: continuation)
            pending[id] = req

            do {
                let data = try JSONSerialization.data(withJSONObject: cmd, options: [])
                stdinHandle.write(data)
                stdinHandle.write("\n".data(using: .utf8)!)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func waitForReady(timeoutSeconds: Double) async throws {
        if isReady { return }
        guard isRunning else { throw BrowserUseWorkerError.processNotRunning }

        let waiterId = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyWaiters.append(ReadyWaiter(id: waiterId, continuation: continuation))
            Task { [weak self] in
                let nanos = UInt64(max(0.2, timeoutSeconds) * 1_000_000_000.0)
                try? await Task.sleep(nanoseconds: nanos)
                await self?.failReadyWaiterIfNeeded(id: waiterId)
            }
        }
    }

    private func failReadyWaiterIfNeeded(id: UUID) {
        guard !isReady else { return }
        guard let index = readyWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = readyWaiters.remove(at: index)
        waiter.continuation.resume(
            throwing: BrowserUseWorkerError.commandFailed("Browser worker failed to start. Check Settings → Browser agent Python.")
        )
    }

    func openBrowser(
        browserUseApiKey: String?,
        userDataDir: URL,
        keepSession: Bool,
        chromeExecutablePath: String? = nil,
        profileDirectory: String? = nil,
        chromeArgs: [String] = [],
        windowSize: CGSize = CGSize(width: 1200, height: 800)
    ) async throws {
        // Only configure the Browser Use key when it is actually set.
        let trimmedKey = (browserUseApiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try await startIfNeeded(browserUseApiKey: trimmedKey.isEmpty ? nil : trimmedKey)

        let normalizedExecutablePath: String? = {
            let trimmed = (chromeExecutablePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        let normalizedProfileDirectory: String? = {
            let trimmed = (profileDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        let normalizedArgs = chromeArgs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let shouldRestartBrowser: Bool = {
            if let currentUserDataDir, currentUserDataDir != userDataDir.path { return true }
            if currentChromeExecutablePath != normalizedExecutablePath { return true }
            if currentProfileDirectory != normalizedProfileDirectory { return true }
            if currentChromeArgs != normalizedArgs { return true }
            return false
        }()

        if shouldRestartBrowser, currentUserDataDir != nil {
            // Close the existing browser so we can reopen with the new config.
            // Keep the worker process alive for performance.
            do {
                try await closeBrowser()
            } catch {
                AppLog.shared.log("BrowserUseWorker: failed closing previous browser: \(error)", level: .error)
            }
        } else if !keepSession,
                  let currentUserDataDir,
                  currentUserDataDir != userDataDir.path {
            // Session isolation requested (legacy behavior).
            do {
                try await closeBrowser()
            } catch {
                AppLog.shared.log("BrowserUseWorker: failed closing previous browser: \(error)", level: .error)
            }
        }

        _ = try await sendCommand(
            type: "open_browser",
            payload: [
                "user_data_dir": .string(userDataDir.path),
                "headless": .bool(false),
                "window_size": .object([
                    "width": .number(Double(windowSize.width)),
                    "height": .number(Double(windowSize.height)),
                ]),
                "chrome_executable_path": normalizedExecutablePath.map { .string($0) } ?? .null,
                "profile_directory": normalizedProfileDirectory.map { .string($0) } ?? .null,
                "chrome_args": .array(normalizedArgs.map { .string($0) }),
            ]
        )
        currentUserDataDir = userDataDir.path
        currentChromeExecutablePath = normalizedExecutablePath
        currentProfileDirectory = normalizedProfileDirectory
        currentChromeArgs = normalizedArgs
    }

    func runTask(
        browserUseApiKey: String?,
        userDataDir: URL,
        keepSession: Bool,
        chromeExecutablePath: String? = nil,
        profileDirectory: String? = nil,
        chromeArgs: [String] = [],
        browserUseModel: String = "bu-2-0",
        useBrowserUseLlm: Bool,
        openAiApiKey: String?,
        openAiBaseUrl: String?,
        openAiModel: String?,
        task: String,
        maxSteps: Int? = 25,
        onEvent: (@Sendable (BrowserUseEvent) -> Void)? = nil
    ) async throws -> String {
        try await openBrowser(
            browserUseApiKey: browserUseApiKey,
            userDataDir: userDataDir,
            keepSession: keepSession,
            chromeExecutablePath: chromeExecutablePath,
            profileDirectory: profileDirectory,
            chromeArgs: chromeArgs
        )

        let response = try await sendCommand(
            type: "run_task",
            payload: [
                "task": .string(task),
                "max_steps": maxSteps.map { .number(Double($0)) } ?? .null,
                "use_browser_use_llm": .bool(useBrowserUseLlm),
                "browser_use_model": .string(browserUseModel),
                "openai_api_key": openAiApiKey.map { .string($0) } ?? .null,
                "openai_base_url": openAiBaseUrl.map { .string($0) } ?? .null,
                "openai_model": openAiModel.map { .string($0) } ?? .null,
                "headless": .bool(false),
                "window_size": .object([
                    "width": .number(1200),
                    "height": .number(800),
                ]),
            ],
            onEvent: { msg in
                guard msg.type == "run_task.event" else { return }
                let payload = msg.payload ?? [:]
                let event = payload["event"]?.stringValue ?? "event"
                let step = payload["step"]?.intValue
                let url = payload["url"]?.stringValue
                let title = payload["title"]?.stringValue
                let memory = payload["memory"]?.stringValue
                let text = payload["text"]?.stringValue
                let screenshotPath = payload["path"]?.stringValue
                let screenshotThumbPath = payload["thumb_path"]?.stringValue

                let actions: [JSONValue]? = {
                    guard let value = payload["actions"] else { return nil }
                    if case .array(let items) = value {
                        return items
                    }
                    return nil
                }()

                func summarizeAction(_ action: JSONValue) -> String? {
                    guard case .object(let obj) = action else { return nil }
                    guard let (name, value) = obj.first else { return nil }
                    if case .object(let params) = value {
                        if let url = params["url"]?.stringValue {
                            return "\(name): \(url)"
                        }
                        if let text = params["text"]?.stringValue {
                            let clipped = text.count > 60 ? String(text.prefix(60)) + "…" : text
                            return "\(name): \(clipped)"
                        }
                        if let index = params["index"]?.intValue {
                            return "\(name): index \(index)"
                        }
                        return name
                    }
                    return name
                }

                func summarizeActions(_ actions: [JSONValue]?) -> String? {
                    guard let actions else { return nil }
                    let parts = actions.compactMap(summarizeAction)
                    guard !parts.isEmpty else { return nil }
                    return parts.joined(separator: ", ")
                }

                var detailParts: [String] = []
                if let step { detailParts.append("Step \(step)") }

                switch event {
                case "step_start", "step_end":
                    if let title, !title.isEmpty { detailParts.append(title) }
                    if let url, !url.isEmpty { detailParts.append(url) }

                case "model_output":
                    if let actionsSummary = summarizeActions(actions) {
                        detailParts.append(actionsSummary)
                    }

                case "action_result":
                    if let text, !text.isEmpty {
                        let clipped = text.count > 100 ? String(text.prefix(100)) + "…" : text
                        detailParts.append(clipped)
                    }

                case "screenshot":
                    detailParts.append("Screenshot")

                default:
                    break
                }

                let detail = detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
                onEvent?(
                    BrowserUseEvent(
                        event: event,
                        step: step,
                        url: url,
                        title: title,
                        memory: memory,
                        actions: actions,
                        text: text,
                        screenshotPath: screenshotPath,
                        screenshotThumbPath: screenshotThumbPath,
                        detail: detail
                    )
                )
            }
        )

        guard response.type == "run_task.ok" else {
            throw BrowserUseWorkerError.invalidWorkerResponse
        }
        return response.payload?["output"]?.stringValue ?? ""
    }

    func getTabContext(
        browserUseApiKey: String?,
        userDataDir: URL,
        keepSession: Bool,
        chromeExecutablePath: String? = nil,
        profileDirectory: String? = nil,
        chromeArgs: [String] = [],
        includeActiveText: Bool,
        maxChars: Int = 1800
    ) async throws -> BrowserTabContext {
        try await openBrowser(
            browserUseApiKey: browserUseApiKey,
            userDataDir: userDataDir,
            keepSession: keepSession,
            chromeExecutablePath: chromeExecutablePath,
            profileDirectory: profileDirectory,
            chromeArgs: chromeArgs
        )

        let response = try await sendCommand(
            type: "get_tab_context",
            payload: [
                "include_active_text": .bool(includeActiveText),
                "max_chars": .number(Double(maxChars)),
            ]
        )

        guard response.type == "get_tab_context.ok",
              let payload = response.payload else {
            throw BrowserUseWorkerError.invalidWorkerResponse
        }

        let tabs: [BrowserTab] = (payload["tabs"]?.arrayValue ?? []).compactMap { value in
            guard case .object(let obj) = value else { return nil }
            let index = obj["index"]?.intValue ?? 0
            let title = obj["title"]?.stringValue
            let url = obj["url"]?.stringValue
            return BrowserTab(index: index, title: title, url: url)
        }

        let activeIndex = payload["active_index"]?.intValue
        let excerpt = payload["active_text_excerpt"]?.stringValue

        return BrowserTabContext(tabs: tabs, activeIndex: activeIndex, activeTextExcerpt: excerpt)
    }

    func readTabText(index: Int, maxChars: Int = 4000) async throws -> String {
        let response = try await sendCommand(
            type: "read_tab_text",
            payload: [
                "index": .number(Double(index)),
                "max_chars": .number(Double(maxChars)),
            ]
        )

        guard response.type == "read_tab_text.ok" else {
            throw BrowserUseWorkerError.invalidWorkerResponse
        }
        return response.payload?["text"]?.stringValue ?? ""
    }

    func pause() async throws {
        _ = try await sendCommand(type: "pause", payload: [:])
    }

    func resume() async throws {
        _ = try await sendCommand(type: "resume", payload: [:])
    }

    func stop() async throws {
        _ = try await sendCommand(type: "stop", payload: [:])
    }

    func closeBrowser() async throws {
        defer {
            currentUserDataDir = nil
            currentChromeExecutablePath = nil
            currentProfileDirectory = nil
            currentChromeArgs = []
        }
        _ = try await sendCommand(type: "close_browser", payload: [:])
    }

    func closeAllWindows(keepSession: Bool) async throws {
        if !keepSession {
            currentUserDataDir = nil
        }
        _ = try await sendCommand(
            type: "close_all_windows",
            payload: [
                "keep_session": .bool(keepSession)
            ]
        )
    }
}

private extension JSONValue {
    func toAny() -> Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.toAny() }
        case .array(let value):
            return value.map { $0.toAny() }
        case .null:
            return NSNull()
        }
    }
}
