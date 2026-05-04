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
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor).opacity(0.65)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(minWidth: 920, minHeight: 820)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Flow2")
                    .font(.system(size: 32, weight: .semibold))
                Text("Push-to-talk dictation for macOS with OpenAI transcription, AI cleanup, and direct app insertion.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    statusChip(title: viewModel.configuration.hotKeyPreset.displayName, systemImage: "keyboard")
                    statusChip(title: viewModel.configuration.enableAIEditing ? "AI Edit On" : "AI Edit Off", systemImage: "sparkles")
                    statusChip(title: "\(viewModel.transcriptHistory.count) Saved", systemImage: "text.quote")
                }
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
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(viewModel.transcriptHistory.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
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
                                        Label(historyLabel(for: item, index: index),
                                              systemImage: historyIcon(for: item, index: index))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(historyColor(for: item, index: index))

                                        Spacer()

                                        if item.isFailedRecording {
                                            Button("Retry") {
                                                Task {
                                                    await viewModel.retryHistoryItem(item)
                                                }
                                            }
                                            .buttonStyle(.borderless)
                                            .disabled(viewModel.isBusy || viewModel.isRecording)
                                        } else {
                                            Button("Copy") {
                                                viewModel.copyHistoryItem(item)
                                            }
                                            .buttonStyle(.borderless)
                                        }

                                        Button("Delete") {
                                            viewModel.deleteHistoryItem(item)
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.red)
                                    }

                                    if item.isFailedRecording {
                                        if let fileName = item.failedRecordingFileName {
                                            Text(fileName)
                                                .font(.system(size: 15, weight: .semibold))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }

                                        Text(item.failureReason ?? "Recognition failed.")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .lineSpacing(3)
                                    } else {
                                        Text(item.text)
                                            .font(.system(size: 18))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .lineSpacing(3)
                                    }
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

            VStack(alignment: .leading, spacing: 14) {
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

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                    footerInfoCard(title: "Transcription", value: transcriptionModelLabel, systemImage: "waveform")
                    footerInfoCard(title: "AI Editing", value: aiEditingModelLabel, systemImage: "sparkles")
                    footerInfoCard(title: "Hotkey", value: viewModel.hotKeyStatus, systemImage: "keyboard")
                    footerInfoCard(title: "Insertion", value: viewModel.insertionStatus, systemImage: "arrow.down.doc")
                    footerInfoCard(title: "Accessibility", value: viewModel.accessibilityStatus, systemImage: "figure.wave")
                }
            }

            HStack(spacing: 10) {
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

    private func statusChip(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
    }

    private var aiEditingModelLabel: String {
        guard viewModel.configuration.enableAIEditing else {
            return "Off"
        }

        return viewModel.configuration.editingModel.rawValue
    }

    private var transcriptionModelLabel: String {
        switch viewModel.configuration.transcriptionProvider {
        case .openAI:
            return viewModel.configuration.model
        case .localWhisper:
            return "Local Whisper: \(viewModel.configuration.localWhisperModel)"
        }
    }

    private func footerInfoCard(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func historyLabel(for item: TranscriptHistoryItem, index: Int) -> String {
        if item.isFailedRecording {
            return "Failed Recording"
        }
        return index == 0 ? "Latest" : item.createdAt.formatted(date: .omitted, time: .shortened)
    }

    private func historyIcon(for item: TranscriptHistoryItem, index: Int) -> String {
        if item.isFailedRecording {
            return "exclamationmark.triangle.fill"
        }
        return index == 0 ? "bolt.fill" : "clock"
    }

    private func historyColor(for item: TranscriptHistoryItem, index: Int) -> Color {
        if item.isFailedRecording {
            return .orange
        }
        return index == 0 ? .primary : .secondary
    }
}
