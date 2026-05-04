import Foundation

enum LocalWhisperTranscriptionError: LocalizedError {
    case executableMissing(String)
    case failed(status: Int32, output: String)
    case missingOutput(directory: String, output: String)
    case emptyTranscript
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "Local Whisper executable was not found or is not executable: \(path)"
        case .failed(let status, let output):
            return "Local Whisper failed with exit code \(status): \(output)"
        case .missingOutput(let directory, let output):
            return "Local Whisper did not create a transcript file in \(directory). Output: \(output)"
        case .emptyTranscript:
            return "Local Whisper returned an empty transcript."
        case .timedOut(let seconds):
            return "Local Whisper timed out after \(seconds) seconds."
        }
    }
}

final class LocalWhisperTranscriptionClient {
    private struct ProcessResult: Sendable {
        let status: Int32
        let output: String
    }

    private static let timeoutSeconds: TimeInterval = 180

    func transcribe(
        audioFileURL: URL,
        executablePath: String,
        model: String,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let resolvedExecutablePath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.isExecutableFile(atPath: resolvedExecutablePath) else {
            throw LocalWhisperTranscriptionError.executableMissing(resolvedExecutablePath)
        }

        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = resolvedModel.isEmpty ? AppConfiguration.defaultLocalWhisperModel : resolvedModel
        let outputDirectoryURL = try makeOutputDirectory(audioFileURL: audioFileURL)

        onLog?("Local Whisper started: file=\(audioFileURL.lastPathComponent), model=\(modelName), executable=\(resolvedExecutablePath)")

        let startedAt = Date()
        let arguments = [
            audioFileURL.path,
            "--model", modelName,
            "--output_dir", outputDirectoryURL.path,
            "--output_format", "txt",
            "--verbose", "False",
            "--fp16", "False"
        ]

        let result = try await runProcess(
            executablePath: resolvedExecutablePath,
            arguments: arguments,
            timeoutSeconds: Self.timeoutSeconds
        )

        guard result.status == 0 else {
            onLog?("Local Whisper failed: elapsed=\(Self.formatElapsed(since: startedAt)), status=\(result.status), output=\(Self.summarize(result.output))")
            throw LocalWhisperTranscriptionError.failed(status: result.status, output: Self.summarize(result.output))
        }

        let transcript = try readTranscript(in: outputDirectoryURL, processOutput: result.output)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalWhisperTranscriptionError.emptyTranscript
        }

        onLog?("Local Whisper complete: elapsed=\(Self.formatElapsed(since: startedAt)), transcriptChars=\(trimmed.count)")
        return trimmed
    }

    private func makeOutputDirectory(audioFileURL: URL) throws -> URL {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Flow2", isDirectory: true)
            .appendingPathComponent("LocalWhisperRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let timestamp = Self.fileTimestamp(from: Date())
        let stem = audioFileURL.deletingPathExtension().lastPathComponent
        let directoryURL = baseDirectory.appendingPathComponent("\(timestamp)-\(stem)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func runProcess(executablePath: String, arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executablePath)
                    process.arguments = arguments
                    process.environment = Self.processEnvironment()

                    let standardOutput = Pipe()
                    let standardError = Pipe()
                    process.standardOutput = standardOutput
                    process.standardError = standardError

                    try process.run()
                    let startedAt = Date()

                    while process.isRunning {
                        if Date().timeIntervalSince(startedAt) > timeoutSeconds {
                            process.terminate()
                            throw LocalWhisperTranscriptionError.timedOut(seconds: Int(timeoutSeconds))
                        }

                        Thread.sleep(forTimeInterval: 0.1)
                    }

                    let output = Self.readAvailableText(from: standardOutput) + Self.readAvailableText(from: standardError)
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus, output: output))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func readTranscript(in outputDirectoryURL: URL, processOutput: String) throws -> String {
        let urls = try FileManager.default.contentsOfDirectory(
            at: outputDirectoryURL,
            includingPropertiesForKeys: nil
        )
        let transcriptURL = urls.first { $0.pathExtension.lowercased() == "txt" }

        guard let transcriptURL else {
            throw LocalWhisperTranscriptionError.missingOutput(
                directory: outputDirectoryURL.path,
                output: Self.summarize(processOutput)
            )
        }

        return try String(contentsOf: transcriptURL, encoding: .utf8)
    }

    private static func readAvailableText(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"

        if environment["FFMPEG_BINARY"] == nil,
           FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") {
            environment["FFMPEG_BINARY"] = "/opt/homebrew/bin/ffmpeg"
        }

        return environment
    }

    private static func summarize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 500 {
            return trimmed
        }

        return "\(trimmed.prefix(500))..."
    }

    private static func fileTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static func formatElapsed(since startedAt: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(startedAt))
    }
}
