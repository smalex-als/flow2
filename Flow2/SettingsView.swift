import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettingsTab()
                    .tabItem { Label("General", systemImage: "gearshape") }

                DictionarySettingsTab()
                    .tabItem { Label("Dictionary", systemImage: "character.book.closed") }

                ShortcutsSettingsTab()
                    .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            }

            if let settingsError = viewModel.settingsError {
                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(settingsError)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 540, height: 512)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var apiKeyDraft = ""
    @State private var didLoadAPIKey = false

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $apiKeyDraft, prompt: Text("sk-..."))

                LabeledContent("Speech-to-text") {
                    Text(OpenAITranscriptionClient.model)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("The key is stored in `~/Library/Application Support/Flow2/config.json`.")
            }

            Section {
                Toggle("Clean up transcripts", isOn: viewModel.binding(\.enableAIEditing))
                Toggle("Translate Russian to English", isOn: viewModel.binding(\.autoTranslateRussianToEnglish))

                Picker("Model", selection: viewModel.binding(\.editingModel)) {
                    ForEach(EditingModelPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .disabled(!isPostProcessingEnabled)
            } header: {
                Text("Post-processing")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(postProcessingSummary)
                    Text("Luna is the fastest, Terra balances speed and quality, Sol is the most accurate.")
                }
            }

            Section("Startup") {
                Toggle("Launch Flow2 at login", isOn: viewModel.binding(\.launchAtLogin))
            }
        }
        .formStyle(.grouped)
        .task {
            apiKeyDraft = viewModel.configuration.apiKey
            didLoadAPIKey = true
        }
        // Saving per keystroke would rewrite the config file and re-register the hotkeys on every
        // character, so the key settles first.
        .task(id: apiKeyDraft) {
            guard didLoadAPIKey else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }

            await viewModel.updateConfiguration {
                $0.apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Leaving the tab cancels the pending debounce, so the last keystrokes are flushed here.
        .onDisappear {
            guard didLoadAPIKey else { return }
            let apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await viewModel.updateConfiguration { $0.apiKey = apiKey } }
        }
    }

    private var isPostProcessingEnabled: Bool {
        viewModel.configuration.enableAIEditing || viewModel.configuration.autoTranslateRussianToEnglish
    }

    private var postProcessingSummary: String {
        switch (viewModel.configuration.enableAIEditing, viewModel.configuration.autoTranslateRussianToEnglish) {
        case (true, true):
            return "Transcripts are corrected, and Russian speech comes back as English."
        case (true, false):
            return "Transcripts are corrected in the language you spoke."
        case (false, true):
            return "Russian speech comes back as English, otherwise the transcript is left as recognized."
        case (false, false):
            return "Transcripts are inserted exactly as recognized. No second model runs."
        }
    }
}

// MARK: - Dictionary

private struct DictionarySettingsTab: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var termsDraft = ""
    @State private var didLoadTerms = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $termsDraft)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }
            } header: {
                HStack {
                    Text("Preferred terms")
                    Spacer()
                    Text(termCountLabel)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("One term per line, for names, products, and spellings that get recognized wrong.")
                    Text("Sent to \(OpenAITranscriptionClient.model) as keyword hints, and treated as authoritative spellings by translation and cleanup.")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            termsDraft = viewModel.configuration.preferredTerms.joined(separator: "\n")
            didLoadTerms = true
        }
        .task(id: termsDraft) {
            guard didLoadTerms else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }

            await viewModel.updateConfiguration { $0.preferredTerms = Self.parse(termsDraft) }
        }
        .onDisappear {
            guard didLoadTerms else { return }
            let terms = Self.parse(termsDraft)
            Task { await viewModel.updateConfiguration { $0.preferredTerms = terms } }
        }
    }

    private var termCountLabel: String {
        let count = Self.parse(termsDraft).count
        return count == 1 ? "1 term" : "\(count) terms"
    }

    private static func parse(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsTab: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var conflictMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Dictate") {
                    HotKeyRecorderView(shortcut: primaryShortcut)
                        .frame(width: 170)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Hold to record, release to transcribe. Click the field, then press a combination that includes ⌃, ⌥, ⇧, or ⌘. Escape cancels.")
            }

            Section {
                Toggle("Use a second shortcut", isOn: viewModel.binding(\.enableNoTranslateHotKey))

                LabeledContent("Dictate without translating") {
                    HotKeyRecorderView(
                        shortcut: secondaryShortcut,
                        isEnabled: viewModel.configuration.enableNoTranslateHotKey
                    )
                    .frame(width: 170)
                }

                if let conflictMessage {
                    Text(conflictMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Skip translation")
            } footer: {
                Text("The main shortcut follows the translation setting in General. This one always returns the transcript in the language you spoke.")
            }
        }
        .formStyle(.grouped)
    }

    private var primaryShortcut: Binding<HotKeyShortcut> {
        Binding(
            get: { viewModel.configuration.hotKey },
            set: { newValue in
                conflictMessage = nil
                Task {
                    await viewModel.updateConfiguration { configuration in
                        configuration.hotKey = newValue
                        // The main shortcut wins; the second one steps aside instead of blocking it.
                        if configuration.noTranslateHotKey == newValue {
                            configuration.noTranslateHotKey = AppConfiguration.fallbackNoTranslateHotKey(avoiding: newValue)
                        }
                    }
                }
            }
        )
    }

    private var secondaryShortcut: Binding<HotKeyShortcut> {
        Binding(
            get: { viewModel.configuration.noTranslateHotKey },
            set: { newValue in
                guard newValue != viewModel.configuration.hotKey else {
                    conflictMessage = "\(newValue.displayName) is already the main dictation shortcut."
                    return
                }

                conflictMessage = nil
                Task {
                    await viewModel.updateConfiguration { $0.noTranslateHotKey = newValue }
                }
            }
        )
    }
}

private extension AppViewModel {
    /// Writes straight through to the stored configuration, so a control never holds a draft that
    /// can drift from what the menu bar or another settings tab already changed.
    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<AppConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { self.configuration[keyPath: keyPath] },
            set: { newValue in
                Task { await self.updateConfiguration { $0[keyPath: keyPath] = newValue } }
            }
        )
    }
}
