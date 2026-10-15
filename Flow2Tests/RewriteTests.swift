import XCTest

@testable import Flow2

/// A reshaped transcript is what the user is about to put in a document, so the model may change
/// the wording and nothing else. These pin down what each button is allowed to ask for.
final class RewriteTests: XCTestCase {
    func testGPT61SolRequestsUseLowReasoningAndOmitTemperature() throws {
        for model in ["gpt-6.1-sol", "gpt-6.1-sol-2026-10-01"] {
            let translation = OpenAITranslationClient.RequestBody(
                model: model, serviceTier: "priority", temperature: 0.2,
                messages: [.init(role: "user", content: "Hello")]
            )
            let rewrite = OpenAIRewriteClient.RequestBody(
                model: model, serviceTier: "priority", temperature: 0.3,
                messages: [.init(role: "user", content: "Hello")]
            )
            for data in [try JSONEncoder().encode(translation), try JSONEncoder().encode(rewrite)] {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(json["reasoning_effort"] as? String, "low")
                XCTAssertNil(json["temperature"])
                XCTAssertEqual(json["model"] as? String, model)
                XCTAssertEqual(json["service_tier"] as? String, "priority")
            }
        }
    }

    func testExistingModelsKeepTheirRequestParameters() throws {
        for model in ["gpt-6-luna", "gpt-6-sol", "gpt-6-astra"] {
            let translation = OpenAITranslationClient.RequestBody(
                model: model, serviceTier: "priority", temperature: 0.2, messages: []
            )
            let rewrite = OpenAIRewriteClient.RequestBody(
                model: model, serviceTier: "priority", temperature: 0.3, messages: []
            )
            for (data, temperature) in [(try JSONEncoder().encode(translation), 0.2),
                                        (try JSONEncoder().encode(rewrite), 0.3)] {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(json["reasoning_effort"] as? String, "none")
                XCTAssertEqual(json["temperature"] as? Double, temperature)
            }
        }
    }

    // MARK: - What the model is asked for

    func testEachStyleAsksForItsOwnChange() {
        XCTAssertTrue(OpenAIRewriteClient.systemPrompt(for: .professional).contains("more professional"))
        XCTAssertTrue(OpenAIRewriteClient.systemPrompt(for: .shorter).contains("fewer words"))
    }

    /// The text is already in place, so the rewrite may change how it reads and nothing else. A
    /// prompt that let the model translate, answer, or add a fact would corrupt the document while
    /// looking like it worked.
    func testEveryStyleForbidsChangingTheSubstance() {
        for style in RewriteStyle.allCases {
            let prompt = OpenAIRewriteClient.systemPrompt(for: style)

            XCTAssertTrue(prompt.contains("never translate"), "\(style) must not translate")
            XCTAssertTrue(prompt.contains("Do not add information"), "\(style) must not invent")
            XCTAssertTrue(prompt.contains("Preserve the meaning"), "\(style) must not change meaning")
            XCTAssertTrue(prompt.contains("Return only the rewritten message"), "\(style) must not chat")
        }
    }

    /// Shortening is the one style allowed to drop words, and the blanket rule against removing
    /// information would otherwise forbid the whole point of the button. What it may drop has to be
    /// spelled out, or the model is left to decide for itself whether a number counts as filler.
    func testShorteningMayDropWordsButNotFacts() {
        let prompt = OpenAIRewriteClient.systemPrompt(for: .shorter)

        XCTAssertFalse(prompt.contains("do not remove information"),
                       "the blanket rule would contradict the instruction above it")
        XCTAssertTrue(prompt.contains("Remove only filler"))
        XCTAssertTrue(prompt.contains("every fact, name, and number must survive"))
    }

    func testAStyleThatOnlyRewordsKeepsTheBlanketRule() {
        XCTAssertTrue(OpenAIRewriteClient.systemPrompt(for: .professional).contains("do not remove information"))
    }

    /// Lengthening is the dangerous one: asked for more words, a model will happily supply more
    /// substance, and the user would insert claims they never made.
    func testLengtheningMayUseMoreWordsButNotSayMore() {
        let prompt = OpenAIRewriteClient.systemPrompt(for: .longer)

        XCTAssertTrue(prompt.contains("use more words for what is already there"))
        XCTAssertTrue(prompt.contains("never introduce a fact, number, promise, or detail"))
    }

    func testEveryStyleIsDistinctFromTheOthers() {
        let titles = Set(RewriteStyle.allCases.map(\.title))
        let prompts = Set(RewriteStyle.allCases.map(OpenAIRewriteClient.systemPrompt(for:)))

        XCTAssertEqual(titles.count, RewriteStyle.allCases.count, "two buttons must never read the same")
        XCTAssertEqual(prompts.count, RewriteStyle.allCases.count, "two buttons must never do the same")
    }
}
