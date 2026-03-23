import Foundation

enum OpenAITranscriptionError: LocalizedError {
    case invalidResponse
    case requestFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The API returned an invalid response."
        case .requestFailed(let message):
            return message
        case .timedOut:
            return "The transcription request timed out."
        }
    }
}

final class OpenAITranscriptionClient {
    private static let requestTimeout: TimeInterval = 15
    private static let resourceTimeout: TimeInterval = 20

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

    func transcribe(audioFileURL: URL, apiKey: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = try makeMultipartBody(audioFileURL: audioFileURL, model: model, boundary: boundary)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.upload(for: request, from: body)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAITranscriptionError.timedOut
        } catch {
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptionError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw OpenAITranscriptionError.requestFailed(message)
        }

        let decoded = try JSONDecoder().decode(AudioResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
}

private extension Data {
    mutating func append(string: String) {
        append(Data(string.utf8))
    }
}
