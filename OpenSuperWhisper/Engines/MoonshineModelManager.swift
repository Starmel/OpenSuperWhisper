import Foundation

/// Downloads and locates Moonshine **v2** models (sherpa-onnx) per language. Each language is a
/// separate `encoder_model.ort` + `decoder_model_merged.ort` + `tokens.txt` (~134 MB) kept under
/// Application Support, so the user can install only the language(s) they need.
final class MoonshineModelManager {
    static let shared = MoonshineModelManager()
    private init() {}

    /// Languages available as Moonshine v2 `base` models (sherpa-onnx, 2026-02-27). English first
    /// (default), Vietnamese second (issue #10).
    struct Language: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let languages: [Language] = [
        .init(code: "en", name: "English"),
        .init(code: "vi", name: "Vietnamese"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "es", name: "Spanish"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "uk", name: "Ukrainian"),
    ]

    static func displayName(for code: String) -> String {
        languages.first { $0.code == code }?.name ?? code
    }

    private let rootDir = "moonshine-models"
    private let files = ["tokens.txt", "encoder_model.ort", "decoder_model_merged.ort"]

    /// The currently-selected language; the engine reads this when it loads.
    var language: String { AppPreferences.shared.moonshineLanguage }

    private func repoURL(_ lang: String) -> String {
        "https://huggingface.co/csukuangfj2/sherpa-onnx-moonshine-base-\(lang)-quantized-2026-02-27/resolve/main"
    }

    private func directory(for lang: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier!)
            .appendingPathComponent(rootDir)
            .appendingPathComponent(lang)
    }

    func encoderPath(for lang: String) -> URL { directory(for: lang).appendingPathComponent("encoder_model.ort") }
    func mergedDecoderPath(for lang: String) -> URL { directory(for: lang).appendingPathComponent("decoder_model_merged.ort") }
    func tokensPath(for lang: String) -> URL { directory(for: lang).appendingPathComponent("tokens.txt") }

    // Convenience accessors for the currently-selected language (used by the engine).
    var encoderPath: URL { encoderPath(for: language) }
    var mergedDecoderPath: URL { mergedDecoderPath(for: language) }
    var tokensPath: URL { tokensPath(for: language) }

    func isDownloaded(_ lang: String) -> Bool {
        let fm = FileManager.default
        return files.allSatisfy { fm.fileExists(atPath: directory(for: lang).appendingPathComponent($0).path) }
    }
    var isDownloaded: Bool { isDownloaded(language) }

    /// Approximate on-disk size of one language, for display.
    var downloadSizeString: String { "≈ 134 MB" }

    /// Download every file for `lang`. `progress` reports 0…1.
    func download(_ lang: String, progress: @escaping (Double) -> Void) async throws {
        let dir = directory(for: lang)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let count = Double(files.count)
        for (index, name) in files.enumerated() {
            guard let url = URL(string: "\(repoURL(lang))/\(name)?download=true") else {
                throw TranscriptionError.processingFailed
            }
            try await download(from: url, to: dir.appendingPathComponent(name)) { p in
                progress((Double(index) + p) / count)
            }
        }
        progress(1.0)
    }

    private func download(from url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.processingFailed
        }
        let total = response.expectedContentLength
        let tmp = destination.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(received) / Double(total)) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.close()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        progress(1.0)
    }
}
