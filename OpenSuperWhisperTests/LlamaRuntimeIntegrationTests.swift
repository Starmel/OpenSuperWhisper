import XCTest
@testable import OpenSuperWhisper

/// Drives the real Swift wrapper against real weights.
///
/// Skipped when this machine has no transform weights, so CI stays fast and
/// hermetic: this is the test that would catch a wrong llama.cpp API flag, a
/// broken chat template or a mis-tracked sequence position, and none of those
/// can be seen with a fake model.
final class LlamaRuntimeIntegrationTests: XCTestCase {

    /// The instruction model the app downloads for tone and e-mail, as the test
    /// harness places it. Read-only: nothing here writes to the user's model
    /// directory.
    private static var weightsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("models/Qwen2.5-7B-Instruct-Q4_K_M.gguf").path
    }

    /// The English clean-up backend, as the app downloads it. Read-only as well.
    private static var normalizerWeightsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("models/s1-mini-q4_k_m.gguf").path
    }

    private func requireWeights() throws -> String {
        let path = Self.weightsPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no transform weights at \(path)")
        }
        return path
    }

    func testComplete_rewritesPolishInPolishThroughTheRealModel() throws {
        let model = try LlamaModel(modelPath: try requireWeights())
        defer { model.unload() }

        let started = Date()
        let text = try model.complete(
            systemPrompt: TransformService.systemPrompt(
                for: .cleanUpWithTone(language: .polish, tone: .formal),
                cleanUp: true
            ),
            userText: "no więc ja myślę że trzeba wysłać ten raport do klienta jutro rano"
        )
        let elapsed = Date().timeIntervalSince(started)
        print("[LlamaRuntimeIntegrationTests] in-process rewrite: \(String(format: "%.2f", elapsed))s -> \(text)")

        XCTAssertFalse(text.isEmpty, "the model produced nothing")
        XCTAssertFalse(
            text.contains("<|im_start|>"),
            "the chat template must not leak into the answer: \(text)"
        )
        XCTAssertNotNil(
            text.rangeOfCharacter(from: CharacterSet(charactersIn: "ąćęłńóśźżĄĆĘŁŃÓŚŹŻ")),
            "a Polish rewrite must come back in Polish, diacritics and all: \(text)"
        )
    }

    /// The English backend's card requires two things of every request that this
    /// build cannot ask for through a template kwarg: the assistant turn opens
    /// with an empty think block, and the answer is decoded greedily. Both are
    /// facts about the prompt the app sends (`TransformPromptStyle`), so this
    /// drives them through the real wrapper and prints what each one produces.
    ///
    /// The positive direction is asserted. The counter-case is printed, not
    /// asserted: the card says the model "usually" produces nothing usable
    /// without the block, and a test may not pin a "usually".
    func testComplete_theNormalizerIsAnsweredWithItsEmptyThinkPrefix() throws {
        let path = Self.normalizerWeightsPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no weights at \(path)")
        }
        let model = try LlamaModel(modelPath: path)
        defer { model.unload() }

        let dictation = "so um i need to like send the the report by uh friday no wait make that thursday"
        let userText = TransformService.normalizerUserPrompt(for: dictation, tone: nil)

        let withPrefix = try model.complete(
            systemPrompt: TransformService.normalizerSystemPrompt,
            userText: userText,
            assistantPrefix: TransformPromptStyle.normalizer.assistantPrefix,
            greedy: TransformPromptStyle.normalizer.isGreedy
        )
        let withoutPrefix = try model.complete(
            systemPrompt: TransformService.normalizerSystemPrompt,
            userText: userText,
            greedy: TransformPromptStyle.normalizer.isGreedy
        )
        print("[LlamaRuntimeIntegrationTests] with the empty think prefix: \(withPrefix)")
        print("[LlamaRuntimeIntegrationTests] without it: \(withoutPrefix)")
        TestFixtures.report("[s1-mini] with the empty think prefix: \(withPrefix)")
        TestFixtures.report("[s1-mini] without it: \(withoutPrefix)")

        XCTAssertFalse(withPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "with its empty think prefix the normalizer has to answer")
        XCTAssertTrue(withPrefix.lowercased().contains("thursday"),
                      "and the answer is the cleaned dictation: \(withPrefix)")
        XCTAssertFalse(withPrefix.contains("<|im_start|>"), "the template must not leak: \(withPrefix)")
        XCTAssertFalse(withPrefix.contains("\u{3C}think\u{3E}") || withPrefix.contains("\u{3C}/think\u{3E}"),
                       "the empty block is a prompt prefix, not output: \(withPrefix)")
    }

    func testComplete_honoursCancellationBeforeSpendingTimeOnDecoding() throws {
        let model = try LlamaModel(modelPath: try requireWeights())
        defer { model.unload() }

        let started = Date()
        XCTAssertThrowsError(
            try model.complete(systemPrompt: "system", userText: "Cześć", isCancelled: { true })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let elapsed = Date().timeIntervalSince(started)
        print("[LlamaRuntimeIntegrationTests] cancelled transform returned in \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 1.0, "a cancelled request must not wait for generation")
    }

    func testComplete_doesNotCarryOneDictationIntoTheNext() throws {
        // Two prompts, one context: the second must not inherit the first one's
        // sequence (a mis-tracked position shows up as an answer to the wrong
        // question, or as an immediate stop).
        let model = try LlamaModel(modelPath: try requireWeights())
        defer { model.unload() }

        let prompt = TransformService.systemPrompt(for: .cleanUp(language: .polish), cleanUp: true)
        let first = try model.complete(
            systemPrompt: prompt,
            userText: "dziękuję bardzo za pomoc"
        )
        let second = try model.complete(
            systemPrompt: prompt,
            userText: "nie mogę dzisiaj przyjść na spotkanie przepraszam"
        )

        print("[LlamaRuntimeIntegrationTests] first: \(first)")
        print("[LlamaRuntimeIntegrationTests] second: \(second)")
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
        XCTAssertNotEqual(first, second, "two different dictations must not produce the same answer")
    }
}
