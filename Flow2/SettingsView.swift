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

                PermissionsSettingsTab()
                    .tabItem { Label("Permissions", systemImage: "lock.shield") }

                DiagnosticsSettingsTab()
                    .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
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
        .frame(width: 540, height: 566)
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
                Text("The key is stored in your login keychain, not in Flow2's files.")
            }

            Section {
                Picker("From", selection: viewModel.binding(\.translationSourceLanguage)) {
                    Text("Any language").tag(TranslationLanguage?.none)
                    ForEach(TranslationLanguage.allCases) { language in
                        Text(language.displayName).tag(TranslationLanguage?.some(language))
                    }
                }

                Picker("To", selection: viewModel.binding(\.translationTargetLanguage)) {
                    ForEach(TranslationLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Picker("Model", selection: viewModel.binding(\.translationModel)) {
                    ForEach(TranslationModelPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
            } header: {
                Text("Translation")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Runs every time you hold the **Dictate & Translate** shortcut. Plain dictation never sends the text to a second model.")
                    Text("**Any language** lets the model work out what you spoke, and leaves the text alone if it is already \(viewModel.configuration.translationTargetLanguage.displayName).")
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
                    Text("Sent to \(OpenAITranscriptionClient.model) as keyword hints in both modes, and treated as authoritative spellings during translation.")
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

                LabeledContent("Smart Dictate") {
                    HotKeyRecorderView(shortcut: shortcut(for: .smart))
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
                    Text("**Dictate & Translate** returns English when you speak Russian. **Dictate** always returns the language you spoke, untouched. **Smart Dictate** inserts nothing until you accept it, so it can be shortened, expanded, or translated first.")
                    Text("Hold to record, release to transcribe. Click a field, then press a combination that includes ⌃, ⌥, ⇧, or ⌘. Escape cancels.")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Each mode refuses a combination another one already owns, so none can silently shadow
    /// another and leave a mode unreachable.
    private func shortcut(for mode: DictationMode) -> Binding<HotKeyShortcut> {
        Binding(
            get: { viewModel.configuration.hotKey(for: mode) },
            set: { newValue in
                let owner = DictationMode.allCases.first {
                    $0 != mode && viewModel.configuration.hotKey(for: $0) == newValue
                }
                guard owner == nil else {
                    conflictMessage = "\(newValue.displayName) is already used by \(owner!.title)."
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
                        case .smart:
                            configuration.smartHotKey = newValue
                        }
                    }
                }
            }
        )
    }
}

// MARK: - Permissions

/// Permissions are something the user grants, not something Flow2 reports, so they live with the
/// other things they can act on rather than in Diagnostics.
private struct PermissionsSettingsTab: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility") {
                    statusLabel(viewModel.isAccessibilityTrusted ? "Trusted" : "Not trusted",
                                isSatisfied: viewModel.isAccessibilityTrusted)
                }

                HStack {
                    Button("Request Access") {
                        viewModel.requestAccessibilityAccess()
                    }
                    .disabled(viewModel.isAccessibilityTrusted)

                    Button("Refresh") {
                        viewModel.refreshPermissionStatus()
                    }
                }
            } header: {
                Text("Accessibility")
            } footer: {
                Text("Needed to place the transcript straight into the text field you were using. Without it Flow2 falls back to pasting.")
            }

            Section {
                LabeledContent("Microphone") {
                    statusLabel(viewModel.microphoneAccess.summary,
                                isSatisfied: viewModel.microphoneAccess == .granted)
                }

                switch viewModel.microphoneAccess {
                case .notRequested:
                    Button("Request Access") {
                        Task { await viewModel.requestMicrophoneAccess() }
                    }
                case .denied:
                    Button("Open System Settings") {
                        viewModel.openMicrophonePrivacySettings()
                    }
                case .granted:
                    EmptyView()
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text(viewModel.microphoneAccess == .denied
                     ? "macOS only asks once. Turning it back on has to happen in System Settings."
                     : "Asked for the first time when you start a recording.")
            }

            Section {
                Text(viewModel.appBundlePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Reveal in Finder") {
                    viewModel.revealAppInFinder()
                }
            } header: {
                Text("This copy of Flow2")
            } footer: {
                Text("Accessibility trust is tied to this exact location. Moving the app means granting it again, so it is worth keeping Flow2 in one place.")
            }
        }
        .formStyle(.grouped)
        .task {
            viewModel.refreshPermissionStatus()
        }
    }

    private func statusLabel(_ text: String, isSatisfied: Bool) -> some View {
        Label(text, systemImage: isSatisfied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(isSatisfied ? Color.green : Color.orange)
    }
}

// MARK: - Diagnostics

/// What the app can only report on. None of it changes what the next dictation does, which is why
/// it is here and not in the main window.
private struct DiagnosticsSettingsTab: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Form {
            Section("Last insertion") {
                Text(viewModel.insertionStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                if viewModel.debugLog.isEmpty {
                    Text("Nothing logged yet.")
                        .foregroundStyle(.secondary)
                } else {
                    // Capped at 20 lines upstream, and the form is already the scroll view, so the
                    // log renders inline rather than nesting one inside another.
                    ForEach(Array(viewModel.debugLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                HStack {
                    Text("Debug log")
                    Spacer()
                    Button("Copy") {
                        viewModel.copyDebugLog()
                    }
                    .disabled(viewModel.debugLog.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
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
