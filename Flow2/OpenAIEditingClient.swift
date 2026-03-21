import Foundation

enum OpenAIEditingError: LocalizedError {
    case invalidResponse
    case requestFailed(String)
    case emptyChoice

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The AI editing API returned an invalid response."
        case .requestFailed(let message):
            return message
        case .emptyChoice:
            return "The AI editing API returned an empty message."
        }
    }
}

final class OpenAIEditingClient {
    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let temperature: Double
        let messages: [Message]
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

    func rewriteLatestMessage(latestMessage: String, previousMessages: [String], translateToEnglish: Bool, apiKey: String) async throws -> String {
        let trimmedLatestMessage = latestMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLatestMessage.isEmpty else {
            return trimmedLatestMessage
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt: String
        if translateToEnglish {
            systemPrompt = """
            You edit only the latest user message using the previous messages for context.
            Return only the rewritten latest message in English.
            Fix recognition mistakes, punctuation, grammar, and wording, keep the user's meaning, and translate the final result to natural English.
            Do not add explanations, quotes, prefixes, labels, or extra lines.
            """
        } else {
            systemPrompt = """
            You edit only the latest user message using the previous messages for context.
            Return only the rewritten latest message.
            Preserve the original language unless the text itself clearly requests translation.
            Fix recognition mistakes, punctuation, grammar, and wording, but keep the user's meaning.
            Do not add explanations, quotes, prefixes, labels, or extra lines.
            """
        }

        let previousContext = previousMessages.enumerated().map { index, message in
            "\(index + 1). \(message)"
        }.joined(separator: "\n")

        let userPrompt: String
        if previousContext.isEmpty {
            userPrompt = """
            Latest message:
            \(trimmedLatestMessage)
            """
        } else {
            userPrompt = """
            Previous messages:
            \(previousContext)

            Latest message:
            \(trimmedLatestMessage)
            """
        }

        let body = RequestBody(
            model: AppConfiguration.defaultEditingModel,
            temperature: 0.2,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ]
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
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
}
