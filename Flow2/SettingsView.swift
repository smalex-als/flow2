import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var draftKey = ""
    @State private var draftModel = ""
    @State private var draftEnableAIEditing = false
    @State private var draftAutoTranslateRussianToEnglish = false
    @State private var draftPreferredTerms = ""
    @State private var draftHotKeyPreset: HotKeyPreset = .controlSpace
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

                    TextField("Transcription model", text: $draftModel)
                        .textFieldStyle(.roundedBorder)

                    Toggle("Auto-edit transcript with AI", isOn: $draftEnableAIEditing)

                    Toggle("Auto-translate Russian to English", isOn: $draftAutoTranslateRussianToEnglish)
                        .disabled(!draftEnableAIEditing)

                    Text("Recommended: `gpt-4o-mini-transcribe` for cost and speed, `gpt-4o-transcribe` for higher accuracy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("AI editing uses recent history as context and returns only the latest corrected message.")
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

                    Text("These terms are passed into AI auto-editing as preferred spellings, names, and product words.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Example: `ChatGPT`, `Smalex`, `iTerm2`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Hotkey") {
                    Picker("Push-to-talk shortcut", selection: $draftHotKeyPreset) {
                        ForEach(HotKeyPreset.allCases) { preset in
                            Text(preset.displayName)
                                .tag(preset)
                        }
                    }
                }

                Section("Startup") {
                    Toggle("Launch Flow2 at login", isOn: $draftLaunchAtLogin)
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Save") {
                            Task {
                                var model = draftModel
                                if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    model = AppConfiguration.defaultModel
                                }

                                let didSave = await viewModel.saveConfiguration(
                                    apiKey: draftKey,
                                    model: model,
                                    enableAIEditing: draftEnableAIEditing,
                                    autoTranslateRussianToEnglish: draftAutoTranslateRussianToEnglish,
                                    preferredTerms: parsePreferredTerms(draftPreferredTerms),
                                    hotKeyPreset: draftHotKeyPreset,
                                    launchAtLogin: draftLaunchAtLogin
                                )

                                if didSave {
                                    dismiss()
                                }
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(18)
        .task {
            guard !didLoadDrafts else { return }
            await viewModel.loadConfiguration()
            draftKey = viewModel.configuration.apiKey
            draftModel = viewModel.configuration.model
            draftEnableAIEditing = viewModel.configuration.enableAIEditing
            draftAutoTranslateRussianToEnglish = viewModel.configuration.autoTranslateRussianToEnglish
            draftPreferredTerms = serializePreferredTerms(viewModel.configuration.preferredTerms)
            draftHotKeyPreset = viewModel.configuration.hotKeyPreset
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
}
