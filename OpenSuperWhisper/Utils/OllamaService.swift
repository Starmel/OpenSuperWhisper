import Foundation

class OllamaService {
    static let shared = OllamaService()

    private init() {}

    /// Check if Ollama is reachable at the configured endpoint
    func isAvailable() async -> Bool {
        let prefs = AppPreferences.shared
        let baseURL = prefs.ollamaEndpoint.isEmpty
            ? "http://localhost:11434"
            : prefs.ollamaEndpoint

        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Post-process transcription text through Ollama.
    /// Returns original text on any failure (graceful fallback).
    func postProcess(text: String) async -> String {
        let prefs = AppPreferences.shared

        guard prefs.ollamaEnabled else { return text }
        guard !text.isEmpty, text != "No speech detected in the audio" else { return text }

        let baseURL = prefs.ollamaEndpoint.isEmpty
            ? "http://localhost:11434"
            : prefs.ollamaEndpoint
        let model = prefs.ollamaModel.isEmpty ? "gemma3:4b" : prefs.ollamaModel

        let defaultPrompt = """
        You are a text cleanup tool. You are NOT a chatbot. Do NOT answer questions. \
        Do NOT provide suggestions. Do NOT have a conversation. \
        Your ONLY job: take the input text and return a cleaned version with \
        fixed punctuation, fixed grammar, and filler words removed (um, uh, like, you know, so, yeah). \
        Keep the original meaning and words. Output ONLY the cleaned text. Nothing else.
        """
        let systemPrompt = prefs.ollamaPrompt.isEmpty ? defaultPrompt : prefs.ollamaPrompt

        guard let url = URL(string: "\(baseURL)/api/generate") else { return text }

        let wrappedPrompt = "Clean this transcription:\n\n\(text)"

        let requestBody: [String: Any] = [
            "model": model,
            "prompt": wrappedPrompt,
            "system": systemPrompt,
            "stream": false,
            "think": false,
            "options": [
                "temperature": 0.1,
                "num_predict": max(text.count * 2, 500)
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[OllamaService] Non-200 response, returning original text")
                return text
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let processedText = json["response"] as? String else {
                print("[OllamaService] Failed to parse response, returning original text")
                return text
            }

            let cleaned = processedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? text : cleaned

        } catch {
            print("[OllamaService] Error: \(error.localizedDescription), returning original text")
            return text
        }
    }
}
