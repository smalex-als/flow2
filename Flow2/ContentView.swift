import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            transcriptsPanel
            footer
        }
        .padding(24)
        .frame(minWidth: 920, minHeight: 820)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Flow2")
                    .font(.system(size: 30, weight: .semibold))
                Text("Record speech, transcribe with OpenAI, and inspect the text before we add global hotkey and cross-app insertion.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            SettingsLink {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        }
    }

    private var transcriptsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcripts")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.transcriptHistory.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .textBackgroundColor))

                if viewModel.transcriptHistory.isEmpty {
                    Text("Your transcripts will appear here after you stop recording.")
                        .foregroundStyle(.secondary)
                        .padding(18)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(viewModel.transcriptHistory.enumerated()), id: \.element.id) { index, item in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top) {
                                        if index == 0 {
                                            Text("Latest")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text(item.createdAt, style: .time)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Button("Copy") {
                                            viewModel.copyHistoryItem(item)
                                        }

                                        Button("Delete") {
                                            viewModel.deleteHistoryItem(item)
                                        }
                                    }

                                    Text(item.text)
                                        .font(.system(size: 16))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(16)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .layoutPriority(2)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isShowingMissingKeyAlert {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Add your OpenAI API key in Settings before sending audio to OpenAI.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink {
                        Text("Open Settings")
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task {
                        await viewModel.toggleRecording()
                    }
                } label: {
                    Label(viewModel.isRecording ? "Stop Recording" : "Start Recording",
                          systemImage: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                .controlSize(.large)
                .disabled(viewModel.isBusy)

                if viewModel.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(viewModel.statusText)
                    .foregroundStyle(.secondary)
            }

            Text("Current model: \(viewModel.configuration.model)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(viewModel.hotKeyStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(viewModel.insertionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(viewModel.accessibilityStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Request Accessibility Access") {
                    viewModel.requestAccessibilityAccess()
                }

                Button("Refresh Access Status") {
                    viewModel.refreshAccessibilityStatus()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Current app bundle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(viewModel.appBundlePath)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()

                    Button("Reveal App in Finder") {
                        viewModel.revealAppInFinder()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Debug Log")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Copy Debug Log") {
                        viewModel.copyDebugLog()
                    }
                    .disabled(viewModel.debugLog.isEmpty)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(viewModel.debugLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(minHeight: 120, maxHeight: 120)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}
