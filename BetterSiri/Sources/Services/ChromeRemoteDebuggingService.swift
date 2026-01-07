import Foundation

enum ChromeRemoteDebuggingError: Error, LocalizedError {
    case invalidPort(Int)
    case chromeNotFound(String)
    case chromeLaunchFailed(String)
    case remoteDebuggingRequiresNonDefaultUserDataDir(String)
    case remoteDebuggingUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid remote debugging port: \(port)"
        case .chromeNotFound(let path):
            return "Chrome executable not found at \(path)"
        case .chromeLaunchFailed(let message):
            return "Failed to launch Chrome: \(message)"
        case .remoteDebuggingRequiresNonDefaultUserDataDir(let path):
            return
                "Chrome blocks DevTools remote debugging when using its default profile directory. Set a non-default Chrome user data dir (for example: `~/Library/Application Support/BetterSiri/Chrome`). Current: \(path)"
        case .remoteDebuggingUnavailable(let port):
            return
                "No Chrome remote debugging endpoint found on port \(port). Start the Browser Window from Settings, or restart Chrome with `--remote-debugging-port=\(port)`."
        }
    }
}

actor ChromeRemoteDebuggingService {
    static let shared = ChromeRemoteDebuggingService()

    private var chromeProcess: Process?

    func ensureAvailable(
        chromeExecutablePath: String,
        chromeUserDataDir: String,
        chromeProfileDirectory: String,
        remoteDebuggingPort: Int,
        launchIfNeeded: Bool
    ) async throws -> String {
        guard (1025...65535).contains(remoteDebuggingPort) else {
            throw ChromeRemoteDebuggingError.invalidPort(remoteDebuggingPort)
        }

        let baseURL = URL(string: "http://127.0.0.1:\(remoteDebuggingPort)")!
        let versionURL = baseURL.appendingPathComponent("json/version")

        if await isCDPAvailable(at: versionURL) {
            return baseURL.absoluteString
        }

        let resolvedUserDataDir = expandTilde(
            chromeUserDataDir.trimmingCharacters(in: .whitespacesAndNewlines))
        if isDefaultChromeUserDataDir(resolvedUserDataDir) {
            throw ChromeRemoteDebuggingError.remoteDebuggingRequiresNonDefaultUserDataDir(
                resolvedUserDataDir)
        }

        guard launchIfNeeded else {
            throw ChromeRemoteDebuggingError.remoteDebuggingUnavailable(remoteDebuggingPort)
        }

        if let existing = chromeProcess, existing.isRunning {
            // We started Chrome but it isn't ready yet; fall through to waiting.
        } else {
            let resolvedChromePath = expandTilde(chromeExecutablePath)
            guard FileManager.default.isExecutableFile(atPath: resolvedChromePath) else {
                throw ChromeRemoteDebuggingError.chromeNotFound(resolvedChromePath)
            }

            do {
                try FileManager.default.createDirectory(
                    atPath: resolvedUserDataDir, withIntermediateDirectories: true)
            } catch {
                throw ChromeRemoteDebuggingError.chromeLaunchFailed(
                    "Failed to create user data directory: \(error.localizedDescription)")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedChromePath)
            process.arguments = [
                "--remote-debugging-port=\(remoteDebuggingPort)",
                "--remote-debugging-address=127.0.0.1",
                "--user-data-dir=\(resolvedUserDataDir)",
                "--profile-directory=\(chromeProfileDirectory)",
                "--no-first-run",
                "--no-default-browser-check",
            ]

            process.standardOutput = Pipe()
            process.standardError = Pipe()

            process.terminationHandler = { [weak self] _ in
                Task { await self?.clearChromeProcessIfNeeded() }
            }

            do {
                try process.run()
            } catch {
                throw ChromeRemoteDebuggingError.chromeLaunchFailed(error.localizedDescription)
            }

            chromeProcess = process
        }

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try Task.checkCancellation()
            if let process = chromeProcess, !process.isRunning {
                throw ChromeRemoteDebuggingError.chromeLaunchFailed(
                    "Chrome exited before remote debugging became available.")
            }
            if await isCDPAvailable(at: versionURL) {
                return baseURL.absoluteString
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw ChromeRemoteDebuggingError.remoteDebuggingUnavailable(remoteDebuggingPort)
    }

    func stop() {
        guard let process = chromeProcess else { return }
        if process.isRunning {
            process.terminate()
        }
        chromeProcess = nil
    }

    private func isCDPAvailable(at url: URL) async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200
            else {
                return false
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return json["webSocketDebuggerUrl"] != nil
        } catch {
            return false
        }
    }

    private func clearChromeProcessIfNeeded() {
        guard let process = chromeProcess, !process.isRunning else { return }
        chromeProcess = nil
    }

    private func isDefaultChromeUserDataDir(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let defaultPath = URL(
            fileURLWithPath: expandTilde("~/Library/Application Support/Google/Chrome")
        ).standardizedFileURL.path
        return standardized == defaultPath
    }

    private func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
