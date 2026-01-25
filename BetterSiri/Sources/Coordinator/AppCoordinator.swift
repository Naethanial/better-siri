import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
class AppCoordinator: ObservableObject {
    @Published var isPanelOpen = false
    @Published var isCapturing = false

    @Published private(set) var chatSessions: [ChatSession] = []

    private var activeChatSessionId: UUID?
    private let chatHistoryKey = "chat_history_v1"
    private let maxSavedChats = 30

    private let screenCaptureService = ScreenCaptureService()
    private let panelController = FloatingPanelController()
    private var chatViewModel: ChatViewModel?
    private var chatBindings = Set<AnyCancellable>()

    init() {
        loadChatHistory()

        // Set up panel close callback
        panelController.onClose = { [weak self] in
            guard let self else { return }

            // Stop any in-flight browser automation immediately, but keep the
            // browser window/session alive for faster subsequent runs.
            Task {
                try? await BrowserUseWorker.shared.stop()
            }

            self.chatViewModel?.cancelStreaming()
            self.persistActiveChatIfNeeded()
            self.chatBindings.removeAll()

            self.isPanelOpen = false
            self.chatViewModel = nil
            self.activeChatSessionId = nil
            AppLog.shared.log("Panel closed")
        }
        AppLog.shared.log("App coordinator initialized")
    }

    func togglePanel() {
        // Always open/refresh when the shortcut is pressed
        openPanel(restoring: nil)
    }

    func closePanel() {
        panelController.close()
        AppLog.shared.log("Panel close requested")
    }

    func openSavedChat(_ id: UUID) {
        guard let session = chatSessions.first(where: { $0.id == id }) else { return }
        openPanel(restoring: session)
    }

    func deleteSavedChat(_ id: UUID) {
        chatSessions.removeAll(where: { $0.id == id })
        saveChatHistory()
    }

    func clearSavedChats() {
        chatSessions.removeAll()
        saveChatHistory()
    }

    private func openPanel(restoring session: ChatSession?) {
        guard !isCapturing else { return }

        isCapturing = true
        AppLog.shared.log("Panel open requested")

        Task {
            do {
                // Capture the screen first
                let screenshot = try await screenCaptureService.captureDisplayUnderCursor()
                AppLog.shared.log("Screen captured")

                let sessionId = session?.id ?? UUID()

                // Create the chat view model with the screenshot
                let viewModel = ChatViewModel(screenshot: screenshot, chatSessionId: sessionId)

                if let session {
                    viewModel.messages = session.messages
                    viewModel.hasSentFirstMessage = !session.messages.isEmpty
                }

                self.activeChatSessionId = sessionId

                self.chatViewModel = viewModel
                self.bindChatViewModel(viewModel)

                // Get cursor position for panel placement
                let cursorPosition = NSEvent.mouseLocation

                // Get the screen containing the cursor
                let screen = NSScreen.screens.first { $0.frame.contains(cursorPosition) } ?? NSScreen.main!

                // Show the panel
                panelController.show(
                    at: cursorPosition,
                    on: screen,
                    viewModel: viewModel
                )

                isPanelOpen = true
                isCapturing = false
                AppLog.shared.log("Panel opened")

            } catch ScreenCaptureError.permissionDenied {
                isCapturing = false
                AppLog.shared.log("Screen capture permission denied", level: .error)
                showPermissionAlert()
            } catch {
                isCapturing = false
                AppLog.shared.log("Screen capture failed: \(error)", level: .error)
            }
        }
    }

    private func persistActiveChatIfNeeded() {
        guard let id = activeChatSessionId else { return }
        guard let chatViewModel else { return }

        let trimmedMessages = chatViewModel.messages
            .map { msg in
                ChatMessage(id: msg.id, role: msg.role, content: msg.content, timestamp: msg.timestamp)
            }
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard trimmedMessages.contains(where: { $0.role == .user }) else { return }

        let now = Date()
        let title = makeChatTitle(from: trimmedMessages)

        if let existingIndex = chatSessions.firstIndex(where: { $0.id == id }) {
            chatSessions[existingIndex].title = title
            chatSessions[existingIndex].messages = trimmedMessages
            chatSessions[existingIndex].updatedAt = now
        } else {
            let session = ChatSession(
                id: id,
                title: title,
                createdAt: now,
                updatedAt: now,
                messages: trimmedMessages
            )
            chatSessions.insert(session, at: 0)
        }

        chatSessions.sort(by: { $0.updatedAt > $1.updatedAt })
        if chatSessions.count > maxSavedChats {
            chatSessions = Array(chatSessions.prefix(maxSavedChats))
        }

        saveChatHistory()
    }

    private func bindChatViewModel(_ viewModel: ChatViewModel) {
        chatBindings.removeAll()

        viewModel.$messages
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.persistActiveChatIfNeeded()
            }
            .store(in: &chatBindings)

        viewModel.$isStreaming
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.persistActiveChatIfNeeded()
            }
            .store(in: &chatBindings)
    }

    private func makeChatTitle(from messages: [ChatMessage]) -> String {
        let fallback = "Chat"
        guard let firstUser = messages.first(where: { $0.role == .user }) else { return fallback }
        let oneLine = firstUser.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !oneLine.isEmpty else { return fallback }
        if oneLine.count <= 52 { return oneLine }
        return String(oneLine.prefix(52)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func loadChatHistory() {
        guard let data = UserDefaults.standard.data(forKey: chatHistoryKey) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            chatSessions = try decoder.decode([ChatSession].self, from: data)
        } catch {
            AppLog.shared.log("Failed to load chat history: \(error)", level: .error)
        }
    }

    private func saveChatHistory() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(chatSessions)
            UserDefaults.standard.set(data, forKey: chatHistoryKey)
        } catch {
            AppLog.shared.log("Failed to save chat history: \(error)", level: .error)
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Better Siri needs screen recording permission to capture context. Please enable it in System Settings > Privacy & Security > Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
                AppLog.shared.log("Opened System Settings for screen recording permission")
            }
        }
    }

    func cleanup() {
        closePanel()
        Task {
            await BrowserUseWorker.shared.stopProcess()
        }
    }

    func exportLogs() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "bettersiri.log"
        savePanel.canCreateDirectories = true

        let response = savePanel.runModal()
        guard response == .OK, let destinationURL = savePanel.url else { return }

        do {
            try AppLog.shared.export(to: destinationURL)
            AppLog.shared.log("Logs exported to \(destinationURL.path)")
        } catch {
            AppLog.shared.log("Failed to export logs: \(error)", level: .error)
        }
    }
}
