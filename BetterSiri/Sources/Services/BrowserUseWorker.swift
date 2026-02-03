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

actor BrowserUseWorker {
    static let shared = BrowserUseWorker()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var buffer = Data()
    private var startedBrowserUseApiKey: String?
    private var currentUserDataDir: String?

    private struct PendingRequest {
        let id: String
        let onEvent: (@Sendable (BrowserUseWorkerMessage) -> Void)?
        let continuation: CheckedContinuation<BrowserUseWorkerMessage, Error>
    }

    private var pending: [String: PendingRequest] = [:]

    var isRunning: Bool {
        process?.isRunning == true
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

    func startIfNeeded(browserUseApiKey: String?) throws {
        if isRunning {
            // If the user added/changed the API key after startup, restart the worker
            // so the env var is updated.
            if let browserUseApiKey, !browserUseApiKey.isEmpty, startedBrowserUseApiKey != browserUseApiKey {
                stopProcess()
            } else {
                return
            }
        }

        let scriptURL = try resolveWorkerScriptURL()

        let process = Process()

        let configuredPython = (UserDefaults.standard.string(forKey: "browser_agent_pythonPath") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envPython = (ProcessInfo.processInfo.environment["BETTERSIRI_BROWSER_AGENT_PYTHON"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !configuredPython.isEmpty {
            process.executableURL = URL(fileURLWithPath: configuredPython)
            process.arguments = ["-u", scriptURL.path]
        } else if !envPython.isEmpty {
            process.executableURL = URL(fileURLWithPath: envPython)
            process.arguments = ["-u", scriptURL.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", scriptURL.path]
        }

        var env = ProcessInfo.processInfo.environment
        if let browserUseApiKey, !browserUseApiKey.isEmpty {
            env["BROWSER_USE_API_KEY"] = browserUseApiKey
        }
        process.environment = env

        startedBrowserUseApiKey = browserUseApiKey

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        self.process = process
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
        currentUserDataDir = nil
    }

    private func handleTermination(_ proc: Process) {
        AppLog.shared.log("BrowserUseWorker terminated (status: \(proc.terminationStatus))", level: .error)
        for (_, req) in pending {
            req.continuation.resume(throwing: BrowserUseWorkerError.processNotRunning)
        }
        pending.removeAll()
        process = nil
        startedBrowserUseApiKey = nil
        currentUserDataDir = nil
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

    func openBrowser(
        browserUseApiKey: String?,
        userDataDir: URL,
        keepSession: Bool,
        windowSize: CGSize = CGSize(width: 1200, height: 800)
    ) async throws {
        try startIfNeeded(browserUseApiKey: browserUseApiKey)
        if !keepSession,
           let currentUserDataDir,
           currentUserDataDir != userDataDir.path {
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
            ]
        )
        currentUserDataDir = userDataDir.path
    }

    func runTask(
        browserUseApiKey: String?,
        userDataDir: URL,
        keepSession: Bool,
        task: String,
        maxSteps: Int? = 25,
        onEvent: (@Sendable (BrowserUseEvent) -> Void)? = nil
    ) async throws -> String {
        try await openBrowser(
            browserUseApiKey: browserUseApiKey,
            userDataDir: userDataDir,
            keepSession: keepSession
        )

        let response = try await sendCommand(
            type: "run_task",
            payload: [
                "task": .string(task),
                "max_steps": maxSteps.map { .number(Double($0)) } ?? .null,
                "use_browser_use_llm": .bool(true),
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
        defer { currentUserDataDir = nil }
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
