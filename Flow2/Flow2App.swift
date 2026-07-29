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
                    viewModel.pruneOrphanedRecordings()
                    appDelegate.installHotKeyIfNeeded(using: viewModel)
                }
        }
        .defaultSize(width: 980, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            Flow2Commands()
        }

        Window("About Flow2", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .frame(width: 760, height: 640)
        }

        MenuBarExtra("Flow2", systemImage: viewModel.isRecording ? "waveform.circle.fill" : "mic.circle") {
            MenuBarContentView()
                .environmentObject(viewModel)
        }
    }
}

private struct Flow2Commands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Flow2") {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            }
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

            Text(hotKeyHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(viewModel.isRecording ? "Stop Recording" : "Start Recording") {
                Task {
                    await viewModel.toggleRecording()
                }
            }
            .disabled(viewModel.isBusy)

            Divider()

            Toggle("AI Auto-Edit", isOn: aiEditingBinding)

            Toggle("Translate RU -> EN", isOn: autoTranslateBinding)

            Divider()

            Button("Show Flow2 Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("About Flow2") {
                openWindow(id: "about")
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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var hotKeyHint: String {
        let configuration = viewModel.configuration
        guard configuration.enableNoTranslateHotKey, configuration.noTranslateHotKey != configuration.hotKey else {
            return configuration.hotKey.displayName
        }

        return "\(configuration.hotKey.displayName) with translation · \(configuration.noTranslateHotKey.displayName) without translation"
    }

    private var aiEditingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.configuration.enableAIEditing },
            set: { newValue in
                Task {
                    await viewModel.updateQuickToggles(
                        enableAIEditing: newValue,
                        autoTranslateRussianToEnglish: viewModel.configuration.autoTranslateRussianToEnglish
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
