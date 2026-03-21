import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var draftKey = ""
    @State private var draftModel = ""
    @State private var draftEnableAIEditing = false
    @State private var draftAutoTranslateRussianToEnglish = false
    @State private var draftHotKeyPreset: HotKeyPreset = .shiftCommandSpace
    @State private var draftLaunchAtLogin = false
    @State private var didLoadDrafts = false

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API key", text: $draftKey)
                    .textFieldStyle(.roundedBorder)

                TextField("Model", text: $draftModel)
                    .textFieldStyle(.roundedBorder)

                Toggle("Auto-edit transcript with AI", isOn: $draftEnableAIEditing)

                Toggle("Auto-translate Russian to English", isOn: $draftAutoTranslateRussianToEnglish)
                    .disabled(!draftEnableAIEditing)

                Text("Recommended: `gpt-4o-mini-transcribe` for cost/speed, `gpt-4o-transcribe` for higher accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("When enabled, Flow2 sends the latest transcript plus recent previous messages to OpenAI and returns only the corrected latest message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("If auto-translate is enabled and the raw transcript contains Russian text, Flow2 asks AI to return the corrected latest message in English.")
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

                            await viewModel.saveConfiguration(
                                apiKey: draftKey,
                                model: model,
                                enableAIEditing: draftEnableAIEditing,
                                autoTranslateRussianToEnglish: draftAutoTranslateRussianToEnglish,
                                hotKeyPreset: draftHotKeyPreset,
                                launchAtLogin: draftLaunchAtLogin
                            )
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .task {
            guard !didLoadDrafts else { return }
            await viewModel.loadConfiguration()
            draftKey = viewModel.configuration.apiKey
            draftModel = viewModel.configuration.model
            draftEnableAIEditing = viewModel.configuration.enableAIEditing
            draftAutoTranslateRussianToEnglish = viewModel.configuration.autoTranslateRussianToEnglish
            draftHotKeyPreset = viewModel.configuration.hotKeyPreset
            draftLaunchAtLogin = viewModel.configuration.launchAtLogin
            didLoadDrafts = true
        }
    }
}
