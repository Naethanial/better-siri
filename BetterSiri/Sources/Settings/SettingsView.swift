import KeyboardShortcuts
import SwiftUI

enum BrowserType: String, CaseIterable, Identifiable {
    case chrome = "chrome"
    case arc = "arc"
    case edge = "edge"
    case brave = "brave"
    case chromium = "chromium"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .arc: return "Arc"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .chromium: return "Chromium"
        }
    }

    var defaultExecutablePath: String {
        switch self {
        case .chrome:
            return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        case .arc:
            return "/Applications/Arc.app/Contents/MacOS/Arc"
        case .edge:
            return "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
        case .brave:
            return "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        case .chromium:
            return "/Applications/Chromium.app/Contents/MacOS/Chromium"
        }
    }

    var defaultUserDataDir: String {
        switch self {
        case .chrome:
            return "~/Library/Application Support/BetterSiri/Chrome"
        case .arc:
            return "~/Library/Application Support/BetterSiri/Arc"
        case .edge:
            return "~/Library/Application Support/BetterSiri/Edge"
        case .brave:
            return "~/Library/Application Support/BetterSiri/Brave"
        case .chromium:
            return "~/Library/Application Support/BetterSiri/Chromium"
        }
    }
}

struct SettingsView: View {
    @AppStorage("openrouter_apiKey") private var apiKey: String = ""
    @AppStorage("openrouter_model") private var model: String = "google/gemini-3-flash-preview"
    @AppStorage("openrouter_reasoning_effort") private var reasoningEffortRaw: String = "default"
    @AppStorage("openrouter_reasoning_effort_custom") private var reasoningEffortCustom: String = ""
    @AppStorage("perplexity_apiKey") private var perplexityApiKey: String = ""
    @AppStorage("appearance_mode") private var appearanceModeRaw: String = AppearanceMode.system
        .rawValue
    @AppStorage("show_thinking_traces") private var showThinkingTraces: Bool = true

    @AppStorage("browseruse_enabled") private var browserUseEnabled: Bool = false
    @AppStorage("browseruse_python") private var browserUsePython: String =
        "~/.bettersiri-browseruse-venv/bin/python"
    @AppStorage("browseruse_browser_type") private var browserTypeRaw: String = BrowserType.chrome
        .rawValue
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

    @State private var browserWindowStatus: String = ""

    private var browserType: Binding<BrowserType> {
        Binding(
            get: { BrowserType(rawValue: browserTypeRaw) ?? .chrome },
            set: { newType in
                browserTypeRaw = newType.rawValue
                // Update paths when browser type changes
                browserUseChromeExecutablePath = newType.defaultExecutablePath
                browserUseChromeUserDataDir = newType.defaultUserDataDir
            }
        )
    }

    private var appearanceMode: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceModeRaw) ?? .system },
            set: { appearanceModeRaw = $0.rawValue }
        )
    }

    private var reasoningEffort: Binding<OpenRouterReasoningEffort> {
        Binding(
            get: { OpenRouterReasoningEffort(rawValue: reasoningEffortRaw) ?? .default },
            set: { reasoningEffortRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mode", selection: appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show thinking traces", isOn: $showThinkingTraces)
            }

            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Toggle Assistant:", name: .togglePanel)
            }

            Section("OpenRouter") {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                TextField("Model", text: $model)
                    .textFieldStyle(.roundedBorder)

                Picker("Thinking level", selection: reasoningEffort) {
                    ForEach(OpenRouterReasoningEffort.allCases) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
                .pickerStyle(.menu)

                TextField("Thinking level (custom)", text: $reasoningEffortCustom)
                    .textFieldStyle(.roundedBorder)

                Text(
                    "Example models: google/gemini-3-flash-preview, anthropic/claude-sonnet-4, openai/gpt-4o"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Perplexity (Web Search)") {
                SecureField("API Key", text: $perplexityApiKey)
                    .textFieldStyle(.roundedBorder)

                Text(
                    "Optional: Enables web search context for more up-to-date responses. Get a key at perplexity.ai"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Browser Agent (browser-use)") {
                Toggle("Enable browser agent", isOn: $browserUseEnabled)
                Toggle("Auto-detect browser tasks", isOn: $browserUseAutoInvoke)
                Toggle("Keep browser open between tasks", isOn: $browserUseKeepBrowserOpen)
                Toggle("Attach to existing browser (don't launch)", isOn: $browserUseAttachOnly)

                Picker("Browser", selection: browserType) {
                    ForEach(BrowserType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.menu)

                Stepper(
                    "Remote debugging port: \(browserUseRemoteDebuggingPort)",
                    value: $browserUseRemoteDebuggingPort,
                    in: 1025...65535
                )

                HStack(spacing: 8) {
                    Button("Open Browser") {
                        browserWindowStatus = "Starting browser window..."
                        Task {
                            do {
                                _ = try await ChromeRemoteDebuggingService.shared.ensureAvailable(
                                    chromeExecutablePath: browserUseChromeExecutablePath,
                                    chromeUserDataDir: browserUseChromeUserDataDir,
                                    chromeProfileDirectory: browserUseChromeProfileDirectory,
                                    remoteDebuggingPort: browserUseRemoteDebuggingPort,
                                    launchIfNeeded: true
                                )
                                browserWindowStatus = "Browser window ready."
                            } catch {
                                browserWindowStatus =
                                    "Browser start failed: \(error.localizedDescription)"
                            }
                        }
                    }

                    Button("Stop Browser") {
                        browserWindowStatus = "Stopping browser window..."
                        Task {
                            await ChromeRemoteDebuggingService.shared.stop()
                            browserWindowStatus = "Browser window stopped."
                        }
                    }
                }

                if !browserWindowStatus.isEmpty {
                    Text(browserWindowStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Python command", text: $browserUsePython)
                    .textFieldStyle(.roundedBorder)

                TextField("Browser executable path", text: $browserUseChromeExecutablePath)
                    .textFieldStyle(.roundedBorder)

                TextField("Browser user data dir", text: $browserUseChromeUserDataDir)
                    .textFieldStyle(.roundedBorder)

                TextField("Browser profile directory", text: $browserUseChromeProfileDirectory)
                    .textFieldStyle(.roundedBorder)

                Stepper("Max steps: \(browserUseMaxSteps)", value: $browserUseMaxSteps, in: 1...200)

                Toggle("Headless", isOn: $browserUseHeadless)
                Toggle("Use vision", isOn: $browserUseUseVision)

                Text("Use in chat: ask normally, or force with `/browser <task>`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    "Note: Chromium-based browsers require a non-default user data dir for DevTools remote debugging. BetterSiri uses a dedicated automation profile; sign into sites inside that window if needed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("About") {
                Text("Better Siri - AI Assistant")
                    .font(.headline)
                Text(
                    "Press the hotkey to capture your screen and ask questions about what you see."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .padding()
    }
}

#Preview {
    SettingsView()
}
