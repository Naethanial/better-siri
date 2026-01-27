import SwiftUI
import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    @AppStorage("openrouter_apiKey") private var apiKey: String = ""
    @AppStorage("browser_use_apiKey") private var browserUseApiKey: String = ""
    @AppStorage("browser_agent_pythonPath") private var browserAgentPythonPath: String = ""
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

    @AppStorage("perplexity_apiKey") private var perplexityApiKey: String = ""
    @AppStorage("appearance_mode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage("gemini_enableUrlContext") private var geminiEnableUrlContext: Bool = true
    @AppStorage("gemini_enableCodeExecution") private var geminiEnableCodeExecution: Bool = true

    private var appearanceMode: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceModeRaw) ?? .system },
            set: { appearanceModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        List {
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

                Toggle("Keep browser session alive", isOn: $browserAgentKeepSession)

                Button("Close All Windows") {
                    Task {
                        try? await BrowserUseWorker.shared.closeAllWindows(keepSession: browserAgentKeepSession)
                    }
                }

                Button("Close Agent Browser") {
                    Task {
                        try? await BrowserUseWorker.shared.closeBrowser()
                        await BrowserUseWorker.shared.stopProcess()
                    }
                }

                Text("Leave blank to use python3 from PATH. If browser mode fails, ensure the selected Python has browser-use installed (pip install browser-use) and browsers installed (uvx browser-use install), or point this at a virtualenv python (e.g. .../.venv/bin/python).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Optional: Enables Browser Use Cloud's ChatBrowserUse model for fast browser automation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OnShape") {
                Toggle("Enable OnShape", isOn: $onshapeEnabled)

                SecureField("Access Key", text: $onshapeApiKey)
                    .textFieldStyle(.roundedBorder)

                SecureField("Secret Key", text: $onshapeSecretKey)
                    .textFieldStyle(.roundedBorder)

                TextField("Base URL", text: $onshapeBaseUrl)
                    .textFieldStyle(.roundedBorder)

                TextField("API Version", text: $onshapeApiVersion)
                    .textFieldStyle(.roundedBorder)

                TextField("OnShape agent Python", text: $onshapeAgentPythonPath)
                    .textFieldStyle(.roundedBorder)

                Divider()

                TextField("OAuth Base URL", text: $onshapeOauthBaseUrl)
                    .textFieldStyle(.roundedBorder)

                SecureField("OAuth Client ID", text: $onshapeOauthClientId)
                    .textFieldStyle(.roundedBorder)

                SecureField("OAuth Client Secret", text: $onshapeOauthClientSecret)
                    .textFieldStyle(.roundedBorder)

                Stepper("OAuth Redirect Port: \(onshapeOauthRedirectPort)", value: $onshapeOauthRedirectPort, in: 1024...65535)

                Button("Authorize OnShape (OAuth)") {
                    Task {
                        do {
                            let tokenFileURL = OnShapeOAuthService.defaultTokenFileURL()
                            try await OnShapeOAuthService.shared.authorize(
                                oauthBaseURL: onshapeOauthBaseUrl,
                                clientId: onshapeOauthClientId,
                                clientSecret: onshapeOauthClientSecret,
                                redirectPort: onshapeOauthRedirectPort,
                                scopes: ["OAuth2Read", "OAuth2Write"],
                                tokenFileURL: tokenFileURL
                            )
                        } catch {
                            AppLog.shared.log("OnShape OAuth failed: \(error)", level: .error)
                        }
                    }
                }

                Button(role: .destructive) {
                    Task {
                        do {
                            try await OnShapeOAuthService.shared.clearTokenFile()
                        } catch {
                            AppLog.shared.log("Clear OnShape OAuth token failed: \(error)", level: .error)
                        }
                    }
                } label: {
                    Text("Clear OAuth Token")
                }

                Button("Ping OnShape Agent") {
                    Task {
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
                                oauthTokenFilePath: OnShapeOAuthService.defaultTokenFileURL().path
                            )
                            try await OnShapeMcpWorker.shared.ping()
                        } catch {
                            AppLog.shared.log("OnShape agent ping failed: \(error)", level: .error)
                        }
                    }
                }

                Button("Stop OnShape Agent") {
                    Task {
                        await OnShapeMcpWorker.shared.stopProcess()
                    }
                }

                Text("If API keys are disabled (common for EDU accounts), use OAuth instead. For your district stack, Base URL should be like https://cteinccsd.onshape.com/api. OAuth Base URL may need to be https://cteinccsd.onshape.com (or https://oauth.onshape.com depending on your tenant).")
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
        .listStyle(.inset)
        .frame(width: 520, height: 520)
        .padding()
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppCoordinator())
}
