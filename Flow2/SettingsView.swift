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
                Picker("Model", selection: viewModel.binding(\.translationModel)) {
                    ForEach(TranslationModelPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
            } header: {
                Text("Translation")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Used only by the **Dictate & Translate** shortcut, and only when the transcript contains Russian. Plain dictation never sends the text to a second model.")
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
                LabeledContent("Dictate & Translate") {
                    HotKeyRecorderView(shortcut: shortcut(for: .translate))
                        .frame(width: 170)
                }

                LabeledContent("Dictate") {
                    HotKeyRecorderView(shortcut: shortcut(for: .dictate))
                        .frame(width: 170)
                }

                if let conflictMessage {
                    Text(conflictMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Push to talk")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("**Dictate & Translate** returns English when you speak Russian. **Dictate** always returns the language you spoke, untouched.")
                    Text("Hold to record, release to transcribe. Click a field, then press a combination that includes ⌃, ⌥, ⇧, or ⌘. Escape cancels.")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Each mode refuses a combination the other one already owns, so neither can silently shadow
    /// the other and leave a mode unreachable.
    private func shortcut(for mode: DictationMode) -> Binding<HotKeyShortcut> {
        Binding(
            get: { viewModel.configuration.hotKey(for: mode) },
            set: { newValue in
                let other: DictationMode = mode == .dictate ? .translate : .dictate
                guard newValue != viewModel.configuration.hotKey(for: other) else {
                    conflictMessage = "\(newValue.displayName) is already used by \(other.title)."
                    return
                }

                conflictMessage = nil
                Task {
                    await viewModel.updateConfiguration { configuration in
                        switch mode {
                        case .dictate:
                            configuration.dictateHotKey = newValue
                        case .translate:
                            configuration.translateHotKey = newValue
                        }
                    }
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
