import Foundation

/// What the user can ask of text already sitting in their document.
///
/// Push-to-talk offers no way to state the intent before speaking, which is why the mode is the
/// shortcut. These are the second chance: the text is already in place, and the choice is made
/// with it in front of you rather than guessed at beforehand.
enum RewriteStyle: String, CaseIterable, Identifiable {
    case professional
    case shorter
    case longer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .professional:
            return "More professional"
        case .shorter:
            return "Shorter"
        case .longer:
            return "Longer"
        }
    }

    var systemImage: String {
        switch self {
        case .professional:
            return "briefcase"
        case .shorter:
            return "arrow.down.right.and.arrow.up.left"
        case .longer:
            return "arrow.up.left.and.arrow.down.right"
        }
    }

    fileprivate var instruction: String {
        switch self {
        case .professional:
            return "Rewrite it to sound more professional: measured, precise, and appropriate for work correspondence."
        case .shorter:
            return "Rewrite it to say the same thing in fewer words."
        case .longer:
            return "Rewrite it more fully: spell out what is implied and let the sentences breathe."
        }
    }

    /// Shortening is the one style that is allowed to drop words, so it needs its own line about
    /// what may go. Without it the rule against removing information forbids the whole point of the
    /// button; with it, filler goes and facts stay.
    fileprivate var preservationRule: String {
        switch self {
        case .professional:
            return "Do not add information and do not remove information."
        case .shorter:
            return "Do not add information. Remove only filler, hedging, and repetition — every fact, name, and number must survive."
        case .longer:
            // The dangerous one. Asked for more words, a model will happily supply more substance,
            // and the user would be inserting claims they never made.
            return "Do not add information: use more words for what is already there, and never introduce a fact, number, promise, or detail the message does not contain."
        }
    }
}

enum OpenAIRewriteError: LocalizedError {
    case invalidResponse
    case requestFailed(String)
    case emptyChoice

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The rewrite API returned an invalid response."
        case .requestFailed(let message):
            return message
        case .emptyChoice:
            return "The rewrite API returned an empty message."
        }
    }
}

final class OpenAIRewriteClient {
    private static let requestTimeout: TimeInterval = 60
    private static let resourceTimeout: TimeInterval = 120

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

    /// The text is already in somebody's document, so the rewrite changes how it reads and nothing
    /// else — same language, same facts, same claims. A "more professional" rewrite that quietly
    /// adds a commitment or drops a number would be worse than no rewrite at all.
    static func systemPrompt(for style: RewriteStyle) -> String {
        """
        You rewrite a message the user has already written.
        \(style.instruction)
        Keep the same language as the message: never translate it.
        Preserve the meaning, facts, names, numbers, and any formatting.
        \(style.preservationRule)
        Do not answer the message and do not continue it.
        Return only the rewritten message, with no explanation, quotes, labels, or extra lines.
        """
    }

    func rewrite(_ text: String, style: RewriteStyle, model: String, apiKey: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: model,
                serviceTier: "priority",
                reasoningEffort: "none",
                temperature: 0.3,
                messages: [
                    .init(role: "system", content: Self.systemPrompt(for: style)),
                    .init(role: "user", content: trimmed)
                ]
            )
        )

        let session = Self.makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIRewriteError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw OpenAIRewriteError.requestFailed(String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)")
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw OpenAIRewriteError.emptyChoice
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
