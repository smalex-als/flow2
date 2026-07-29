import AppKit
import Foundation
import ServiceManagement
import SwiftUI

extension Notification.Name {
    static let flow2ConfigurationDidChange = Notification.Name("flow2ConfigurationDidChange")
}

struct TranscriptHistoryItem: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    let text: String
    let failedRecordingFilePath: String?
    let failedRecordingFileName: String?
    let failureReason: String?

    var isFailedRecording: Bool {
        failedRecordingFilePath != nil
    }

    init(id: UUID = UUID(), createdAt: Date = Date(), text: String, failedRecordingFilePath: String? = nil, failedRecordingFileName: String? = nil, failureReason: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.failedRecordingFilePath = failedRecordingFilePath
        self.failedRecordingFileName = failedRecordingFileName
        self.failureReason = failureReason
    }

    static func failedRecording(fileURL: URL, reason: String, id: UUID = UUID(), createdAt: Date = Date()) -> TranscriptHistoryItem {
        TranscriptHistoryItem(
            id: id,
            createdAt: createdAt,
            text: "",
            failedRecordingFilePath: fileURL.path,
            failedRecordingFileName: fileURL.lastPathComponent,
            failureReason: reason
        )
    }
}

/// What a recording is for. The mode is fixed the moment the user presses a shortcut, because
/// push-to-talk gives no later opportunity to state the intent.
enum DictationMode: String, Codable, CaseIterable, Identifiable, Equatable {
    /// Insert what was said, in the language it was said.
    case dictate
    /// Insert an English translation of what was said.
    case translate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictate:
            return "Dictate"
        case .translate:
            return "Dictate & Translate"
        }
    }

    var shortDescription: String {
        switch self {
        case .dictate:
            return "as spoken"
        case .translate:
            return "translated to English"
        }
    }

    var systemImage: String {
        switch self {
        case .dictate:
            return "mic.circle.fill"
        case .translate:
            return "globe"
        }
    }
}

enum AppWorkflowPhase: Equatable {
    case idle
    case startingRecording
    case recording
    case finalizingRecording
    case transcribing
    case translating
    case inserting
}

@MainActor
final class AppViewModel: ObservableObject {
    private static let maxHistoryItems = 12

    @Published var configuration = AppConfiguration()
    @Published var transcript = ""
    @Published var statusText = "Ready"
    @Published private(set) var workflowPhase: AppWorkflowPhase = .idle
    @Published var isShowingMissingKeyAlert = false
    @Published var settingsError: String?
    @Published var hotKeyStatus = "Hotkey not registered"
    @Published var failedHotKeyModes: Set<DictationMode> = []
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
    private let recordingIndicator = RecordingIndicatorController()
    private var insertionTargetApp: NSRunningApplication?
    private var stopRequestedDuringRecordingStart = false
    private var activeMode: DictationMode = .dictate

    var isRecording: Bool {
        workflowPhase == .startingRecording || workflowPhase == .recording
    }

    var isBusy: Bool {
        switch workflowPhase {
        case .finalizingRecording, .transcribing, .translating, .inserting:
            return true
        case .idle, .startingRecording, .recording:
            return false
        }
    }

    /// The mode of the recording in flight, so the UI can show what is being produced.
    var recordingMode: DictationMode? {
        workflowPhase == .idle ? nil : activeMode
    }

    func loadConfiguration() async {
        do {
            configuration = try configStore.load()
            appendLog("Config loaded: transcriptionModel=\(OpenAITranscriptionClient.model), translationModel=\(configuration.translationModel.rawValue), dictate=\(configuration.dictateHotKey.displayName), translate=\(configuration.translateHotKey.displayName)")
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

    /// Settings apply as they are edited, so every change funnels through here instead of a Save
    /// button. Identical values are dropped: they would otherwise rewrite the file and re-register
    /// the hotkeys for nothing.
    func updateConfiguration(_ mutate: (inout AppConfiguration) -> Void) async {
        var next = configuration
        mutate(&next)
        guard next != configuration else { return }
        await saveConfiguration(next)
    }

    private func saveConfiguration(_ next: AppConfiguration) async {
        let launchAtLoginChanged = next.launchAtLogin != configuration.launchAtLogin

        do {
            try configStore.save(next)
            configuration = next
            NotificationCenter.default.post(name: .flow2ConfigurationDidChange, object: nil)
            appendLog("Settings saved: translationModel=\(next.translationModel.rawValue), dictate=\(next.dictateHotKey.displayName), translate=\(next.translateHotKey.displayName)")
        } catch {
            settingsError = "Could not save settings: \(error.localizedDescription)"
            appendLog("Settings save failed: \(error.localizedDescription)")
            return
        }

        guard launchAtLoginChanged else {
            settingsError = nil
            return
        }

        do {
            try launchAtLoginService.setEnabled(next.launchAtLogin)
            settingsError = nil
        } catch {
            // The system refused, so the stored value is rolled back to what it actually is rather
            // than left claiming something the user would not get at the next login.
            var resolved = next
            resolved.launchAtLogin = launchAtLoginService.currentValue()
            configuration = resolved
            try? configStore.save(resolved)
            settingsError = "Launch at login could not be changed: \(error.localizedDescription)"
            appendLog("Launch at login update failed: \(error.localizedDescription)")
        }
    }

    func toggleRecording(mode: DictationMode) async {
        switch workflowPhase {
        case .startingRecording, .recording:
            await stopRecording()
        case .idle:
            await startRecording(mode: mode)
        case .finalizingRecording, .transcribing, .translating, .inserting:
            break
        }
    }

    func startRecordingFromHotKey(mode: DictationMode) async {
        await startRecording(mode: mode)
    }

    func stopRecordingFromHotKey() async {
        await stopRecording()
    }

    func updateHotKeyStatus(_ text: String, failedModes: Set<DictationMode>) {
        hotKeyStatus = text
        failedHotKeyModes = failedModes
    }

    func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
        statusText = "Transcript copied"
        appendLog("Transcript copied to pasteboard from app window")
    }

    func copyHistoryItem(_ item: TranscriptHistoryItem) {
        guard !item.isFailedRecording else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        statusText = "History item copied"
        appendLog("History item copied to pasteboard")
    }

    func deleteHistoryItem(_ item: TranscriptHistoryItem) {
        transcriptHistory.removeAll { $0.id == item.id }
        discardRecording(for: item)

        do {
            try historyStore.save(transcriptHistory)
            statusText = "History item deleted"
            appendLog("History item deleted")
        } catch {
            statusText = "Could not delete history item: \(error.localizedDescription)"
            appendLog("History delete failed: \(error.localizedDescription)")
        }
    }

    func retryHistoryItem(_ item: TranscriptHistoryItem) async {
        guard workflowPhase == .idle else { return }
        guard let path = item.failedRecordingFilePath else { return }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            deleteHistoryItem(item)
            statusText = "Failed recording is no longer available"
            appendLog("Manual transcription retry aborted: missing file \(fileURL.lastPathComponent)")
            return
        }

        workflowPhase = .transcribing
        defer { workflowPhase = .idle }
        statusText = "Retrying \(fileURL.lastPathComponent)..."
        appendLog("Manual transcription retry started: \(fileURL.lastPathComponent)")

        do {
            try await transcribeRecordedFile(
                fileURL: fileURL,
                targetApp: nil,
                shouldInsertExternally: false,
                replacingHistoryItemID: item.id
            )
        } catch {
            updateFailedHistoryItem(item.id, fileURL: fileURL, reason: error.localizedDescription)
            statusText = "Failed: \(error.localizedDescription)"
            appendLog("Manual transcription retry failed: \(error.localizedDescription)")
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

    private func startRecording(mode: DictationMode) async {
        guard workflowPhase == .idle else { return }

        workflowPhase = .startingRecording
        stopRequestedDuringRecordingStart = false
        activeMode = mode
        statusText = "Starting recording..."
        insertionTargetApp = NSWorkspace.shared.frontmostApplication

        do {
            let url = try await recorder.start()
            workflowPhase = .recording
            transcript = ""
            statusText = "Recording to \(url.lastPathComponent)"
            let targetAppName = insertionTargetApp?.localizedName ?? "unknown"
            appendLog("Recording started: \(url.lastPathComponent), targetApp=\(targetAppName), mode=\(mode.rawValue)")

            if stopRequestedDuringRecordingStart {
                appendLog("Recording startup completed after stop was requested; stopping immediately")
                await stopRecording()
                return
            }

            recordingIndicator.show(mode: mode)
        } catch {
            workflowPhase = .idle
            insertionTargetApp = nil
            stopRequestedDuringRecordingStart = false
            activeMode = .dictate
            statusText = "Failed to start recording: \(error.localizedDescription)"
            appendLog("Recording failed to start: \(error.localizedDescription)")
        }
    }

    private func stopRecording() async {
        if workflowPhase == .startingRecording {
            stopRequestedDuringRecordingStart = true
            statusText = "Stopping recording as soon as it starts..."
            appendLog("Stop requested while recording was starting")
            return
        }

        guard workflowPhase == .recording else { return }
        workflowPhase = .finalizingRecording
        recordingIndicator.hide()
        var recordedFileURL: URL?
        defer {
            insertionTargetApp = nil
            stopRequestedDuringRecordingStart = false
            activeMode = .dictate
            workflowPhase = .idle
        }

        do {
            let fileURL = try await recorder.stop()
            recordedFileURL = fileURL
            appendLog("Recording stopped: \(fileURL.lastPathComponent)")
            try await transcribeRecordedFile(fileURL: fileURL, targetApp: insertionTargetApp, shouldInsertExternally: true)
        } catch {
            if let fileURL = recordedFileURL {
                insertFailedHistoryItem(fileURL: fileURL, reason: error.localizedDescription)
            }
            statusText = "Failed: \(error.localizedDescription)"
            appendLog("Stop/transcribe flow failed: \(error.localizedDescription)")
        }
    }

    private func transcribeRecordedFile(fileURL: URL, targetApp: NSRunningApplication?, shouldInsertExternally: Bool, replacingHistoryItemID: UUID? = nil) async throws {
        workflowPhase = .transcribing
        statusText = "Uploading and transcribing audio..."
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            isShowingMissingKeyAlert = true
            appendLog("Insertion aborted: missing API key")
            throw OpenAITranscriptionError.requestFailed("API key required")
        }

        let targetAppName = targetApp?.localizedName ?? "none"
        let replacingHistoryItem = replacingHistoryItemID != nil
        appendLog(
            "Transcription flow started: file=\(fileURL.lastPathComponent), targetApp=\(targetAppName), shouldInsertExternally=\(shouldInsertExternally), replacingHistoryItem=\(replacingHistoryItem)"
        )

        let client = OpenAITranscriptionClient()
        let rawText = try await client.transcribe(
            audioFileURL: fileURL,
            apiKey: apiKey,
            keywords: configuration.preferredTerms,
            onAttempt: { [weak self] attempt, total in
                Task { @MainActor [weak self] in
                    self?.appendLog("Transcription attempt \(attempt)/\(total)")
                }
            },
            onLog: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.appendLog(message)
                }
            }
        )

        appendLog("Transcription complete: \(rawText.count) chars")
        RecordingFileStore.delete(at: fileURL)
        if let replacingHistoryItemID {
            transcriptHistory.removeAll { $0.id == replacingHistoryItemID }
            saveHistory()
        }

        let finalText = await translateTranscriptIfNeeded(rawText, apiKey: apiKey)
        workflowPhase = .transcribing
        transcript = finalText
        statusText = "Transcription complete"
        addTranscriptToHistory(finalText)

        guard shouldInsertExternally else {
            insertionStatus = "Transcript kept in the Flow2 window"
            appendLog("Insertion skipped: manual retry")
            return
        }

        if shouldSkipExternalInsertion(for: targetApp) {
            insertionStatus = "Transcript kept in the Flow2 window"
            appendLog("Insertion skipped: targetApp=Flow2")
            return
        }

        workflowPhase = .inserting
        statusText = "Inserting transcript..."
        do {
            let details = try await textInsertionService.insert(finalText, targetApp: targetApp)
            statusText = "Transcription complete"
            insertionStatus = "Transcript inserted into the active app"
            refreshAccessibilityStatus()
            appendLog(details)
        } catch {
            insertionStatus = "Insertion failed. Check Accessibility/Input Monitoring permissions."
            statusText = "Transcript ready, but insertion failed: \(error.localizedDescription)"
            refreshAccessibilityStatus()
            appendLog("Insertion failed: \(error.localizedDescription)")
        }
    }

    private func insertFailedHistoryItem(fileURL: URL, reason: String) {
        transcriptHistory.insert(TranscriptHistoryItem.failedRecording(fileURL: fileURL, reason: reason), at: 0)
        trimHistory()
        saveHistory()
        appendLog("Saved failed recording for manual retry: \(fileURL.lastPathComponent)")
    }

    private func updateFailedHistoryItem(_ id: UUID, fileURL: URL, reason: String) {
        guard let index = transcriptHistory.firstIndex(where: { $0.id == id }) else { return }
        transcriptHistory[index] = TranscriptHistoryItem.failedRecording(fileURL: fileURL, reason: reason, id: id, createdAt: transcriptHistory[index].createdAt)
        saveHistory()
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
        trimHistory()
        saveHistory()
    }

    /// Drops the oldest entries past the cap, taking any recording they were still holding with them.
    private func trimHistory() {
        let overflow = transcriptHistory.count - Self.maxHistoryItems
        guard overflow > 0 else { return }

        let dropped = transcriptHistory.suffix(overflow)
        transcriptHistory.removeLast(overflow)
        dropped.forEach(discardRecording(for:))
    }

    private func discardRecording(for item: TranscriptHistoryItem) {
        guard let path = item.failedRecordingFilePath else { return }
        RecordingFileStore.delete(at: URL(fileURLWithPath: path))
    }

    /// Clears recordings left behind by earlier versions, crashes, or force quits. Only entries still
    /// offering `Retry` are kept, so a run that ends normally leaves nothing on disk.
    func pruneOrphanedRecordings() {
        guard workflowPhase == .idle else { return }

        let retainedPaths = Set(transcriptHistory.compactMap(\.failedRecordingFilePath))
        let removed = RecordingFileStore.pruneOrphans(keeping: retainedPaths)
        guard removed.count > 0 else { return }

        let freed = ByteCountFormatter.string(fromByteCount: removed.bytes, countStyle: .file)
        appendLog("Removed \(removed.count) orphaned recording(s), freed \(freed)")
    }

    private func saveHistory() {
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

    /// `Dictate` inserts the transcript untouched, so the second model only runs for `translate`,
    /// and only when there is Russian in the text to translate.
    private func translateTranscriptIfNeeded(_ text: String, apiKey: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard activeMode == .translate else { return trimmed }

        guard containsRussianText(trimmed) else {
            appendLog("Translation skipped: no Cyrillic in the transcript")
            return trimmed
        }

        workflowPhase = .translating
        statusText = "Translating transcript..."

        // Failed recordings carry no text and would arrive as blank numbered lines of context.
        let previousMessages = transcriptHistory
            .lazy
            .filter { !$0.isFailedRecording }
            .prefix(8)
            .map(\.text)
            .reversed()

        appendLog("Translation started: previousMessages=\(previousMessages.count), model=\(configuration.translationModel.rawValue)")

        do {
            let client = OpenAITranslationClient()
            let translatedText = try await client.translateLatestMessage(
                latestMessage: trimmed,
                previousMessages: Array(previousMessages),
                preferredTerms: configuration.preferredTerms,
                model: configuration.translationModel.rawValue,
                apiKey: apiKey
            )
            appendLog("Translation complete: \(translatedText.count) chars")
            return translatedText
        } catch {
            appendLog("Translation failed, using raw transcript: \(error.localizedDescription)")
            return trimmed
        }
    }

    private func containsRussianText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0400 ... 0x04FF).contains(scalar.value) || (0x0500 ... 0x052F).contains(scalar.value)
        }
    }

    private func shouldSkipExternalInsertion(for targetApp: NSRunningApplication?) -> Bool {
        guard let targetApp else { return false }
        return targetApp.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}

@MainActor
final class RecordingIndicatorController {
    private var panel: NSPanel?

    func show(mode: DictationMode) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: RecordingIndicatorView(mode: mode))
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 132, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - (panel.frame.width / 2)
        let y = visibleFrame.midY - (panel.frame.height / 2)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Names the mode, because which shortcut was pressed is the only thing that decides whether the
/// result comes back translated, and that is easy to get wrong mid-sentence.
private struct RecordingIndicatorView: View {
    let mode: DictationMode

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.82))

            VStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 38, weight: .semibold))

                Text(mode == .translate ? "EN" : "AS SPOKEN")
                    .font(.system(size: mode == .translate ? 13 : 9, weight: .bold))
                    .kerning(0.5)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 132, height: 132)
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
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
