import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var draftKey = ""
    @State private var draftEditingModel: EditingModelPreset = AppConfiguration.defaultEditingModel
    @State private var draftEnableAIEditing = false
    @State private var draftAutoTranslateRussianToEnglish = false
    @State private var draftPreferredTerms = ""
    @State private var draftHotKey = HotKeyShortcut.controlSpace
    @State private var draftEnableNoTranslateHotKey = false
    @State private var draftNoTranslateHotKey = AppConfiguration.defaultNoTranslateHotKey
    @State private var draftLaunchAtLogin = false
    @State private var didLoadDrafts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 22, weight: .semibold))
                Text("Control your OpenAI setup, recording hotkey, and startup behavior.")
                    .foregroundStyle(.secondary)
            }

            Form {
                Section("OpenAI") {
                    SecureField("API key", text: $draftKey)
                        .textFieldStyle(.roundedBorder)

                    Picker("Post-processing model", selection: $draftEditingModel) {
                        ForEach(EditingModelPreset.allCases) { preset in
                            Text(preset.displayName)
                                .tag(preset)
                        }
                    }
                    .disabled(!draftEnableAIEditing && !draftAutoTranslateRussianToEnglish)

                    Toggle("Auto-edit transcript with AI", isOn: $draftEnableAIEditing)

                    Toggle("Auto-translate Russian to English", isOn: $draftAutoTranslateRussianToEnglish)

                    Text("OpenAI speech-to-text uses \(OpenAITranscriptionClient.model) for completed recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Post-processing model: used for enabled editing and translation. Translation works independently of auto-editing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("GPT-5.6 post-processing options: Luna for speed and volume, Terra for balance, and Sol for maximum quality.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("When Russian text is detected in the raw transcript, translation mode asks for English-only output.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Dictionary") {
                    Text("Use one preferred term per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $draftPreferredTerms)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Text("These terms are sent to \(OpenAITranscriptionClient.model) as keyword hints and passed into enabled translation or auto-editing as preferred spellings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Example: `ChatGPT`, `Smalex`, `iTerm2`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Hotkey") {
                    LabeledContent("Dictation with translation") {
                        HotKeyRecorderView(shortcut: $draftHotKey)
                            .frame(width: 180)
                    }

                    Toggle("Enable dictation without translation", isOn: $draftEnableNoTranslateHotKey)

                    LabeledContent("Dictation without translation") {
                        HotKeyRecorderView(
                            shortcut: $draftNoTranslateHotKey,
                            isEnabled: draftEnableNoTranslateHotKey
                        )
                        .frame(width: 180)
                    }

                    if hasHotKeyConflict {
                        Text("Choose different shortcuts for the two dictation modes.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Click a shortcut field, then press any key with Control, Option, Shift, or Command. Press Escape to cancel recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Dictation with translation follows the translation setting above. Dictation without translation always returns the transcript in the language you spoke.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Startup") {
                    Toggle("Launch Flow2 at login", isOn: $draftLaunchAtLogin)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text("Press Return to save")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Save Settings") {
                    saveSettings()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hasHotKeyConflict)
            }
        }
        .padding(18)
        .frame(width: 720, height: 520)
        .task {
            guard !didLoadDrafts else { return }
            await viewModel.loadConfiguration()
            draftKey = viewModel.configuration.apiKey
            draftEditingModel = viewModel.configuration.editingModel
            draftEnableAIEditing = viewModel.configuration.enableAIEditing
            draftAutoTranslateRussianToEnglish = viewModel.configuration.autoTranslateRussianToEnglish
            draftPreferredTerms = serializePreferredTerms(viewModel.configuration.preferredTerms)
            draftHotKey = viewModel.configuration.hotKey
            draftEnableNoTranslateHotKey = viewModel.configuration.enableNoTranslateHotKey
            draftNoTranslateHotKey = viewModel.configuration.noTranslateHotKey
            draftLaunchAtLogin = viewModel.configuration.launchAtLogin
            didLoadDrafts = true
        }
    }

    private func parsePreferredTerms(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func serializePreferredTerms(_ terms: [String]) -> String {
        terms.joined(separator: "\n")
    }

    private var hasHotKeyConflict: Bool {
        draftEnableNoTranslateHotKey && draftHotKey == draftNoTranslateHotKey
    }

    private func saveSettings() {
        Task {
            let didSave = await viewModel.saveConfiguration(
                apiKey: draftKey,
                editingModel: draftEditingModel,
                enableAIEditing: draftEnableAIEditing,
                autoTranslateRussianToEnglish: draftAutoTranslateRussianToEnglish,
                preferredTerms: parsePreferredTerms(draftPreferredTerms),
                hotKey: draftHotKey,
                enableNoTranslateHotKey: draftEnableNoTranslateHotKey,
                noTranslateHotKey: draftNoTranslateHotKey,
                launchAtLogin: draftLaunchAtLogin
            )

            if didSave {
                dismiss()
            }
        }
    }
}
