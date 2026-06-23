import AVFoundation
import Foundation

/// Cloud transcription via Groq's OpenAI-compatible Speech-to-Text API (#64).
///
/// ⚠️ Unlike Whisper / Parakeet / SenseVoice, this is NOT on-device: the audio file is uploaded to
/// Groq's servers. It is very fast (server-side whisper-large-v3). Requires a Groq API key.
///
/// API integration approach credited to @Schreezer's upstream PR
/// (Starmel/OpenSuperWhisper#64). Reimplemented against this fork's `TranscriptionEngine` protocol.
final class GroqEngine: TranscriptionEngine {
    static let models = ["whisper-large-v3-turbo", "whisper-large-v3"]
    /// Only the full model can translate to English; the turbo model is transcription-only.
    static let translatingModel = "whisper-large-v3"

    private let endpoint = "https://api.groq.com/openai/v1/audio"
    private var currentTask: Task<Void, Never>?

    var isModelLoaded: Bool { (AppPreferences.shared.groqAPIKey ?? "").isEmpty == false }
    var engineName: String { "Groq" }

    func initialize() async throws {
        guard let key = AppPreferences.shared.groqAPIKey, !key.isEmpty else {
            throw GroqError.missingAPIKey
        }
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let key = AppPreferences.shared.groqAPIKey, !key.isEmpty else {
            throw GroqError.missingAPIKey
        }
        let model = AppPreferences.shared.groqModel
        let translate = settings.translateToEnglish && model == Self.translatingModel
        let action = translate ? "translations" : "transcriptions"

        var request = URLRequest(url: URL(string: "\(endpoint)/\(action)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audio = try Data(contentsOf: url)
        var body = Data()
        body.appendField("file", filename: url.lastPathComponent, data: audio, boundary: boundary)
        body.appendField("model", model, boundary: boundary)
        body.appendField("response_format", "json", boundary: boundary)
        // The translations endpoint ignores `language` (output is always English).
        if !translate, settings.selectedLanguage != "auto", !settings.selectedLanguage.isEmpty {
            body.appendField("language", settings.selectedLanguage, boundary: boundary)
        }
        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GroqError.network(nil) }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(GroqErrorResponse.self, from: data))?.error.message
            if http.statusCode == 401 { throw GroqError.invalidAPIKey }
            throw GroqError.api(http.statusCode, message)
        }
        let result = try JSONDecoder().decode(GroqTranscription.self, from: data)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancelTranscription() {
        currentTask?.cancel()
    }

    func getSupportedLanguages() -> [String] {
        ["auto", "en", "fr", "es", "de", "it", "pt", "nl", "ru", "zh", "ja", "ko", "ar", "hi", "tr", "pl", "uk"]
    }
}

enum GroqError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case network(Error?)
    case api(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Groq API key. Add one in Settings → Model → Groq."
        case .invalidAPIKey: return "Groq rejected the API key (401). Check it in Settings."
        case .network(let e): return "Couldn't reach Groq. \(e?.localizedDescription ?? "Check your connection.")"
        case .api(let code, let msg): return "Groq error \(code): \(msg ?? "request failed")."
        }
    }
}

private struct GroqTranscription: Decodable { let text: String }
private struct GroqErrorResponse: Decodable {
    struct GError: Decodable { let message: String? }
    let error: GError
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
    mutating func appendField(_ name: String, _ value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }
    mutating func appendField(_ name: String, filename: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        append(data)
        append("\r\n")
    }
}
