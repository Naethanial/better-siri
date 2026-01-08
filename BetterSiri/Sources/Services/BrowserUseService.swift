import Darwin
import Foundation

enum BrowserUseError: Error, LocalizedError {
    case missingOpenRouterApiKey
    case invalidConfiguration(String)
    case failedToWriteRunner(String)
    case processExitedNonZero(Int32)

    var errorDescription: String? {
        switch self {
        case .missingOpenRouterApiKey:
            return "OpenRouter API key is missing."
        case .invalidConfiguration(let message):
            return message
        case .failedToWriteRunner(let message):
            return "Failed to prepare browser-use runner: \(message)"
        case .processExitedNonZero(let code):
            return "browser-use runner exited with code \(code)."
        }
    }
}

actor BrowserUseService {
    private static let runnerFileName = "browser_use_runner.py"
    private var currentProcess: Process?

    private static let runnerScript = """
        import argparse
        import asyncio
        import json
        import os
        import sys

        OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"


        def _expand(path: str) -> str:
            return os.path.expanduser(path)


        async def run() -> int:
            parser = argparse.ArgumentParser()
            parser.add_argument("--task", required=True)
            parser.add_argument("--model", required=True)
            parser.add_argument("--api-key", required=False)

            parser.add_argument("--cdp-url", required=True)

            parser.add_argument("--max-steps", type=int, default=50)
            parser.add_argument("--use-vision", action=argparse.BooleanOptionalAction, default=True)

            args = parser.parse_args()

            api_key = args.api_key or os.getenv("OPENROUTER_API_KEY")
            if not api_key:
                print("ERROR: OPENROUTER_API_KEY is not set", flush=True)
                return 2

            try:
                from browser_use import Agent, Browser, ChatOpenAI
            except Exception as e:
                print("ERROR: browser-use is not installed in this Python environment.", flush=True)
                print(str(e), flush=True)
                return 3

            llm = ChatOpenAI(
                model=args.model,
                base_url=OPENROUTER_BASE_URL,
                api_key=api_key,
            )

            browser = Browser(cdp_url=args.cdp_url)

            agent = Agent(
                task=args.task,
                llm=llm,
                browser=browser,
                use_vision=args.use_vision,
            )

            real_stdout = sys.stdout
            sys.stdout = sys.stderr

            history = await agent.run(max_steps=args.max_steps)
            result = history.final_result() or "Done."

            sys.stdout = real_stdout
            payload = {"final": str(result)}
            print("BETTER_SIRI_FINAL_RESULT: " + json.dumps(payload), flush=True)
            return 0


        def main() -> None:
            raise SystemExit(asyncio.run(run()))


        if __name__ == "__main__":
            main()
        """

    private let fileManager: FileManager
    private let runnerURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseDir =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let runnerDir =
            baseDir
            .appendingPathComponent("BetterSiri", isDirectory: true)
            .appendingPathComponent("BrowserUse", isDirectory: true)

        try? fileManager.createDirectory(at: runnerDir, withIntermediateDirectories: true)
        self.runnerURL = runnerDir.appendingPathComponent(Self.runnerFileName)
    }

    func runAgent(
        task: String,
        pythonCommand: String,
        cdpURL: String,
        openRouterApiKey: String,
        openRouterModel: String,
        maxSteps: Int,
        useVision: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard !openRouterApiKey.isEmpty else {
                        throw BrowserUseError.missingOpenRouterApiKey
                    }

                    let trimmedCDPURL = cdpURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedCDPURL.isEmpty else {
                        throw BrowserUseError.invalidConfiguration("CDP URL is missing.")
                    }

                    try Self.ensureRunnerScript(at: runnerURL)

                    let process = Process()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    var environment = ProcessInfo.processInfo.environment
                    environment["OPENROUTER_API_KEY"] = openRouterApiKey
                    environment["NO_COLOR"] = "1"
                    environment["PYTHONUNBUFFERED"] = "1"
                    environment["TERM"] = "dumb"
                    process.environment = environment

                    let resolvedPythonCommand = Self.expandTilde(pythonCommand)
                    if resolvedPythonCommand.contains("/") {
                        process.executableURL = URL(fileURLWithPath: resolvedPythonCommand)
                        process.arguments = Self.buildArguments(
                            runnerPath: runnerURL.path,
                            task: task,
                            model: openRouterModel,
                            maxSteps: maxSteps,
                            cdpURL: trimmedCDPURL,
                            useVision: useVision
                        )
                    } else {
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        process.arguments =
                            [resolvedPythonCommand]
                            + Self.buildArguments(
                                runnerPath: runnerURL.path,
                                task: task,
                                model: openRouterModel,
                                maxSteps: maxSteps,
                                cdpURL: trimmedCDPURL,
                                useVision: useVision
                            )
                    }

                    continuation.onTermination = { @Sendable _ in
                        if process.isRunning {
                            process.terminate()
                        }
                    }

                    currentProcess = process

                    try process.run()

                    async let stdoutTask: Void = streamLines(
                        from: stdoutPipe.fileHandleForReading,
                        prefix: "",
                        continuation: continuation
                    )
                    async let stderrTask: Void = streamLines(
                        from: stderrPipe.fileHandleForReading,
                        prefix: "[stderr] ",
                        continuation: continuation
                    )

                    let exitCode = await withCheckedContinuation {
                        (cont: CheckedContinuation<Int32, Never>) in
                        process.terminationHandler = { proc in
                            Task {
                                await self.clearCurrentProcess(proc)
                            }
                            cont.resume(returning: proc.terminationStatus)
                        }
                    }

                    _ = try await (stdoutTask, stderrTask)

                    if exitCode == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(
                            throwing: BrowserUseError.processExitedNonZero(exitCode))
                    }
                } catch {
                    currentProcess = nil
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func cancelCurrentRun() {
        guard let process = currentProcess, process.isRunning else { return }
        let pid = process.processIdentifier
        process.interrupt()
        process.terminate()

        guard pid > 0 else { return }
        Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if kill(pid, 0) == 0 {
                _ = kill(pid, SIGKILL)
            }
        }
    }

    private func clearCurrentProcess(_ process: Process) {
        guard currentProcess === process else { return }
        currentProcess = nil
    }

    private static func ensureRunnerScript(at url: URL) throws {
        let data = Data(runnerScript.utf8)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw BrowserUseError.failedToWriteRunner(error.localizedDescription)
        }
    }

    private static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func buildArguments(
        runnerPath: String,
        task: String,
        model: String,
        maxSteps: Int,
        cdpURL: String,
        useVision: Bool
    ) -> [String] {
        [
            "-u",
            runnerPath,
            "--task",
            task,
            "--model",
            model,
            "--cdp-url",
            cdpURL,
            "--max-steps",
            String(maxSteps),
            useVision ? "--use-vision" : "--no-use-vision",
        ]
    }
}

private func streamLines(
    from handle: FileHandle,
    prefix: String,
    continuation: AsyncThrowingStream<String, Error>.Continuation
) async throws {
    for try await line in handle.bytes.lines {
        continuation.yield(prefix + stripANSI(line) + "\n")
    }
}

private let ansiEscapeRegex: NSRegularExpression = {
    // Matches common ANSI escape sequences like: \u{1B}[34m, \u{1B}[0m
    // This keeps chat output readable when CLI tools emit colored logs.
    let pattern = "\u{1B}\\[[0-9;]*[A-Za-z]"
    return (try? NSRegularExpression(pattern: pattern)) ?? (try! NSRegularExpression(pattern: "a^"))
}()

private func stripANSI(_ input: String) -> String {
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    return ansiEscapeRegex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
}
