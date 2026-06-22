import Foundation

/// Downloads and locates the SenseVoice (int8) model used by the sherpa-onnx engine.
/// Two files are fetched directly from Hugging Face into Application Support:
/// `model.int8.onnx` (~239 MB) and `tokens.txt`.
final class SenseVoiceModelManager {
    static let shared = SenseVoiceModelManager()
    private init() {}

    private let dirName = "sensevoice-model"
    private let modelURL = URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx?download=true")!
    private let tokensURL = URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt?download=true")!

    var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier!)
            .appendingPathComponent(dirName)
    }
    var modelPath: URL { modelDirectory.appendingPathComponent("model.int8.onnx") }
    var tokensPath: URL { modelDirectory.appendingPathComponent("tokens.txt") }

    var isDownloaded: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: modelPath.path) && fm.fileExists(atPath: tokensPath.path)
    }

    /// Approximate on-disk size, for display.
    var downloadSizeString: String { "≈ 239 MB" }

    /// Download both files. `progress` reports 0…1 (model download dominates).
    func download(progress: @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try await download(from: tokensURL, to: tokensPath) { _ in progress(0.01) }
        try await download(from: modelURL, to: modelPath) { p in progress(0.01 + p * 0.99) }
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
