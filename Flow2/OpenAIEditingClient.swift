import Foundation

enum OpenAIEditingError: LocalizedError {
    case invalidResponse
    case requestFailed(String)
    case emptyChoice
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The AI post-processing API returned an invalid response."
        case .requestFailed(let message):
            return message
        case .emptyChoice:
            return "The AI post-processing API returned an empty message."
        case .timedOut:
            return "The AI post-processing request timed out."
        }
    }
}

final class OpenAIEditingClient {
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

    func processLatestMessage(latestMessage: String, previousMessages: [String], preferredTerms: [String], model: String, enableEditing: Bool, translateToEnglish: Bool, apiKey: String) async throws -> String {
        let trimmedLatestMessage = latestMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLatestMessage.isEmpty else {
            return trimmedLatestMessage
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt: String
        switch (enableEditing, translateToEnglish) {
        case (true, true):
            systemPrompt = """
            You edit only the latest user message using the previous messages for context.
            Return only the rewritten latest message in English.
            Fix recognition mistakes, punctuation, grammar, and wording, keep the user's meaning, and translate the final result to natural English.
            Treat the preferred terms list as authoritative. If the latest message seems to refer to one of those terms, prefer that spelling in the final answer.
            The final answer must be English only. Do not output Russian or any Cyrillic characters.
            Do not add explanations, quotes, prefixes, labels, or extra lines.
            """
        case (true, false):
            systemPrompt = """
            You edit only the latest user message using the previous messages for context.
            Return only the rewritten latest message.
            Preserve the original language unless the text itself clearly requests translation.
            Fix recognition mistakes, punctuation, grammar, and wording, but keep the user's meaning.
            Treat the preferred terms list as authoritative. If the latest message seems to refer to one of those terms, prefer that spelling in the final answer.
            Do not add explanations, quotes, prefixes, labels, or extra lines.
            """
        case (false, true):
            systemPrompt = """
            Translate only the latest user message from Russian into natural English, using the previous messages only to resolve context.
            Preserve the meaning, tone, emphasis, names, numbers, and formatting of the latest message.
            Do not correct, rewrite, summarize, or add information beyond changes required for an accurate natural translation.
            Treat the preferred terms list as authoritative.
            Return English only. Do not output Russian or any Cyrillic characters.
            Do not add explanations, quotes, prefixes, labels, or extra lines.
            """
        case (false, false):
            return trimmedLatestMessage
        }

        let strictEnglishRetryPrompt = enableEditing
            ? """
              Rewrite only the latest message in natural English.
              Return one plain sentence or paragraph in English only.
              Treat the preferred terms list as authoritative.
              Do not output Russian or any Cyrillic characters.
              Do not add explanations, quotes, prefixes, labels, or extra lines.
              """
            : """
              Translate only the latest message from Russian into natural English.
              Preserve its meaning, tone, names, numbers, and formatting without rewriting or adding information.
              Return English only. Do not output Russian or any Cyrillic characters.
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

        let content = try await performRequest(
            request: request,
            model: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )

        if translateToEnglish, containsCyrillic(content) {
            return try await performRequest(
                request: request,
                model: model,
                systemPrompt: strictEnglishRetryPrompt,
                userPrompt: userPrompt
            )
        }

        return content
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
            throw OpenAIEditingError.timedOut
        } catch {
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIEditingError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw OpenAIEditingError.requestFailed(message)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw OpenAIEditingError.emptyChoice
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

    private func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0400 ... 0x04FF).contains(scalar.value) || (0x0500 ... 0x052F).contains(scalar.value)
        }
    }
}
