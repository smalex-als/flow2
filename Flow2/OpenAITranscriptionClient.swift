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
            return "The transcription network request failed or timed out after \(attempts) attempts. Check network, VPN, or proxy connectivity, then retry from history."
        }
    }
}

final class OpenAITranscriptionClient {
    private static let maxAttempts = 3
    private static let requestTimeout: TimeInterval = 60
    private static let resourceTimeout: TimeInterval = 180

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
            "Transcription request prepared: file=\(audioFileURL.lastPathComponent), \(fileDescription), bodyBytes=\(body.count), model=\(model), requestTimeout=\(Int(Self.requestTimeout))s, resourceTimeout=\(Int(Self.resourceTimeout))s, transport=freshEphemeralURLSession"
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
                let session = Self.makeSession()
                defer { session.finishTasksAndInvalidate() }
                (data, response) = try await session.upload(for: request, from: body)
                let elapsed = Self.formatElapsed(Date().timeIntervalSince(startedAt))
                onLog?("Transcription upload finished: attempt=\(attempt)/\(Self.maxAttempts), elapsed=\(elapsed), responseBytes=\(data.count)")
            } catch let error as URLError where Self.shouldRetry(error) && attempt < Self.maxAttempts {
                let elapsedSeconds = Date().timeIntervalSince(startedAt)
                let errorDescription = Self.describe(error: error)
                lastRetryableError = error
                onLog?(
                    "Transcription attempt failed, retrying: attempt=\(attempt)/\(Self.maxAttempts), elapsed=\(Self.formatElapsed(elapsedSeconds)), \(errorDescription)"
                )
                try? await Task.sleep(for: Self.retryDelay(for: attempt))
                continue
            } catch let error as URLError where Self.shouldRetry(error) {
                let elapsedSeconds = Date().timeIntervalSince(startedAt)
                let errorDescription = Self.describe(error: error)
                lastRetryableError = error
                onLog?(
                    "Transcription attempt failed, no retries left: attempt=\(attempt)/\(Self.maxAttempts), elapsed=\(Self.formatElapsed(elapsedSeconds)), \(errorDescription)"
                )
                break
            } catch {
                let elapsedSeconds = Date().timeIntervalSince(startedAt)
                let errorDescription = Self.describe(error: error)
                onLog?(
                    "Transcription attempt failed with non-retryable error: attempt=\(attempt)/\(Self.maxAttempts), elapsed=\(Self.formatElapsed(elapsedSeconds)), \(errorDescription)"
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
                    "Transcription succeeded: attempt=\(attempt)/\(Self.maxAttempts), elapsed=\(Self.formatElapsed(Date().timeIntervalSince(startedAt))), transcriptChars=\(finalText.count)"
                )
                return finalText
            } catch {
                let errorDescription = Self.describe(error: error)
                onLog?(
                    "Transcription decode failed: attempt=\(attempt)/\(Self.maxAttempts), \(errorDescription), body=\(Self.summarizeResponseBody(data))"
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
        body.append(string: "Content-Type: \(mimeType(for: audioFileURL))\r\n\r\n")
        body.append(audioData)
        body.append(string: "\r\n")

        body.append(string: "--\(boundary)--\r\n")
        return body
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }

    private static func shouldRetry(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/m4a"
        default:
            return "application/octet-stream"
        }
    }

    private static func retryDelay(for attempt: Int) -> Duration {
        switch attempt {
        case 1:
            return .seconds(1)
        case 2:
            return .seconds(3)
        default:
            return .seconds(5)
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

    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
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
