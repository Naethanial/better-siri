import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    @AppStorage("openrouter_apiKey") private var apiKey: String = ""
    @AppStorage("browser_use_apiKey") private var browserUseApiKey: String = ""
    @AppStorage("browser_agent_pythonPath") private var browserAgentPythonPath: String = ""
    @AppStorage("browser_agent_llmMode") private var browserAgentLlmMode: String = "auto"
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
    @AppStorage("perplexity_apiKey") private var perplexityApiKey: String = ""
    @AppStorage("appearance_mode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage("gemini_enableUrlContext") private var geminiEnableUrlContext: Bool = true
    @AppStorage("gemini_enableCodeExecution") private var geminiEnableCodeExecution: Bool = true
    @State private var availableProfiles: [ChromiumProfile] = []
    @State private var isLoadingProfiles: Bool = false
    @State private var profileLoadError: String?

    private var appearanceMode: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceModeRaw) ?? .system },
            set: { appearanceModeRaw = $0.rawValue }
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
            }

            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Toggle Assistant:", name: .togglePanel)
            }

            Section("Chats") {
                if coordinator.chatSessions.isEmpty {
                    Text("No saved chats yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.chatSessions) { session in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                    .lineLimit(1)
                                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 10)
                            Button("Open") {
                                coordinator.openSavedChat(session.id)
                            }
                            Button(role: .destructive) {
                                coordinator.deleteSavedChat(session.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button(role: .destructive) {
                        coordinator.clearSavedChats()
                    } label: {
                        Text("Clear Saved Chats")
                    }
                }
            }
            
            Section("OpenRouter") {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Text("Model is fixed to google/gemini-3-flash-preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Enable URL context", isOn: $geminiEnableUrlContext)
                Toggle("Enable code execution", isOn: $geminiEnableCodeExecution)
            }

            Section("Browser Use") {
                SecureField("API Key", text: $browserUseApiKey)
                    .textFieldStyle(.roundedBorder)

                TextField("Browser agent Python", text: $browserAgentPythonPath)
                    .textFieldStyle(.roundedBorder)

                Picker("Browser agent LLM", selection: $browserAgentLlmMode) {
                    Text("Auto").tag("auto")
                    Text("Browser Use Cloud").tag("browser_use_cloud")
                    Text("OpenRouter").tag("openrouter")
                }

                if browserAgentLlmMode == "browser_use_cloud" {
                    Text("Uses your Browser Use API key and the selected bu-* model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if browserAgentLlmMode == "openrouter" {
                    Text("Uses your OpenRouter API key for browser automation. Browser Use API key is optional in this mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Auto uses Browser Use Cloud if a Browser Use API key is set; otherwise it uses OpenRouter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Browser app", selection: $browserAgentBrowserAppId) {
                    ForEach(ChromiumBrowserAppId.allCases) { app in
                        Text(app.displayName).tag(app.rawValue)
                    }
                }

                if (ChromiumBrowserAppId(rawValue: browserAgentBrowserAppId) ?? .chrome) == .custom {
                    TextField("Custom executable path", text: $browserAgentCustomExecutablePath)
                        .textFieldStyle(.roundedBorder)
                }

                Picker("Profile root", selection: $browserAgentProfileRootMode) {
                    Text("Real browser profile").tag("real")
                    Text("App-managed profile").tag("app_managed")
                    Text("Custom path").tag("custom")
                }

                if browserAgentProfileRootMode == "custom" {
                    TextField("Custom user-data-dir", text: $browserAgentCustomUserDataDir)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 12) {
                    Picker("Profile", selection: $browserAgentProfileDirectory) {
                        ForEach(availableProfiles) { profile in
                            Text(profile.displayName).tag(profile.dirName)
                        }
                        if availableProfiles.isEmpty {
                            Text(browserAgentProfileDirectory.isEmpty ? "Default" : browserAgentProfileDirectory)
                                .tag(browserAgentProfileDirectory.isEmpty ? "Default" : browserAgentProfileDirectory)
                        }
                    }

                    Button(isLoadingProfiles ? "Refreshing…" : "Refresh") {
                        refreshProfiles()
                    }
                    .disabled(isLoadingProfiles)
                }

                if let error = profileLoadError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Auto-open DevTools", isOn: $browserAgentAutoOpenDevTools)

                Toggle("Include tab context in answers", isOn: $browserAgentIncludeTabContext)
                Toggle("Include active tab text", isOn: $browserAgentIncludeActiveTabText)
                    .disabled(!browserAgentIncludeTabContext)

                Picker("Browser Use model", selection: $browserUseCloudModel) {
                    Text("bu-2-0").tag("bu-2-0")
                    Text("bu-latest").tag("bu-latest")
                    Text("bu-1-0").tag("bu-1-0")
                }
                .disabled(browserAgentLlmMode == "openrouter")

                Toggle("Keep browser session alive", isOn: $browserAgentKeepSession)
                    .disabled(browserAgentProfileRootMode != "app_managed")

                if browserAgentProfileRootMode != "app_managed" {
                    Text("Session persistence is required when using real/custom browser profiles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Close All Windows") {
                    Task {
                        try? await BrowserUseWorker.shared.closeAllWindows(keepSession: browserAgentKeepSession)
                    }
                }

                Button("Restart Agent Browser") {
                    Task {
                        try? await BrowserUseWorker.shared.closeBrowser()
                        await BrowserUseWorker.shared.stopProcess()
                    }
                }

                Button("Close Agent Browser") {
                    Task {
                        try? await BrowserUseWorker.shared.closeBrowser()
                    }
                }

                Text("Leave blank to use python3 from PATH. If browser mode fails, ensure the selected Python has browser-use installed (pip install browser-use) and browsers installed (uvx browser-use install), or point this at a virtualenv python (e.g. .../.venv/bin/python).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Optional: Enables Browser Use Cloud's ChatBrowserUse model for fast browser automation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Perplexity (Web Search)") {
                SecureField("API Key", text: $perplexityApiKey)
                    .textFieldStyle(.roundedBorder)
                
                Text("Optional: Enables web search context for more up-to-date responses. Get a key at perplexity.ai")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("About") {
                Text("Better Siri - AI Assistant")
                    .font(.headline)
                Text("Press the hotkey to capture your screen and ask questions about what you see.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .padding()
        .task {
            refreshProfiles()
        }
        .onChange(of: browserAgentBrowserAppId) { _, _ in
            refreshProfiles()
        }
        .onChange(of: browserAgentProfileRootMode) { _, _ in
            refreshProfiles()
        }
        .onChange(of: browserAgentCustomUserDataDir) { _, _ in
            if browserAgentProfileRootMode == "custom" {
                refreshProfiles()
            }
        }
    }

    private func refreshProfiles() {
        profileLoadError = nil
        guard !isLoadingProfiles else { return }

        isLoadingProfiles = true

        Task {
            defer { isLoadingProfiles = false }

            do {
                let userDataDir = try resolveProfileRootURL()
                let profiles = await ChromiumProfileDiscovery.discoverProfiles(userDataDir: userDataDir)
                availableProfiles = profiles
            } catch {
                availableProfiles = []
                profileLoadError = error.localizedDescription
            }
        }
    }

    private func resolveProfileRootURL() throws -> URL {
        switch browserAgentProfileRootMode {
        case "custom":
            let trimmed = browserAgentCustomUserDataDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw NSError(domain: "BetterSiri", code: 1, userInfo: [NSLocalizedDescriptionKey: "Custom user-data-dir is empty"])
            }
            return URL(fileURLWithPath: trimmed, isDirectory: true)

        case "app_managed":
            let fileManager = FileManager.default
            let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory

            let dir = baseDir
                .appendingPathComponent("BetterSiri", isDirectory: true)
                .appendingPathComponent("BrowserAgentUserData", isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir

        default:
            let appId = ChromiumBrowserAppId(rawValue: browserAgentBrowserAppId) ?? .chrome
            return appId.defaultUserDataDirURL() ?? FileManager.default.temporaryDirectory
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppCoordinator())
}
