import SwiftUI

@main
struct Flow2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        Window("Flow2", id: "main") {
            ContentView()
                .environmentObject(viewModel)
                .task {
                    await viewModel.loadConfiguration()
                    appDelegate.installHotKeyIfNeeded(using: viewModel)
                }
        }
        .defaultSize(width: 980, height: 780)

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .frame(width: 520, height: 320)
        }

        MenuBarExtra("Flow2", systemImage: viewModel.isRecording ? "waveform.circle.fill" : "mic.circle") {
            MenuBarContentView()
                .environmentObject(viewModel)
        }
    }
}

private struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.isRecording ? "Recording..." : viewModel.statusText)
                .font(.headline)

            Button(viewModel.isRecording ? "Stop Recording" : "Start Recording") {
                Task {
                    await viewModel.toggleRecording()
                }
            }
            .disabled(viewModel.isBusy)

            Divider()

            Toggle("AI Auto-Edit", isOn: aiEditingBinding)

            Toggle("Translate RU -> EN", isOn: autoTranslateBinding)
                .disabled(!viewModel.configuration.enableAIEditing)

            Divider()

            Button("Show Flow2 Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            SettingsLink {
                Text("Settings")
            }

            Button("Quit Flow2") {
                NSApp.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var aiEditingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.configuration.enableAIEditing },
            set: { newValue in
                Task {
                    await viewModel.updateQuickToggles(
                        enableAIEditing: newValue,
                        autoTranslateRussianToEnglish: newValue ? viewModel.configuration.autoTranslateRussianToEnglish : false
                    )
                }
            }
        )
    }

    private var autoTranslateBinding: Binding<Bool> {
        Binding(
            get: { viewModel.configuration.autoTranslateRussianToEnglish },
            set: { newValue in
                Task {
                    await viewModel.updateQuickToggles(
                        enableAIEditing: viewModel.configuration.enableAIEditing,
                        autoTranslateRussianToEnglish: newValue
                    )
                }
            }
        )
    }
}
