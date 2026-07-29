import Foundation

enum OpenAITranslationError: LocalizedError {
    case invalidResponse
    case requestFailed(String)
    case emptyChoice
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The translation API returned an invalid response."
        case .requestFailed(let message):
            return message
        case .emptyChoice:
            return "The translation API returned an empty message."
        case .timedOut:
            return "The translation request timed out."
        }
    }
}

final class OpenAITranslationClient {
    private static let requestTimeout: TimeInterval = 180
    private static let resourceTimeout: TimeInterval = 300

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let serviceTier: String
        let reasoningEffort: String
        let temperature: Double
        let messages: [Message]

        private enum CodingKeys: String, CodingKey {
            case model
            case serviceTier = "service_tier"
            case reasoningEffort = "reasoning_effort"
            case temperature
            case messages
        }
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }

            let message: Message
        }

        let choices: [Choice]
    }

    func translateLatestMessage(latestMessage: String, previousMessages: [String], preferredTerms: [String], model: String, sourceLanguage: TranslationLanguage?, targetLanguage: TranslationLanguage, apiKey: String) async throws -> String {
        let trimmedLatestMessage = latestMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLatestMessage.isEmpty else {
            return trimmedLatestMessage
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let target = targetLanguage.displayName
        let sourceClause = sourceLanguage.map { "from \($0.displayName) " } ?? ""
        // Without a declared source the model has to identify the language itself, and text already
        // in the target has to survive untouched rather than be paraphrased.
        let passthroughClause = sourceLanguage == nil
            ? "If the latest message is already in \(target), return it unchanged.\n"
            : ""

        let systemPrompt = """
        Translate only the latest user message \(sourceClause)into natural \(target), using the previous messages only to resolve context.
        \(passthroughClause)Preserve the meaning, tone, emphasis, names, numbers, and formatting of the latest message.
        Do not correct, rewrite, summarize, or add information beyond changes required for an accurate natural translation.
        Treat the preferred terms list as authoritative.
        Return \(target) only.
        Do not add explanations, quotes, prefixes, labels, or extra lines.
        """

        let previousContext = previousMessages.enumerated().map { index, message in
            "\(index + 1). \(message)"
        }.joined(separator: "\n")

        let dictionaryContext = preferredTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" }
            .compactMap { $0 }
            .joined(separator: "\n")

        let userPrompt: String
        if previousContext.isEmpty, dictionaryContext.isEmpty {
            userPrompt = """
            Latest message:
            \(trimmedLatestMessage)
            """
        } else if previousContext.isEmpty {
            userPrompt = """
            Preferred terms:
            \(dictionaryContext)

            Latest message:
            \(trimmedLatestMessage)
            """
        } else if dictionaryContext.isEmpty {
            userPrompt = """
            Previous messages:
            \(previousContext)

            Latest message:
            \(trimmedLatestMessage)
            """
        } else {
            userPrompt = """
            Previous messages:
            \(previousContext)

            Preferred terms:
            \(dictionaryContext)

            Latest message:
            \(trimmedLatestMessage)
            """
        }

        return try await performRequest(
            request: request,
            model: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }

    private func performRequest(request: URLRequest, model: String, systemPrompt: String, userPrompt: String) async throws -> String {
        var request = request
        let body = RequestBody(
            model: model,
            serviceTier: "priority",
            reasoningEffort: "none",
            temperature: 0.2,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ]
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            let session = Self.makeSession()
            defer { session.finishTasksAndInvalidate() }
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAITranslationError.timedOut
        } catch {
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranslationError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw OpenAITranslationError.requestFailed(message)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw OpenAITranslationError.emptyChoice
        }

        return content
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

}
