import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var isShowingDiagnostics = false

    /// The window keeps a single scrollable region between a pinned header and a pinned control bar,
    /// so the primary action stays reachable and no scroll view is ever nested inside another.
    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    transcriptsSection
                    diagnosticsSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            controlBar
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
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
        .frame(minWidth: 640, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Flow2")
                    .font(.system(size: 32, weight: .semibold))
                Text("Push-to-talk dictation for macOS. Hold one shortcut to dictate, the other to come back in \(viewModel.configuration.translationTargetLanguage.displayName).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    ForEach(DictationMode.allCases) { mode in
                        modeChip(for: mode)
                    }
                }
            }

            Spacer()

            SettingsLink {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        }
    }

    private var transcriptsSection: some View {
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

            if viewModel.transcriptHistory.isEmpty {
                Text("Your transcripts will appear here after you stop recording.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(Array(viewModel.transcriptHistory.enumerated()), id: \.element.id) { index, item in
                    transcriptCard(for: item, index: index)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transcriptCard(for item: TranscriptHistoryItem, index: Int) -> some View {
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
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    private var controlBar: some View {
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
                if viewModel.isRecording {
                    Button {
                        Task {
                            await viewModel.toggleRecording(mode: .dictate)
                        }
                    } label: {
                        Label("Stop Recording", systemImage: "stop.circle.fill")
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .controlSize(.large)
                } else {
                    // One button per mode: the mode has to be chosen before speaking, not after.
                    ForEach(DictationMode.allCases) { mode in
                        Button {
                            Task {
                                await viewModel.toggleRecording(mode: mode)
                            }
                        } label: {
                            Label(mode.title, systemImage: mode.systemImage)
                        }
                        .keyboardShortcut(mode == .dictate ? KeyboardShortcut(.space, modifiers: []) : nil)
                        .controlSize(.large)
                        .disabled(viewModel.isBusy)
                    }
                }

                if viewModel.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(viewModel.statusText)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnosticsSection: some View {
        DisclosureGroup(isExpanded: $isShowingDiagnostics) {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                    footerInfoCard(title: "Transcription", value: transcriptionModelLabel, systemImage: "waveform")
                    footerInfoCard(title: "Translation", value: translationSummary, systemImage: "globe")
                    footerInfoCard(title: "Insertion", value: viewModel.insertionStatus, systemImage: "arrow.down.doc")
                    footerInfoCard(title: "Accessibility", value: viewModel.accessibilityStatus, systemImage: "figure.wave")
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

                    // The log is capped at 20 lines upstream, so it can render inline instead of
                    // opening a second scroll view inside the page.
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(viewModel.debugLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Diagnostics")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One chip per mode, carrying its own registration outcome, so a shortcut the system refused is
    /// visible without opening Diagnostics. The full status stays in the tooltip.
    private func modeChip(for mode: DictationMode) -> some View {
        let failed = viewModel.failedHotKeyModes.contains(mode)
        let shortcut = viewModel.configuration.hotKey(for: mode).displayName

        return statusChip(
            title: failed ? "\(mode.title) unavailable" : "\(shortcut)  \(mode.title)",
            systemImage: failed ? "exclamationmark.triangle.fill" : mode.systemImage,
            tint: failed ? .orange : nil
        )
        .help(viewModel.hotKeyStatus)
    }

    private func statusChip(title: String, systemImage: String, tint: Color? = nil) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((tint ?? Color.secondary).opacity(tint == nil ? 0.1 : 0.15))
            .clipShape(Capsule())
    }

    private var transcriptionModelLabel: String {
        OpenAITranscriptionClient.model
    }

    private var translationSummary: String {
        let configuration = viewModel.configuration
        let source = configuration.translationSourceLanguage?.displayName ?? "Any language"
        return "\(source) → \(configuration.translationTargetLanguage.displayName)\n\(configuration.translationModel.rawValue)"
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
