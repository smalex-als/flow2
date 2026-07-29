import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case recorderCreationFailed
    case noActiveRecording
    case recordingFinalizationFailed
    case recordingTooShort

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission was denied."
        case .recorderCreationFailed:
            return "Could not create an audio recorder."
        case .noActiveRecording:
            return "There is no active recording."
        case .recordingFinalizationFailed:
            return "The recording could not be finalized."
        case .recordingTooShort:
            return "The recording was too short to transcribe."
        }
    }
}

/// Owns the on-disk lifetime of recorded audio. A recording is only kept while something can still
/// consume it: until transcription succeeds, or until the failed-recording entry offering `Retry`
/// is gone from history.
enum RecordingFileStore {
    static let directory: URL = {
        let base = AppStoragePaths.baseDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func delete(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes every recording no history entry can still retry, including leftovers from earlier
    /// runs that crashed or were killed mid-flow.
    @discardableResult
    static func pruneOrphans(keeping retainedPaths: Set<String>) -> (count: Int, bytes: Int64) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var count = 0
        var bytes: Int64 = 0

        for url in contents where !retainedPaths.contains(url.path) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            do {
                try FileManager.default.removeItem(at: url)
                count += 1
                bytes += Int64(size)
            } catch {
                continue
            }
        }

        return (count, bytes)
    }
}

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private var finishContinuation: CheckedContinuation<Bool, Never>?

    func start() async throws -> URL {
        let granted = await Self.ensureMicrophonePermission()
        guard granted else {
            throw AudioRecorderError.microphonePermissionDenied
        }

        let fileURL = RecordingFileStore.directory
            .appendingPathComponent("recording-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AudioRecorderError.recorderCreationFailed
        }

        self.recorder = recorder
        self.currentFileURL = fileURL
        return fileURL
    }

    func stop() async throws -> URL {
        guard let recorder, let currentFileURL else {
            throw AudioRecorderError.noActiveRecording
        }

        let duration = recorder.currentTime
        guard duration >= 0.15 else {
            recorder.stop()
            self.recorder = nil
            self.currentFileURL = nil
            RecordingFileStore.delete(at: currentFileURL)
            throw AudioRecorderError.recordingTooShort
        }

        let finished = await withCheckedContinuation { continuation in
            finishContinuation = continuation
            recorder.stop()
        }

        self.recorder = nil
        self.currentFileURL = nil

        guard finished else {
            throw AudioRecorderError.recordingFinalizationFailed
        }

        return currentFileURL
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            finishContinuation?.resume(returning: flag)
            finishContinuation = nil
        }
    }

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
