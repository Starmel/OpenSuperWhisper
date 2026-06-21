import Foundation

/// Cleans up a transcription with a local LLM. Currently backed by Ollama's HTTP API
/// (http://localhost:11434 by default), behind a single `process` entry point so another
/// backend (Apple MLX, llama.cpp…) can be swapped in later without touching the call sites.
///
/// `process` never throws and never loses the transcription: if post-processing is disabled
/// or the LLM call fails (Ollama not running, bad model, timeout…), it returns the input text.
enum LLMPostProcessor {
    static func process(_ text: String) async -> String {
        let prefs = AppPreferences.shared
        guard prefs.aiPostProcessingEnabled else { return text }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        do {
            let cleaned = try await ollamaChat(
                endpoint: prefs.aiOllamaEndpoint,
                model: prefs.aiOllamaModel,
                system: prefs.aiPostProcessingPrompt,
                user: text)
            let result = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? text : result
        } catch {
            print("AI post-processing failed, using the raw transcription: \(error)")
            return text
        }
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    private static func ollamaChat(endpoint: String, model: String, system: String, user: String) async throws -> String {
        guard let base = URL(string: endpoint.trimmingCharacters(in: .whitespaces)) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: base.appendingPathComponent("api/chat"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
    }
}
