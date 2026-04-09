import Foundation

enum OpenAITranscriptionError: LocalizedError {
    case invalidResponse
    case requestFailed(String)
    case timedOut(attempts: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The API returned an invalid response."
        case .requestFailed(let message):
            return message
        case .timedOut(let attempts):
            return "The transcription request timed out after \(attempts) attempts."
        }
    }
}

final class OpenAITranscriptionClient {
    private static let maxAttempts = 3
    private static let requestTimeout: TimeInterval = 5
    private static let resourceTimeout: TimeInterval = 8

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private struct AudioResponse: Decodable {
        let text: String
    }

    func transcribe(
        audioFileURL: URL,
        apiKey: String,
        model: String,
        onAttempt: (@Sendable (Int, Int) -> Void)? = nil,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        var lastRetryableError: URLError?
        let fileDescription = Self.describeFile(at: audioFileURL)
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = try makeMultipartBody(audioFileURL: audioFileURL, model: model, boundary: boundary)

        onLog?(
            "Transcription request prepared: file=\(audioFileURL.lastPathComponent), \(fileDescription), bodyBytes=\(body.count), model=\(model), requestTimeout=\(Int(Self.requestTimeout))s, resourceTimeout=\(Int(Self.resourceTimeout))s"
        )

        for attempt in 1 ... Self.maxAttempts {
            onAttempt?(attempt, Self.maxAttempts)
            let startedAt = Date()
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = Self.requestTimeout
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await Self.session.upload(for: request, from: body)
                let elapsed = Self.formatElapsed(since: startedAt)
                onLog?("Transcription upload finished: attempt=\(attempt)/\(Self.maxAttempts), elapsed=\(elapsed), responseBytes=\(data.count)")
            } catch let error as URLError where Self.shouldRetry(error) && attempt < Self.maxAttempts {
                lastRetryableError = error
                onLog?(
                    "Transcription attempt failed, retrying: attempt=\(attempt)/\(Self.maxAttempts), elapsed=\(Self.formatElapsed(since: startedAt)), \(Self.describe(error: error))"
                )
                try? await Task.sleep(for: Self.retryDelay(for: attempt))
                continue
            } catch let error as URLError where Self.shouldRetry(error) {
                lastRetryableError = error
                onLog?(
                    "Transcription attempt failed, no retries left: attempt=\(attempt)/\(Self.maxAttempts), elapsed=\(Self.formatElapsed(since: startedAt)), \(Self.describe(error: error))"
                )
                break
            } catch {
                onLog?(
                    "Transcription attempt failed with non-retryable error: attempt=\(attempt)/\(Self.maxAttempts), elapsed=\(Self.formatElapsed(since: startedAt)), \(Self.describe(error: error))"
                )
                throw error
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                onLog?("Transcription failed: invalid non-HTTP response on attempt \(attempt)/\(Self.maxAttempts)")
                throw OpenAITranscriptionError.invalidResponse
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                onLog?(
                    "Transcription HTTP failure: attempt=\(attempt)/\(Self.maxAttempts), status=\(httpResponse.statusCode), body=\(Self.summarizeResponseBody(data))"
                )
                throw OpenAITranscriptionError.requestFailed(message)
            }

            do {
                let decoded = try JSONDecoder().decode(AudioResponse.self, from: data)
                let finalText = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
                onLog?(
                    "Transcription succeeded: attempt=\(attempt)/\(Self.maxAttempts), elapsed=\(Self.formatElapsed(since: startedAt)), transcriptChars=\(finalText.count)"
                )
                return finalText
            } catch {
                onLog?(
                    "Transcription decode failed: attempt=\(attempt)/\(Self.maxAttempts), \(Self.describe(error: error)), body=\(Self.summarizeResponseBody(data))"
                )
                throw error
            }
        }

        if let lastRetryableError {
            onLog?("Transcription exhausted retries: \(Self.describe(error: lastRetryableError))")
            throw OpenAITranscriptionError.timedOut(attempts: Self.maxAttempts)
        }

        throw OpenAITranscriptionError.invalidResponse
    }

    private func makeMultipartBody(audioFileURL: URL, model: String, boundary: String) throws -> Data {
        let audioData = try Data(contentsOf: audioFileURL)
        var body = Data()

        body.append(string: "--\(boundary)\r\n")
        body.append(string: "Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append(string: "\(model)\r\n")

        body.append(string: "--\(boundary)\r\n")
        body.append(string: "Content-Disposition: form-data; name=\"file\"; filename=\"\(audioFileURL.lastPathComponent)\"\r\n")
        body.append(string: "Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        body.append(string: "\r\n")

        body.append(string: "--\(boundary)--\r\n")
        return body
    }

    private static func shouldRetry(_ error: URLError) -> Bool {
        error.code == .timedOut || error.code == .networkConnectionLost || error.code == .cannotConnectToHost
    }

    private static func retryDelay(for attempt: Int) -> Duration {
        switch attempt {
        case 1:
            return .milliseconds(300)
        case 2:
            return .milliseconds(700)
        default:
            return .seconds(1)
        }
    }

    private static func describeFile(at url: URL) -> String {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "unknown size"
            let modified = values.contentModificationDate.map(Self.format(date:)) ?? "unknown modifiedAt"
            return "size=\(size), modifiedAt=\(modified)"
        } catch {
            return "metadataError=\(describe(error: error))"
        }
    }

    private static func describe(error: Error) -> String {
        let nsError = error as NSError
        if let urlError = error as? URLError {
            return "URLError code=\(urlError.code.rawValue) (\(urlError.code)), localizedDescription=\(urlError.localizedDescription), domain=\(nsError.domain), userInfo=\(sanitize(userInfo: nsError.userInfo))"
        }

        return "errorType=\(String(describing: type(of: error))), localizedDescription=\(error.localizedDescription), domain=\(nsError.domain), code=\(nsError.code), userInfo=\(sanitize(userInfo: nsError.userInfo))"
    }

    private static func sanitize(userInfo: [String: Any]) -> String {
        guard !userInfo.isEmpty else { return "[:]" }
        let sanitized = userInfo.map { key, value in
            let renderedValue: String
            if let url = value as? URL {
                renderedValue = url.absoluteString
            } else {
                renderedValue = String(describing: value)
            }
            return "\(key)=\(renderedValue)"
        }
        .sorted()
        return "[\(sanitized.joined(separator: ", "))]"
    }

    private static func summarizeResponseBody(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 body \(data.count) bytes>"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 400 {
            return trimmed
        }

        let prefix = trimmed.prefix(400)
        return "\(prefix)..."
    }

    private static func formatElapsed(since startedAt: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(startedAt))
    }

    private static func format(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension Data {
    mutating func append(string: String) {
        append(Data(string.utf8))
    }
}
