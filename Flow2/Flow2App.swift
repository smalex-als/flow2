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
        }

        MenuBarExtra("Flow2", systemImage: viewModel.isRecording ? "waveform.circle.fill" : "mic.circle") {
            MenuBarContentView()
                .environmentObject(viewModel)
        }
        // Stated rather than left to .automatic: the content is a list of commands, which is what a
        // menu is for, and a menu discards any layout or styling wrapped around it.
        .menuBarExtraStyle(.menu)
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
        Text(statusLine)

        // With no window open there is no other place this can surface, and a shortcut the system
        // refused otherwise just looks like a broken key.
        if !viewModel.failedHotKeyModes.isEmpty {
            Text(viewModel.hotKeyStatus)
        }

        Divider()

        if viewModel.isRecording {
            Button("Stop Recording") {
                Task {
                    await viewModel.toggleRecording(mode: .dictate)
                }
            }
        } else {
            ForEach(DictationMode.allCases) { mode in
                Button("\(mode.title)  \(viewModel.configuration.hotKey(for: mode).displayName)") {
                    Task {
                        await viewModel.toggleRecording(mode: mode)
                    }
                }
                .disabled(viewModel.isBusy)
            }
        }

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

        Divider()

        // Flow2 spends most of its life without a menu bar to carry the standard binding.
        Button("Quit Flow2") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        guard let mode = viewModel.recordingMode else { return viewModel.statusText }
        return viewModel.isRecording ? "Recording \(mode.shortDescription)..." : viewModel.statusText
    }
}
