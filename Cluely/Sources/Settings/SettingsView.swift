import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @AppStorage("openrouter_apiKey") private var apiKey: String = ""
    @AppStorage("openrouter_model") private var model: String = "anthropic/claude-sonnet-4"
    
    var body: some View {
        Form {
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
            
            Section("About") {
                Text("Cluely - AI Assistant")
                    .font(.headline)
                Text("Press the hotkey to capture your screen and ask questions about what you see.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 300)
        .padding()
    }
}

#Preview {
    SettingsView()
}
