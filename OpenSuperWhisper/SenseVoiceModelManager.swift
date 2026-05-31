import Foundation

enum SenseVoiceVariant: String, CaseIterable {
    case int8
    case fp32

    var displayName: String {
        switch self {
        case .int8: return "SenseVoice int8"
        case .fp32: return "SenseVoice float32"
        }
    }

    var description: String {
        switch self {
        case .int8: return "Quantized, faster and lighter (~229 MB)"
        case .fp32: return "Full precision, higher accuracy (~895 MB)"
        }
    }

    /// Size in megabytes (approximate, used for UI display).
    var sizeMB: Int {
        switch self {
        case .int8: return 229
        case .fp32: return 895
        }
    }

    /// Release archive URL on GitHub.
    var archiveURL: URL {
        switch self {
        case .int8:
            return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2")!
        case .fp32:
            return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2")!
        }
    }

    /// Name of the onnx model file inside the extracted archive.
    var modelFileName: String {
        switch self {
        case .int8: return "model.int8.onnx"
        case .fp32: return "model.onnx"
        }
    }
}

class SenseVoiceModelManager {
    static let shared = SenseVoiceModelManager()

    private let modelsDirectoryName = "sensevoice-models"
    private let tokensFileName = "tokens.txt"
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private let downloadTasksLock = NSLock()

    private init() {
        createModelsDirectoryIfNeeded()
    }

    var modelsDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return applicationSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier!)
            .appendingPathComponent(modelsDirectoryName)
    }

    func directory(for variant: SenseVoiceVariant) -> URL {
        modelsDirectory.appendingPathComponent(variant.rawValue)
    }

    func modelPath(for variant: SenseVoiceVariant) -> URL {
        directory(for: variant).appendingPathComponent(variant.modelFileName)
    }

    func tokensPath(for variant: SenseVoiceVariant) -> URL {
        directory(for: variant).appendingPathComponent(tokensFileName)
    }

    func isModelDownloaded(variant: SenseVoiceVariant) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: modelPath(for: variant).path)
            && fm.fileExists(atPath: tokensPath(for: variant).path)
    }

    private func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create SenseVoice models directory: \(error)")
        }
    }

    /// Downloads and extracts the model archive for the given variant.
    /// The progress callback reports the download phase (0.0...1.0). Extraction
    /// happens afterwards and is reported as a final 1.0.
    func downloadModel(variant: SenseVoiceVariant, progressCallback: @escaping (Double) -> Void) async throws {
        if isModelDownloaded(variant: variant) {
            await MainActor.run { progressCallback(1.0) }
            return
        }

        let variantDir = directory(for: variant)
        try FileManager.default.createDirectory(at: variantDir, withIntermediateDirectories: true)

        let archiveURL = try await downloadArchive(variant: variant, progressCallback: progressCallback)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        try extractArchive(at: archiveURL, into: variantDir)

        guard isModelDownloaded(variant: variant) else {
            throw NSError(
                domain: "SenseVoiceModelManager",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Extracted archive does not contain expected model files"]
            )
        }

        await MainActor.run { progressCallback(1.0) }
    }

    private func downloadArchive(variant: SenseVoiceVariant, progressCallback: @escaping (Double) -> Void) async throws -> URL {
        let url = variant.archiveURL
        let key = variant.rawValue

        return try await withCheckedThrowingContinuation { continuation in
            // Download progress maps to 0.0...0.95, leaving headroom for extraction.
            let delegate = WhisperDownloadDelegate(progressCallback: { progress in
                progressCallback(min(progress * 0.95, 0.95))
            })
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForResource = 1800

            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            let downloadTask = session.downloadTask(with: url)
            delegate.downloadTask = downloadTask

            downloadTasksLock.lock()
            activeDownloadTasks[key] = downloadTask
            downloadTasksLock.unlock()

            delegate.completionHandler = { [weak self] location, error in
                self?.downloadTasksLock.lock()
                self?.activeDownloadTasks.removeValue(forKey: key)
                self?.downloadTasksLock.unlock()

                if let error = error as? URLError, error.code == .cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location = location else {
                    continuation.resume(throwing: NSError(
                        domain: "SenseVoiceModelManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No download location received"]
                    ))
                    return
                }

                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("tar.bz2")
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            downloadTask.resume()
        }
    }

    /// Extracts a `.tar.bz2` archive, flattening the single top-level directory
    /// so the model files land directly inside `destinationDir`.
    private func extractArchive(at archiveURL: URL, into destinationDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-xjf", archiveURL.path,
            "-C", destinationDir.path,
            "--strip-components=1",
        ]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown tar error"
            throw NSError(
                domain: "SenseVoiceModelManager",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract model archive: \(message)"]
            )
        }
    }

    func cancelDownload(variant: SenseVoiceVariant) {
        downloadTasksLock.lock()
        defer { downloadTasksLock.unlock() }

        if let task = activeDownloadTasks[variant.rawValue] {
            task.cancel()
            activeDownloadTasks.removeValue(forKey: variant.rawValue)
        }
    }
}
