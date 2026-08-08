import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    /// Everything that acts is pinned at the top, and the one scrolling region below it only shows
    /// what the app has produced. Nothing the user can press moves as the transcript list grows.
    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summarySection
                    transcriptsSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Flow2")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Push-to-talk dictation for macOS. Hold one shortcut to dictate, the other to come back in \(viewModel.configuration.translationTargetLanguage.displayName).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                SettingsLink {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            }

            actionBar
        }
    }

    /// The buttons carry their own shortcut, so the separate row of chips that used to state it is
    /// gone: one control per mode, saying what it does and which key does it without being asked.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if viewModel.isRecording {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.toggleRecording(mode: .dictate)
                        }
                    } label: {
                        Label("Stop Recording", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                    .controlSize(.large)
                } else {
                    // One button per mode: the mode has to be chosen before speaking, not after.
                    ForEach(DictationMode.allCases) { mode in
                        modeButton(for: mode)
                    }
                }

                if viewModel.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(viewModel.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }

            // A shortcut the system refused otherwise just looks like a broken key.
            if !viewModel.failedHotKeyModes.isEmpty {
                noticeRow(viewModel.hotKeyStatus, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }

            if viewModel.isShowingMissingKeyAlert {
                HStack(spacing: 8) {
                    noticeRow("Add your OpenAI API key in Settings before sending audio to OpenAI.",
                              systemImage: "exclamationmark.triangle.fill",
                              tint: .yellow)

                    SettingsLink {
                        Text("Open Settings")
                    }
                }
            }
        }
    }

    private func modeButton(for mode: DictationMode) -> some View {
        let failed = viewModel.failedHotKeyModes.contains(mode)
        let shortcut = viewModel.configuration.hotKey(for: mode).displayName

        return Button {
            Task {
                await viewModel.toggleRecording(mode: mode)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : mode.systemImage)
                    .foregroundStyle(failed ? Color.orange : Color.accentColor)

                Text(mode.title)

                Text(shortcut)
                    .foregroundStyle(.secondary)
            }
        }
        .keyboardShortcut(mode == .dictate ? KeyboardShortcut(.space, modifiers: []) : nil)
        .controlSize(.large)
        .disabled(viewModel.isBusy)
        .help(failed ? viewModel.hotKeyStatus : "Hold \(shortcut) anywhere, or click to record \(mode.shortDescription)")
    }

    private func noticeRow(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The standing facts: what the pipeline is, and what it has produced. One strip rather than a
    /// row of cards — a card gives a figure the weight of a headline, and these are things you
    /// glance at on the way to the transcripts, not the content of the window.
    private var summarySection: some View {
        ViewThatFits(in: .horizontal) {
            summaryRow(showsEveryQualifier: true)
            summaryRow(showsEveryQualifier: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    /// One row of cells, each stacking its value over what qualifies it. Stacked rather than laid
    /// side by side because a cell is then only as wide as its longest line, which is what leaves
    /// room for type big enough to read at a glance — the point of the row in the first place.
    private struct SummaryItem {
        let systemImage: String
        let value: String
        let qualifier: String
        /// Whether the qualifier survives a window too narrow for the full row. The translation
        /// model does: which model rewrote the words is not a footnote about them.
        let isQualifierEssential: Bool
        let help: String
    }

    private var pipelineItems: [SummaryItem] {
        [
            SummaryItem(systemImage: "waveform",
                        value: OpenAITranscriptionClient.model,
                        qualifier: "both modes",
                        isQualifierEssential: false,
                        help: "Speech to text. Runs on every recording, in both modes."),
            SummaryItem(systemImage: "globe",
                        value: translationLanguagePair,
                        qualifier: viewModel.configuration.translationModel.rawValue,
                        isQualifierEssential: true,
                        help: "Runs only when you hold the Dictate & Translate shortcut.")
        ]
    }

    /// Empty until something has been dictated: a row of zeros on a fresh install says nothing.
    private var statisticItems: [SummaryItem] {
        let statistics = viewModel.statistics
        guard statistics.dictations > 0 else { return [] }

        let shortest = Int(DictationStatistics.minimumSecondsForRate)

        return [
            SummaryItem(systemImage: "text.word.spacing",
                        value: "\(statistics.totalWords.formatted()) words",
                        qualifier: "\(statistics.dictations.formatted()) dictations",
                        isQualifierEssential: false,
                        help: "Words dictated since Flow2 started counting."),
            SummaryItem(systemImage: "calendar",
                        value: "\(statistics.wordsPerDay.formatted()) / day",
                        qualifier: "last \(DictationStatistics.recentDays) days",
                        isQualifierEssential: false,
                        help: "Average over the last \(DictationStatistics.recentDays) days, or since your first dictation if that was more recent."),
            SummaryItem(systemImage: "speedometer",
                        value: "\(statistics.wordsPerMinute.formatted()) wpm",
                        qualifier: "over \(shortest)s",
                        isQualifierEssential: false,
                        help: "Measured on recordings longer than \(shortest) seconds, where the pause at each end is not most of the recording.")
        ]
    }

    private func summaryRow(showsEveryQualifier: Bool) -> some View {
        let items = pipelineItems + statisticItems

        return HStack(spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Divider().frame(height: 36)
                }

                summaryItem(item, showsQualifier: showsEveryQualifier || item.isQualifierEssential)
            }

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func summaryItem(_ item: SummaryItem, showsQualifier: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.value)
                    .font(.system(size: 19, weight: .semibold))

                if showsQualifier {
                    Text(item.qualifier)
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .lineLimit(1)
        .help(item.help)
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

    private var translationLanguagePair: String {
        let configuration = viewModel.configuration
        let source = configuration.translationSourceLanguage?.displayName ?? "Any language"
        return "\(source) → \(configuration.translationTargetLanguage.displayName)"
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
