import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var draftKey = ""
    @State private var draftModel = ""
    @State private var draftTranscriptionProvider: TranscriptionProvider = .openAI
    @State private var draftLocalWhisperExecutablePath = AppConfiguration.defaultLocalWhisperExecutablePath
    @State private var draftLocalWhisperModel = AppConfiguration.defaultLocalWhisperModel
    @State private var draftEditingModel: EditingModelPreset = AppConfiguration.defaultEditingModel
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

                    Picker("Speech-to-text engine", selection: $draftTranscriptionProvider) {
                        ForEach(TranscriptionProvider.allCases) { provider in
                            Text(provider.displayName)
                                .tag(provider)
                        }
                    }

                    TextField("OpenAI speech-to-text model", text: $draftModel)
                        .textFieldStyle(.roundedBorder)
                        .disabled(draftTranscriptionProvider != .openAI)

                    TextField("Local Whisper command", text: $draftLocalWhisperExecutablePath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(draftTranscriptionProvider != .localWhisper)

                    TextField("Local Whisper model", text: $draftLocalWhisperModel)
                        .textFieldStyle(.roundedBorder)
                        .disabled(draftTranscriptionProvider != .localWhisper)

                    Picker("Post-processing model", selection: $draftEditingModel) {
                        ForEach(EditingModelPreset.allCases) { preset in
                            Text(preset.displayName)
                                .tag(preset)
                        }
                    }
                    .disabled(!draftEnableAIEditing)

                    Toggle("Auto-edit transcript with AI", isOn: $draftEnableAIEditing)

                    Toggle("Auto-translate Russian to English", isOn: $draftAutoTranslateRussianToEnglish)
                        .disabled(!draftEnableAIEditing)

                    Text("Local Whisper runs on this Mac through the command-line tool and does not send audio to OpenAI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("OpenAI speech-to-text model: `gpt-4o-mini-transcribe` is the compact default; `gpt-4o-transcribe` is the higher accuracy option.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Post-processing model: used only after transcription, for cleanup, translation, and preferred terms.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Available GPT-5 post-processing options: Nano, Mini, and the full GPT-5.4 model.")
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
                                    transcriptionProvider: draftTranscriptionProvider,
                                    localWhisperExecutablePath: draftLocalWhisperExecutablePath,
                                    localWhisperModel: draftLocalWhisperModel,
                                    editingModel: draftEditingModel,
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
            draftTranscriptionProvider = viewModel.configuration.transcriptionProvider
            draftLocalWhisperExecutablePath = viewModel.configuration.localWhisperExecutablePath
            draftLocalWhisperModel = viewModel.configuration.localWhisperModel
            draftEditingModel = viewModel.configuration.editingModel
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
