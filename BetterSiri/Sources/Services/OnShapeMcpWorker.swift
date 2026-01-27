import Foundation

enum OnShapeMcpWorkerError: Error, LocalizedError {
    case resourceMissing(String)
    case processNotRunning
    case invalidWorkerResponse
    case jsonRpcError(String)
    case toolError(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "Missing OnShapeAgent resource: \(name)"
        case .processNotRunning:
            return "OnShape MCP server process is not running"
        case .invalidWorkerResponse:
            return "Invalid response from OnShape MCP server"
        case .jsonRpcError(let message):
            return message
        case .toolError(let message):
            return message
        }
    }
}

private struct McpJsonRpcError: Decodable {
    let code: Int
    let message: String
    let data: JSONValue?
}

private struct McpJsonRpcMessage: Decodable {
    let jsonrpc: String?
    let id: JSONValue?
    let method: String?
    let result: JSONValue?
    let error: McpJsonRpcError?

    var idString: String? {
        guard let id else { return nil }
        if case .string(let value) = id { return value }
        if case .number(let value) = id { return String(Int(value)) }
        return nil
    }
}

actor OnShapeMcpWorker {
    static let shared = OnShapeMcpWorker()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<McpJsonRpcMessage, Error>] = [:]
    private var isInitialized: Bool = false

    private var startedAccessKey: String?
    private var startedSecretKey: String?
    private var startedBaseURL: String?
    private var startedApiVersion: String?

    var isRunning: Bool {
        process?.isRunning == true
    }

    func startIfNeeded(
        accessKey: String?,
        secretKey: String?,
        baseURL: String?,
        apiVersion: String?,
        pythonPath: String?,
        oauthClientId: String? = nil,
        oauthClientSecret: String? = nil,
        oauthBaseURL: String? = nil,
        oauthTokenFilePath: String? = nil
    ) throws {
        if isRunning {
            let shouldRestart = startedAccessKey != accessKey
                || startedSecretKey != secretKey
                || startedBaseURL != baseURL
                || startedApiVersion != apiVersion

            if shouldRestart {
                stopProcess()
            } else {
                return
            }
        }

        guard let scriptURL = Bundle.module.url(forResource: "onshape_mcp_server", withExtension: "py") else {
            throw OnShapeMcpWorkerError.resourceMissing("Resources/OnShapeAgent/onshape_mcp_server.py")
        }

        let process = Process()

        let configuredPython = (pythonPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let envPython = (ProcessInfo.processInfo.environment["BETTERSIRI_ONSHAPE_AGENT_PYTHON"] ?? "")
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
        if let accessKey, !accessKey.isEmpty {
            env["ONSHAPE_ACCESS_KEY"] = accessKey
        }
        if let secretKey, !secretKey.isEmpty {
            env["ONSHAPE_SECRET_KEY"] = secretKey
        }
        if let baseURL, !baseURL.isEmpty {
            env["ONSHAPE_BASE_URL"] = baseURL
        }
        if let apiVersion, !apiVersion.isEmpty {
            env["ONSHAPE_API_VERSION"] = apiVersion
        }

        if let oauthClientId, !oauthClientId.isEmpty {
            env["ONSHAPE_OAUTH_CLIENT_ID"] = oauthClientId
        }
        if let oauthClientSecret, !oauthClientSecret.isEmpty {
            env["ONSHAPE_OAUTH_CLIENT_SECRET"] = oauthClientSecret
        }
        if let oauthBaseURL, !oauthBaseURL.isEmpty {
            env["ONSHAPE_OAUTH_BASE_URL"] = oauthBaseURL
        }
        if let oauthTokenFilePath, !oauthTokenFilePath.isEmpty {
            env["ONSHAPE_OAUTH_TOKEN_FILE"] = oauthTokenFilePath
        }
        process.environment = env

        startedAccessKey = accessKey
        startedSecretKey = secretKey
        startedBaseURL = baseURL
        startedApiVersion = apiVersion
        isInitialized = false

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
                let trimmed = text.count > 1600 ? String(text.prefix(1600)) + "…" : text
                AppLog.shared.log("OnShapeMcpWorker stderr: \(trimmed)", level: .debug)
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
        buffer = Data()
        isInitialized = false

        startedAccessKey = nil
        startedSecretKey = nil
        startedBaseURL = nil
        startedApiVersion = nil

        for (_, cont) in pending {
            cont.resume(throwing: OnShapeMcpWorkerError.processNotRunning)
        }
        pending.removeAll()
    }

    private func handleTermination(_ proc: Process) {
        AppLog.shared.log("OnShapeMcpWorker terminated (status: \(proc.terminationStatus))", level: .error)
        for (_, cont) in pending {
            cont.resume(throwing: OnShapeMcpWorkerError.processNotRunning)
        }
        pending.removeAll()
        process = nil
        isInitialized = false

        startedAccessKey = nil
        startedSecretKey = nil
        startedBaseURL = nil
        startedApiVersion = nil
    }

    private func handleStdout(_ data: Data) {
        buffer.append(data)
        while true {
            guard let range = buffer.firstRange(of: Data([0x0A])) else { break }
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { continue }

            guard let msgData = line.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(McpJsonRpcMessage.self, from: msgData) else {
                AppLog.shared.log("OnShapeMcpWorker: failed decoding line: \(line)", level: .error)
                continue
            }

            route(msg)
        }
    }

    private func route(_ msg: McpJsonRpcMessage) {
        if let err = msg.error {
            let message = "MCP error \(err.code): \(err.message)"
            if let id = msg.idString, let cont = pending.removeValue(forKey: id) {
                cont.resume(throwing: OnShapeMcpWorkerError.jsonRpcError(message))
            } else {
                AppLog.shared.log("OnShapeMcpWorker unhandled error: \(message)", level: .error)
            }
            return
        }

        guard let id = msg.idString, let cont = pending.removeValue(forKey: id) else {
            // Notifications or uncorrelated messages.
            if let method = msg.method {
                AppLog.shared.log("OnShapeMcpWorker notification: \(method)", level: .debug)
            }
            return
        }

        cont.resume(returning: msg)
    }

    private func sendRequest(method: String, params: [String: JSONValue]? = nil) async throws -> McpJsonRpcMessage {
        guard isRunning else { throw OnShapeMcpWorkerError.processNotRunning }
        guard let stdinHandle else { throw OnShapeMcpWorkerError.processNotRunning }

        let id = UUID().uuidString
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            obj["params"] = params.mapValues { $0.toAny() }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<McpJsonRpcMessage, Error>) in
            pending[id] = cont
            do {
                let data = try JSONSerialization.data(withJSONObject: obj, options: [])
                stdinHandle.write(data)
                stdinHandle.write("\n".data(using: .utf8)!)
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: [String: JSONValue]? = nil) throws {
        guard isRunning else { throw OnShapeMcpWorkerError.processNotRunning }
        guard let stdinHandle else { throw OnShapeMcpWorkerError.processNotRunning }

        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            obj["params"] = params.mapValues { $0.toAny() }
        }

        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        stdinHandle.write(data)
        stdinHandle.write("\n".data(using: .utf8)!)
    }

    private func ensureInitialized() async throws {
        guard isRunning else { throw OnShapeMcpWorkerError.processNotRunning }
        if isInitialized {
            return
        }

        let initializeResponse = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "clientInfo": .object([
                    "name": .string("BetterSiri"),
                    "version": .string("1.0")
                ]),
            ]
        )

        guard initializeResponse.result != nil else {
            throw OnShapeMcpWorkerError.invalidWorkerResponse
        }

        try sendNotification(method: "initialized")
        isInitialized = true
    }

    func ping() async throws {
        try await ensureInitialized()
        _ = try await sendRequest(method: "ping")
    }

    func callTool(name: String, arguments: [String: JSONValue]) async throws -> String {
        try await ensureInitialized()
        let msg = try await sendRequest(
            method: "tools/call",
            params: [
                "name": .string(name),
                "arguments": .object(arguments)
            ]
        )

        guard let result = msg.result, case .object(let obj) = result else {
            throw OnShapeMcpWorkerError.invalidWorkerResponse
        }

        let isError = obj["isError"]?.boolValue ?? false

        var text: String? = nil
        if let content = obj["content"], case .array(let items) = content {
            for item in items {
                guard case .object(let itemObj) = item else { continue }
                if itemObj["type"]?.stringValue == "text" {
                    text = itemObj["text"]?.stringValue
                    break
                }
            }
        }

        guard let text else {
            throw OnShapeMcpWorkerError.invalidWorkerResponse
        }

        if isError {
            throw OnShapeMcpWorkerError.toolError(text)
        }

        return text
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
