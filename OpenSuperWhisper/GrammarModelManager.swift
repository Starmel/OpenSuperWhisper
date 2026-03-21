import Foundation

struct GrammarDownloadableModel: Identifiable {
    let id = UUID()
    let name: String
    let filename: String
    let url: URL
    let sizeMB: Int
    let description: String
    var downloadProgress: Double = 0.0
    var isDownloaded: Bool = false

    var sizeString: String {
        let gb = Double(sizeMB) / 1000.0
        return String(format: "%.1f GB", gb)
    }
}

struct GrammarDownloadableModels {
    static let availableModels: [GrammarDownloadableModel] = [
        GrammarDownloadableModel(
            name: "GRMR-V3-G4B · Q4_K_M",
            filename: "GRMR-V3-G4B-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/qingy2024/GRMR-V3-G4B-GGUF/resolve/main/GRMR-V3-G4B-Q4_K_M.gguf")!,
            sizeMB: 2500,
            description: "Grammar Only — fine-tuned specifically for grammar correction"
        ),
        GrammarDownloadableModel(
            name: "Qwen3-4B · Q4_K_M",
            filename: "Qwen3-4B-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!,
            sizeMB: 2509,
            description: "Balanced — general purpose with strong grammar correction"
        ),
        GrammarDownloadableModel(
            name: "Qwen3-14B · Q4_K_M",
            filename: "Qwen3-14B-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf")!,
            sizeMB: 8990,
            description: "Premium — highest quality, requires ~9 GB disk space"
        ),
    ]
}

class GrammarModelManager {
    static let shared = GrammarModelManager()

    private let modelDirectoryName = "grammar-models"
    private var activeDownloadTask: URLSessionDownloadTask?
    private let downloadTaskLock = NSLock()

    var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier!)
            .appendingPathComponent(modelDirectoryName)
    }

    // The currently selected model file (first downloaded one wins)
    var activeModelPath: URL? {
        for model in GrammarDownloadableModels.availableModels {
            let path = modelsDirectory.appendingPathComponent(model.filename)
            if FileManager.default.fileExists(atPath: path.path) { return path }
        }
        return nil
    }

    // Legacy compatibility — used by GrammarEngine
    var modelPath: URL {
        activeModelPath ?? modelsDirectory.appendingPathComponent(GrammarDownloadableModels.availableModels[0].filename)
    }

    var isModelDownloaded: Bool { activeModelPath != nil }

    private init() {
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    func isDownloaded(_ model: GrammarDownloadableModel) -> Bool {
        FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent(model.filename).path)
    }

    func downloadModel(
        _ model: GrammarDownloadableModel,
        progressCallback: @escaping (Double) -> Void
    ) async throws {
        let dest = modelsDirectory.appendingPathComponent(model.filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            progressCallback(1.0)
            return
        }

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = WhisperDownloadDelegate(progressCallback: progressCallback)
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForResource = 7200 // 2 hrs for large model

            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
            let task = session.downloadTask(with: model.url)

            downloadTaskLock.lock()
            activeDownloadTask = task
            downloadTaskLock.unlock()

            delegate.completionHandler = { [weak self] location, error in
                guard let self else { return }
                self.downloadTaskLock.lock()
                self.activeDownloadTask = nil
                self.downloadTaskLock.unlock()

                if let urlError = error as? URLError, urlError.code == .cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location else {
                    continuation.resume(throwing: NSError(
                        domain: "GrammarModelManager", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No download location"]
                    ))
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: location, to: dest)
                    progressCallback(1.0)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }

    func cancelDownload() {
        downloadTaskLock.lock()
        defer { downloadTaskLock.unlock() }
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
    }

    func deleteModel(_ model: GrammarDownloadableModel) {
        let path = modelsDirectory.appendingPathComponent(model.filename)
        try? FileManager.default.removeItem(at: path)
    }
}
