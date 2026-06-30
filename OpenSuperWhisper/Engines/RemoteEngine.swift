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
final class RemoteEngine: TranscriptionEngine {
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

            // Send with bounded retries for TRANSIENT failures only: network blips,
            // 5xx, 408/429, and the "405 + nginx HTML" signature a reverse proxy
            // returns mid-redeploy/restart. Re-sending the same audio has no side
            // effects, so this just rides out a momentary server hiccup. Auth errors
            // (401/403) and real JSON-API 4xx are never retried.
            var attempt = 0
            while true {
                attempt += 1
                try Task.checkCancellation()
                let session = self.makeSession()
                var retry = false
                do {
                    defer { session.finishTasksAndInvalidate() }
                    let (data, response) = try await session.data(for: request)
                    try Task.checkCancellation()

                    guard let http = response as? HTTPURLResponse else {
                        throw RemoteError.network(nil)
                    }
                    if (200..<300).contains(http.statusCode) {
                        self.onProgressUpdate?(1.0)
                        return Self.extractText(from: data)
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        throw self.apiKey.isEmpty ? RemoteError.missingAPIKey : RemoteError.invalidAPIKey
                    }
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("RemoteEngine HTTP \(http.statusCode) (attempt \(attempt)/\(Self.maxAttempts)): \(body)")
                    if attempt < Self.maxAttempts, Self.isRetryable(status: http.statusCode, body: body) {
                        retry = true
                    } else {
                        throw RemoteError.api(http.statusCode, Self.serverMessage(from: data))
                    }
                } catch let urlError as URLError {
                    print("RemoteEngine network error (attempt \(attempt)/\(Self.maxAttempts)): \(urlError.code.rawValue)")
                    guard attempt < Self.maxAttempts, Self.isRetryable(urlError) else {
                        throw RemoteError.network(urlError)
                    }
                    retry = true
                }
                // Reached only when an attempt was deemed retryable.
                if retry {
                    try await Task.sleep(nanoseconds: Self.backoffNanos(afterAttempt: attempt))
                    self.onProgressUpdate?(0.2)
                }
            }
        }

        currentTask = task
        defer { currentTask = nil }

        do {
            return try await task.value
        } catch let error as RemoteError {
            throw error
        } catch is CancellationError {
            // Preserve cancellation as cancellation (house style), don't mask it.
            throw CancellationError()
        } catch {
            throw RemoteError.network(error)
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
        for (name, value) in fields {
            body.appendField(name, value, boundary: boundary)
        }
        body.appendField("file", filename: filename, data: audioData, boundary: boundary)
        body.append("--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }

    // MARK: - Retry policy

    /// Total attempts (1 initial + 2 retries) for a transcription request.
    private static let maxAttempts = 3

    /// Backoff before the next attempt: ~0.5s after the first failure, ~1.5s after
    /// the second — long enough to clear a brief reverse-proxy reload, short enough
    /// not to feel stuck.
    private static func backoffNanos(afterAttempt attempt: Int) -> UInt64 {
        attempt <= 1 ? 500_000_000 : 1_500_000_000
    }

    /// Retry a non-2xx only when it looks like a transient server/infra hiccup, not
    /// a real client error: 5xx, request-timeout/too-many-requests, or the static
    /// "405 Not Allowed" page a reverse proxy (nginx) emits while mid-redeploy.
    private static func isRetryable(status: Int, body: String) -> Bool {
        switch status {
        case 408, 429, 500, 502, 503, 504:
            return true
        case 405:
            // Only the proxy's HTML 405 (server bounce); a real JSON API 405 is not retried.
            return body.localizedCaseInsensitiveContains("nginx")
                || body.localizedCaseInsensitiveContains("<html")
        default:
            return false
        }
    }

    /// Retry transient transport errors (timeouts, dropped/again-unavailable
    /// connections), but not e.g. a bad URL or cancellation.
    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable,
             .badServerResponse:
            return true
        default:
            return false
        }
    }

    /// OpenAI returns `{"text": "..."}`; tolerate a bare string or `result` key.
    private static func extractText(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = json["text"] as? String { return text }
            if let text = json["result"] as? String { return text }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Pull a human-readable message from an error body — OpenAI-style
    /// `{"error": {"message": "…"}}` or `{"error": "…"}`, else the raw text.
    private static func serverMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let err = json["error"] as? String { return err }
            if let msg = json["message"] as? String { return msg }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
}

/// User-facing remote-server failures. Mirrors the (now-folded-in) Groq engine's
/// error style: cloud/remote failures are common and actionable, so they get
/// descriptive messages instead of the bare on-device `TranscriptionError`.
enum RemoteError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case network(Error?)
    case api(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "The server requires an API key. Add one in Settings → Engine & Model → Remote (lock icon)."
        case .invalidAPIKey:
            return "The server rejected the API key. Check it in Settings → Engine & Model → Remote."
        case .network(let e):
            return "Couldn't reach the remote server. \(e?.localizedDescription ?? "Check the URL and your connection.")"
        case .api(let code, let msg):
            return "Remote server error \(code): \(msg ?? "request failed")."
        }
    }
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
        append("Content-Type: audio/wav\r\n\r\n")
        append(data)
        append("\r\n")
    }
}
