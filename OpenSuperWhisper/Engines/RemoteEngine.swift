import Foundation

/// Transcription engine that delegates to a remote OpenAI-compatible server
/// (Groq, speaches, a LiteLLM front door, a local Ollama-style endpoint, …)
/// instead of running a model on-device.
///
/// The server URL, model name, and an optional API key are read from
/// `AppPreferences`. Authentication is optional: when the API key is empty no
/// `Authorization` header is sent, so no-auth servers work unchanged.
///
/// Translation uses OpenAI's separate `/v1/audio/translations` endpoint (which
/// always outputs English and ignores `language`), matching the OpenAI spec;
/// plain transcription uses `/v1/audio/transcriptions`.
class RemoteEngine: TranscriptionEngine {
    var engineName: String { "Remote" }

    private var serverURL: String = ""
    private var modelName: String = ""
    private var apiKey: String = ""
    private var timeoutEnabled: Bool = true
    private var timeoutSeconds: Double = 60
    private var currentTask: Task<String, Error>?

    // Stand-in for "no timeout" when the user disables it — a year, far longer
    // than any transcription, without the edge cases of `.infinity`.
    private static let noTimeoutInterval: TimeInterval = 31_536_000

    var onProgressUpdate: ((Float) -> Void)?

    /// Loaded once a server URL is configured. The remote model itself is not
    /// fetched locally, so "loaded" just means we have somewhere to call.
    var isModelLoaded: Bool {
        !serverURL.isEmpty
    }

    func initialize() async throws {
        let prefs = AppPreferences.shared
        serverURL = prefs.remoteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = prefs.remoteServerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = (prefs.remoteServerAPIKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        timeoutEnabled = prefs.remoteServerTimeoutEnabled
        timeoutSeconds = prefs.remoteServerTimeoutSeconds

        guard !serverURL.isEmpty, endpoint(for: "transcriptions") != nil else {
            throw TranscriptionError.contextInitializationFailed
        }
    }

    func cancelTranscription() {
        currentTask?.cancel()
        currentTask = nil
    }

    func getSupportedLanguages() -> [String] {
        // The remote server decides language support; advertise none so the UI
        // offers the full list and we forward the user's choice verbatim.
        []
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        // OpenAI splits transcribe vs translate into two endpoints; the translations
        // endpoint always outputs English and ignores `language`.
        let translate = settings.translateToEnglish
        guard let endpoint = endpoint(for: translate ? "translations" : "transcriptions") else {
            throw TranscriptionError.contextInitializationFailed
        }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw TranscriptionError.processingFailed }

            self.onProgressUpdate?(0.05)
            try Task.checkCancellation()

            let audioData = try Data(contentsOf: url)
            let boundary = "Boundary-\(UUID().uuidString)"
            let request = self.makeRequest(
                endpoint: endpoint,
                boundary: boundary,
                filename: url.lastPathComponent,
                audioData: audioData,
                language: translate ? "" : settings.selectedLanguage,
                temperature: settings.temperature,
                prompt: settings.initialPrompt
            )

            self.onProgressUpdate?(0.2)
            let session = self.makeSession()
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            self.onProgressUpdate?(0.9)

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("RemoteEngine HTTP error: \(body)")
                throw TranscriptionError.processingFailed
            }

            let text = Self.extractText(from: data)
            self.onProgressUpdate?(1.0)
            return text
        }

        currentTask = task
        defer { currentTask = nil }

        do {
            return try await task.value
        } catch is CancellationError {
            throw TranscriptionError.processingFailed
        }
    }

    // MARK: - Helpers

    /// A URLSession whose request/resource timeouts honor the user's remote
    /// timeout setting. When disabled, an effectively-unbounded interval is used
    /// so slow server-side pipelines aren't cut off at URLSession's 60s default.
    /// POST-with-body ignores `URLRequest.timeoutInterval` in practice, so the
    /// interval must live on the session configuration.
    private func makeSession() -> URLSession {
        let interval = timeoutEnabled
            ? max(1, timeoutSeconds)
            : Self.noTimeoutInterval
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = interval
        config.timeoutIntervalForResource = interval
        return URLSession(configuration: config)
    }

    /// Build `<base>/v1/audio/<action>` (action = "transcriptions" | "translations"),
    /// tolerating a base URL that may or may not already include a trailing slash
    /// or `/v1` segment.
    private func endpoint(for action: String) -> URL? {
        var base = serverURL
        // Default to http:// when no scheme is given (LAN servers like
        // speaches/LiteLLM are commonly plain HTTP); leave explicit https alone.
        let lower = base.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            base = "http://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + "/v1/audio/\(action)")
    }

    private func makeRequest(
        endpoint: URL,
        boundary: String,
        filename: String,
        audioData: Data,
        language: String,
        temperature: Double,
        prompt: String
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var fields: [(String, String)] = [("response_format", "json")]
        if !modelName.isEmpty { fields.append(("model", modelName)) }
        // The translations endpoint ignores `language` (output is always English),
        // so the caller passes an empty language string for translation.
        if !language.isEmpty, language != "auto" { fields.append(("language", language)) }
        // OpenAI-standard transcription params, forwarded for servers that honor
        // them (speaches, LiteLLM). Only sent when set, so server defaults stand.
        if temperature > 0 { fields.append(("temperature", String(temperature))) }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty { fields.append(("prompt", trimmedPrompt)) }

        var body = Data()
        let prefix = "--\(boundary)\r\n"
        for (name, value) in fields {
            body.append(prefix.data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append(prefix.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        return request
    }

    /// OpenAI returns `{"text": "..."}`; tolerate a bare string or `result` key.
    private static func extractText(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = json["text"] as? String { return text }
            if let text = json["result"] as? String { return text }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
