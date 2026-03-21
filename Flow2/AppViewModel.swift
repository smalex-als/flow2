import AppKit
import Foundation
import ServiceManagement

extension Notification.Name {
    static let flow2ConfigurationDidChange = Notification.Name("flow2ConfigurationDidChange")
}

struct TranscriptHistoryItem: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    let text: String

    init(id: UUID = UUID(), createdAt: Date = Date(), text: String) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var configuration = AppConfiguration()
    @Published var transcript = ""
    @Published var statusText = "Ready"
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var isShowingMissingKeyAlert = false
    @Published var hotKeyStatus = "Hotkey not registered"
    @Published var insertionStatus = "Auto-paste after transcription is enabled"
    @Published var accessibilityStatus = "Accessibility status unknown"
    @Published var appBundlePath = Bundle.main.bundleURL.path
    @Published var debugLog: [String] = []
    @Published var transcriptHistory: [TranscriptHistoryItem] = []

    private let configStore = ConfigurationStore()
    private let historyStore = TranscriptHistoryStore()
    private let recorder = AudioRecorder()
    private let textInsertionService = TextInsertionService()
    private let launchAtLoginService = LaunchAtLoginService()
    private var insertionTargetApp: NSRunningApplication?

    func loadConfiguration() async {
        do {
            configuration = try configStore.load()
        } catch {
            statusText = "Could not load config: \(error.localizedDescription)"
        }

        do {
            transcriptHistory = try historyStore.load()
        } catch {
            appendLog("History load failed: \(error.localizedDescription)")
        }

        await syncLaunchAtLoginFromSystem()
        refreshAccessibilityStatus()
    }

    func saveConfiguration(apiKey: String, model: String) async {
        var next = configuration
        next.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        next.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.model.isEmpty {
            next.model = AppConfiguration.defaultModel
        }
        next.enableAIEditing = configuration.enableAIEditing
        next.autoTranslateRussianToEnglish = configuration.autoTranslateRussianToEnglish
        next.hotKeyPreset = configuration.hotKeyPreset

        await saveConfiguration(next)
    }

    func updateQuickToggles(enableAIEditing: Bool, autoTranslateRussianToEnglish: Bool) async {
        var next = configuration
        next.enableAIEditing = enableAIEditing
        next.autoTranslateRussianToEnglish = enableAIEditing ? autoTranslateRussianToEnglish : false
        await saveConfiguration(next)
    }

    func saveConfiguration(apiKey: String, model: String, enableAIEditing: Bool, autoTranslateRussianToEnglish: Bool, hotKeyPreset: HotKeyPreset, launchAtLogin: Bool) async {
        var next = configuration
        next.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        next.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.model.isEmpty {
            next.model = AppConfiguration.defaultModel
        }
        next.enableAIEditing = enableAIEditing
        next.autoTranslateRussianToEnglish = autoTranslateRussianToEnglish
        next.hotKeyPreset = hotKeyPreset
        next.launchAtLogin = launchAtLogin

        await saveConfiguration(next)
    }

    private func saveConfiguration(_ next: AppConfiguration) async {
        var resolved = next
        var launchAtLoginError: Error?

        do {
            try configStore.save(next)
            configuration = next
            NotificationCenter.default.post(name: .flow2ConfigurationDidChange, object: nil)
        } catch {
            statusText = "Could not save config: \(error.localizedDescription)"
            appendLog("Settings save failed: \(error.localizedDescription)")
            return
        }

        do {
            try launchAtLoginService.setEnabled(next.launchAtLogin)
        } catch {
            launchAtLoginError = error
            resolved.launchAtLogin = launchAtLoginService.currentValue()
            configuration = resolved
            try? configStore.save(resolved)
        }

        if let launchAtLoginError {
            statusText = "Settings saved, but Launch at login failed: \(launchAtLoginError.localizedDescription)"
            appendLog("Launch at login update failed: \(launchAtLoginError.localizedDescription)")
        } else {
            statusText = "Settings saved"
        }
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecordingFromHotKey() async {
        guard !isRecording else { return }
        await startRecording()
    }

    func stopRecordingFromHotKey() async {
        guard isRecording else { return }
        await stopRecording()
    }

    func updateHotKeyStatus(_ text: String) {
        hotKeyStatus = text
    }

    func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
        statusText = "Transcript copied"
        appendLog("Transcript copied to pasteboard from app window")
    }

    func copyHistoryItem(_ item: TranscriptHistoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        statusText = "History item copied"
        appendLog("History item copied to pasteboard")
    }

    func deleteHistoryItem(_ item: TranscriptHistoryItem) {
        transcriptHistory.removeAll { $0.id == item.id }

        do {
            try historyStore.save(transcriptHistory)
            statusText = "History item deleted"
            appendLog("History item deleted")
        } catch {
            statusText = "Could not delete history item: \(error.localizedDescription)"
            appendLog("History delete failed: \(error.localizedDescription)")
        }
    }

    func copyDebugLog() {
        let joined = debugLog.reversed().joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(joined, forType: .string)
        statusText = "Debug log copied"
        appendLog("Debug log copied to pasteboard")
    }

    func requestAccessibilityAccess() {
        textInsertionService.requestAccessibilityAccess()
        appendLog("Requested Accessibility access prompt")
        refreshAccessibilityStatus()
    }

    func refreshAccessibilityStatus() {
        let trusted = textInsertionService.isAccessibilityTrusted()
        accessibilityStatus = trusted ? "Accessibility trusted" : "Accessibility not trusted"
        appBundlePath = Bundle.main.bundleURL.path
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        appendLog("Revealed current app bundle in Finder")
    }

    private func startRecording() async {
        guard !isBusy else { return }

        do {
            insertionTargetApp = NSWorkspace.shared.frontmostApplication
            let url = try await recorder.start()
            isRecording = true
            transcript = ""
            statusText = "Recording to \(url.lastPathComponent)"
            let targetAppName = insertionTargetApp?.localizedName ?? "unknown"
            appendLog("Recording started: \(url.lastPathComponent), targetApp=\(targetAppName)")
        } catch {
            statusText = "Failed to start recording: \(error.localizedDescription)"
            appendLog("Recording failed to start: \(error.localizedDescription)")
        }
    }

    private func stopRecording() async {
        guard isRecording else { return }
        isBusy = true
        isRecording = false

        do {
            let fileURL = try await recorder.stop()
            statusText = "Uploading audio..."
            appendLog("Recording stopped: \(fileURL.lastPathComponent)")

            let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                isShowingMissingKeyAlert = true
                statusText = "API key required"
                isBusy = false
                appendLog("Insertion aborted: missing API key")
                return
            }

            let client = OpenAITranscriptionClient()
            let rawText = try await client.transcribe(audioFileURL: fileURL, apiKey: apiKey, model: configuration.model)
            appendLog("Transcription complete: \(rawText.count) chars")

            let finalText = await autoEditTranscriptIfNeeded(rawText, apiKey: apiKey)
            transcript = finalText
            statusText = "Transcription complete"
            addTranscriptToHistory(finalText)

            do {
                let details = try await textInsertionService.insert(finalText, targetApp: insertionTargetApp)
                insertionStatus = "Transcript inserted into the active app"
                refreshAccessibilityStatus()
                appendLog(details)
            } catch {
                insertionStatus = "Insertion failed. Check Accessibility/Input Monitoring permissions."
                statusText = "Transcript ready, but insertion failed: \(error.localizedDescription)"
                refreshAccessibilityStatus()
                appendLog("Insertion failed: \(error.localizedDescription)")
            }
        } catch {
            statusText = "Failed: \(error.localizedDescription)"
            appendLog("Stop/transcribe flow failed: \(error.localizedDescription)")
        }

        insertionTargetApp = nil
        isBusy = false
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date()))  \(message)"
        debugLog.insert(line, at: 0)
        if debugLog.count > 20 {
            debugLog.removeLast(debugLog.count - 20)
        }
    }

    private func addTranscriptToHistory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        transcriptHistory.insert(TranscriptHistoryItem(text: trimmed), at: 0)
        if transcriptHistory.count > 12 {
            transcriptHistory.removeLast(transcriptHistory.count - 12)
        }

        do {
            try historyStore.save(transcriptHistory)
        } catch {
            appendLog("History save failed: \(error.localizedDescription)")
        }
    }

    private func syncLaunchAtLoginFromSystem() async {
        var next = configuration
        next.launchAtLogin = launchAtLoginService.currentValue()
        configuration = next
    }

    private func autoEditTranscriptIfNeeded(_ text: String, apiKey: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.enableAIEditing else { return trimmed }
        guard !trimmed.isEmpty else { return trimmed }
        let shouldTranslateToEnglish = configuration.autoTranslateRussianToEnglish && containsRussianText(trimmed)

        let previousMessages = transcriptHistory
            .prefix(8)
            .map(\.text)
            .reversed()

        appendLog("AI editing started: previousMessages=\(previousMessages.count), model=\(AppConfiguration.defaultEditingModel), translateToEnglish=\(shouldTranslateToEnglish)")

        do {
            let client = OpenAIEditingClient()
            let editedText = try await client.rewriteLatestMessage(
                latestMessage: trimmed,
                previousMessages: Array(previousMessages),
                translateToEnglish: shouldTranslateToEnglish,
                apiKey: apiKey
            )
            appendLog("AI editing complete: \(editedText.count) chars")
            return editedText
        } catch {
            appendLog("AI editing failed, using raw transcript: \(error.localizedDescription)")
            return trimmed
        }
    }

    private func containsRussianText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0400 ... 0x04FF).contains(scalar.value) || (0x0500 ... 0x052F).contains(scalar.value)
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Launch at login is unavailable on this macOS version."
        }
    }
}

@MainActor
final class LaunchAtLoginService {
    func currentValue() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return false
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw LaunchAtLoginError.unsupported
        }

        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

final class TranscriptHistoryStore {
    private let fileURL = AppStoragePaths.baseDirectory.appendingPathComponent("history.json")

    func load() throws -> [TranscriptHistoryItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([TranscriptHistoryItem].self, from: data)
    }

    func save(_ history: [TranscriptHistoryItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(history)
        try data.write(to: fileURL, options: Data.WritingOptions.atomic)
    }
}
