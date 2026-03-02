import Foundation

struct MoonshineModelInfo {
    let name: String
    let language: String
    let archRawValue: UInt32
    let downloadBaseURL: String
    let components: [String]
    
    var folderName: String {
        downloadBaseURL
            .replacingOccurrences(of: "https://", with: "")
    }
}

class MoonshineModelManager {
    static let shared = MoonshineModelManager()
    
    private let cacheDirectoryName = "moonshine"
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private let downloadTasksLock = NSLock()
    
    static let baseComponents = ["encoder_model.ort", "decoder_model_merged.ort", "tokenizer.bin"]
    
    static let availableModels: [MoonshineModelInfo] = [
        MoonshineModelInfo(
            name: "base-en",
            language: "en",
            archRawValue: 1,
            downloadBaseURL: "https://download.moonshine.ai/model/base-en/quantized/base-en",
            components: baseComponents
        ),
        MoonshineModelInfo(
            name: "tiny-en",
            language: "en",
            archRawValue: 0,
            downloadBaseURL: "https://download.moonshine.ai/model/tiny-en/quantized/tiny-en",
            components: baseComponents
        ),
        MoonshineModelInfo(
            name: "base-ja",
            language: "ja",
            archRawValue: 1,
            downloadBaseURL: "https://download.moonshine.ai/model/base-ja/quantized/base-ja",
            components: baseComponents
        ),
        MoonshineModelInfo(
            name: "base-es",
            language: "es",
            archRawValue: 1,
            downloadBaseURL: "https://download.moonshine.ai/model/base-es/quantized/base-es",
            components: baseComponents
        ),
        MoonshineModelInfo(
            name: "base-ar",
            language: "ar",
            archRawValue: 1,
            downloadBaseURL: "https://download.moonshine.ai/model/base-ar/quantized/base-ar",
            components: baseComponents
        ),
        MoonshineModelInfo(
            name: "base-uk",
            language: "uk",
            archRawValue: 1,
            downloadBaseURL: "https://download.moonshine.ai/model/base-uk/quantized/base-uk",
            components: baseComponents
        ),
        MoonshineModelInfo(
            name: "base-zh",
            language: "zh",
            archRawValue: 1,
            downloadBaseURL: "https://download.moonshine.ai/model/base-zh/quantized/base-zh",
            components: baseComponents
        ),
        MoonshineModelInfo(
            name: "base-vi",
            language: "vi",
            archRawValue: 1,
            downloadBaseURL: "https://download.moonshine.ai/model/base-vi/quantized/base-vi",
            components: baseComponents
        ),
        MoonshineModelInfo(
            name: "base-ko",
            language: "ko",
            archRawValue: 0,
            downloadBaseURL: "https://download.moonshine.ai/model/tiny-ko/quantized/tiny-ko",
            components: baseComponents
        ),
    ]
    
    var modelsDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "OpenSuperWhisper")
            .appendingPathComponent(cacheDirectoryName)
    }
    
    private init() {
        createModelsDirectoryIfNeeded()
    }
    
    private func createModelsDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }
    
    func modelDirectory(for info: MoonshineModelInfo) -> URL {
        modelsDirectory.appendingPathComponent(info.name)
    }
    
    func isModelDownloaded(_ info: MoonshineModelInfo) -> Bool {
        let dir = modelDirectory(for: info)
        return info.components.allSatisfy { component in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(component).path)
        }
    }
    
    func isModelDownloaded(name: String) -> Bool {
        guard let info = Self.availableModels.first(where: { $0.name == name }) else { return false }
        return isModelDownloaded(info)
    }
    
    func downloadModel(
        _ info: MoonshineModelInfo,
        progressCallback: @escaping (Double) -> Void
    ) async throws {
        let destDir = modelDirectory(for: info)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        let totalComponents = Double(info.components.count)
        
        for (index, component) in info.components.enumerated() {
            let destFile = destDir.appendingPathComponent(component)
            if FileManager.default.fileExists(atPath: destFile.path) {
                let baseProgress = Double(index + 1) / totalComponents
                await MainActor.run { progressCallback(baseProgress) }
                continue
            }
            
            let componentURL = URL(string: "\(info.downloadBaseURL)/\(component)")!
            
            try await downloadComponent(
                url: componentURL,
                destination: destFile,
                taskKey: "\(info.name)/\(component)"
            ) { componentProgress in
                let baseProgress = (Double(index) + componentProgress) / totalComponents
                progressCallback(baseProgress)
            }
        }
        
        await MainActor.run { progressCallback(1.0) }
    }
    
    private func downloadComponent(
        url: URL,
        destination: URL,
        taskKey: String,
        progressCallback: @escaping (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = WhisperDownloadDelegate(progressCallback: progressCallback)
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForResource = 600
            
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            let downloadTask = session.downloadTask(with: url)
            delegate.downloadTask = downloadTask
            
            downloadTasksLock.lock()
            activeDownloadTasks[taskKey] = downloadTask
            downloadTasksLock.unlock()
            
            delegate.completionHandler = { [weak self] location, error in
                self?.downloadTasksLock.lock()
                self?.activeDownloadTasks.removeValue(forKey: taskKey)
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
                        domain: "MoonshineModelManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No download location"]
                    ))
                    return
                }
                
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            
            downloadTask.resume()
        }
    }
    
    func cancelDownload(name: String) {
        downloadTasksLock.lock()
        defer { downloadTasksLock.unlock() }
        
        let keysToCancel = activeDownloadTasks.keys.filter { $0.hasPrefix(name) }
        for key in keysToCancel {
            activeDownloadTasks[key]?.cancel()
            activeDownloadTasks.removeValue(forKey: key)
        }
    }
}
