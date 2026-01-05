import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @AppStorage("openrouter_apiKey") private var apiKey: String = ""
    @AppStorage("openrouter_model") private var model: String = "anthropic/claude-sonnet-4"
    @AppStorage("perplexity_apiKey") private var perplexityApiKey: String = ""
    @AppStorage("appearance_mode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue

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
            
            Section("OpenRouter") {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                
                TextField("Model", text: $model)
                    .textFieldStyle(.roundedBorder)
                
                Text("Example models: anthropic/claude-sonnet-4, openai/gpt-4o, google/gemini-2.0-flash-exp")
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
        .frame(width: 450, height: 380)
        .padding()
    }
}

#Preview {
    SettingsView()
}
