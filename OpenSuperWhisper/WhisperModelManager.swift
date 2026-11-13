import Combine
import CryptoKit
import Foundation

class ModelDownloadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    private let progressCallback: (Double) -> Void
    private var expectedContentLength: Int64 = 0
    var completionHandler: ((URL?, Error?) -> Void)?
    weak var downloadTask: URLSessionDownloadTask?
    
    init(progressCallback: @escaping (Double) -> Void) {
        self.progressCallback = progressCallback
        super.init()
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let error = Self.validationError(for: downloadTask.response) {
            completionHandler?(nil, error)
            return
        }
        completionHandler?(location, nil)
    }
    
    static func validationError(for response: URLResponse?) -> Error? {
        guard let httpResponse = response as? HTTPURLResponse,
              !(200...299).contains(httpResponse.statusCode) else {
            return nil
        }
        return NSError(
            domain: "WhisperModelManager",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Model server returned HTTP \(httpResponse.statusCode). Please try again later."]
        )
    }
    
    static func progressFraction(totalBytesWritten: Int64, expectedContentLength: Int64) -> Double? {
        guard expectedContentLength > 0 else { return nil }
        return min(Double(totalBytesWritten) / Double(expectedContentLength), 1.0)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if expectedContentLength <= 0 {
            expectedContentLength = totalBytesExpectedToWrite
        }
        guard let progress = Self.progressFraction(totalBytesWritten: totalBytesWritten, expectedContentLength: expectedContentLength) else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.progressCallback(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completionHandler?(nil, error)
        } else {
        }
    }
}

/// What happened to the models on disk, in the terms the Model tab shows it.
///
/// A missing selection used to be a `print`: the app quietly switched to the
/// bundled model and the user only found out when a transcript came out of a
/// different model than the one they picked.
enum ModelStorageNotice: Equatable {
    /// The selected file was gone, so the app fell back to the bundled model.
    case selectionWasMissing(was: String, now: String)
    /// The user removed a model, and this is how much disk that freed.
    case removed(name: String, bytesFreed: Int64)
    /// Removing the last model put the bundled one back, so the app keeps working.
    case restoredBundled(name: String)

    var message: String {
        switch self {
        case .selectionWasMissing(let was, let now):
            return "The selected model \(was) was not on disk any more — now using \(now)."
        case .removed(let name, let bytesFreed):
            return "Removed \(name), freeing \(ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file))."
        case .restoredBundled(let name):
            return "That was the last model, so the bundled \(name) was put back."
        }
    }
}

/// A model file checked against the digest the repository pins for it.
struct ModelVerification: Equatable {
    let fileName: String
    let sizeBytes: Int64
    let sha256: String
    /// `nil` when this file is not one of the catalogue entries, so there is
    /// nothing published to compare against.
    let pinnedSHA256: String?

    var matchesPinnedDigest: Bool? {
        guard let pinnedSHA256 else { return nil }
        return pinnedSHA256.caseInsensitiveCompare(sha256) == .orderedSame
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// The one line the Model tab shows.
    var summary: String {
        switch matchesPinnedDigest {
        case true?:
            return "Verified ✓ against the published sha256 \(String(sha256.prefix(16)))…"
        case false?:
            return "Checksum mismatch — this file is not the published one (got \(String(sha256.prefix(16)))…)"
        case nil:
            return "sha256 \(String(sha256.prefix(16)))…, \(sizeDescription) — no published checksum for this file"
        }
    }
}

class WhisperModelManager: ObservableObject {
    static let shared = WhisperModelManager()

    /// The model the app ships inside its own bundle.
    static let defaultModelName = "ggml-tiny.en.bin"

    /// The last thing that happened to a model file, for the Model tab.
    @Published private(set) var lastNotice: ModelStorageNotice?

    private static let modelsDirectoryName = "whisper-models"
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private let downloadTasksLock = NSLock()

    /// `~/Library/Application Support/<bundle id>/whisper-models/`
    ///
    /// Static so the preference migration can tell an app-owned model path from
    /// a foreign one without instantiating the manager. A test replaces it with
    /// a fixture directory of its own; the app never sets it.
    static var modelsDirectory: URL = defaultModelsDirectory

    static let defaultModelsDirectory: URL = {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "ru.starmel.OpenSuperWhisper"
        return applicationSupport
            .appendingPathComponent(bundleID)
            .appendingPathComponent(modelsDirectoryName)
    }()

    var modelsDirectory: URL { Self.modelsDirectory }
    
    private init() {
        createModelsDirectoryIfNeeded()
        copyDefaultModelIfNeeded()
    }
    
    private func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create models directory: \(error)")
        }
    }
    
    private func copyDefaultModelIfNeeded() {
        let defaultModelName = Self.defaultModelName
        let destinationURL = modelsDirectory.appendingPathComponent(defaultModelName)
        
        // Check if model already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return
        }
        
        // Look for the model in the bundle
        if let bundleURL = Bundle.main.url(forResource: "ggml-tiny.en", withExtension: "bin") {
            do {
                try FileManager.default.copyItem(at: bundleURL, to: destinationURL)
                print("Copied default model to: \(destinationURL.path)")
            } catch {
                print("Failed to copy default model: \(error)")
            }
        }
    }

    /// The model the app keeps for itself: the one inside its own bundle, copied
    /// into the app's directory on first run. Falls back to the file in the
    /// bundle when that copy is not there (a first launch that has not copied it
    /// yet, a full or read-only disk) — either way the app can load it.
    ///
    /// `nil` only when the bundle does not carry its model, which is a broken
    /// build rather than a state a user can reach: the repository tracks
    /// `OpenSuperWhisper/ggml-tiny.en.bin` and the target puts it in the bundle's
    /// resources.
    ///
    /// Static on purpose: this answers where the app's own model is without
    /// creating the manager, so nothing has to be instantiated — and no directory
    /// has to be chosen — just to find out whether a fresh install has something
    /// to run.
    static var bundledModelPath: String? {
        let copy = modelsDirectory.appendingPathComponent(defaultModelName)
        if FileManager.default.fileExists(atPath: copy.path) { return copy.path }
        return Bundle.main.url(forResource: "ggml-tiny.en", withExtension: "bin")?.path
    }

    // Call this on every startup to ensure at least one model is present
    public func ensureDefaultModelPresent() {
        let defaultModelURL = modelsDirectory.appendingPathComponent(Self.defaultModelName)
        if !FileManager.default.fileExists(atPath: defaultModelURL.path) {
            copyDefaultModelIfNeeded()
        }

        // A selection that points at a file which is not there anymore (the
        // checkout it came from was moved, the file was deleted, the migration
        // dropped it) would fail every dictation with
        // contextInitializationFailed. Point it at the model the app owns
        // instead — and say so in the Model tab, because a silent switch is a
        // transcript from a model the user did not choose.
        //
        // A fresh install has nothing selected at all, which is that same
        // failure one step earlier: no preference ever hands the engine a path,
        // and the first dictation reports "Model could not be loaded" while the
        // app is carrying a model of its own. That case points at the bundled
        // model too — silently, because nothing was swapped out from under
        // anybody, and the Model tab lists it as the model in use.
        let prefs = AppPreferences.shared
        let stored = prefs.selectedWhisperModelPath
        if let stored, !stored.isEmpty, FileManager.default.fileExists(atPath: stored) {
            return
        }

        guard let bundled = Self.bundledModelPath else { return }
        prefs.selectedWhisperModelPath = bundled
        if let stored, !stored.isEmpty {
            print("Selected whisper model \(stored) is gone; falling back to the bundled one")
            notify(.selectionWasMissing(was: URL(fileURLWithPath: stored).lastPathComponent,
                                        now: Self.defaultModelName))
        }
    }

    private func notify(_ notice: ModelStorageNotice) {
        if Thread.isMainThread {
            lastNotice = notice
        } else {
            DispatchQueue.main.async { [weak self] in self?.lastNotice = notice }
        }
    }

    /// Whether two paths name the same file. `/var` and `/private/var`, a
    /// symlinked home directory, and a trailing slash all spell the same model
    /// differently, and a selection that is not recognised is a model the user
    /// cannot see they are using — and one `Remove` will not detach.
    static func isSameFile(_ lhs: String, _ rhs: String) -> Bool {
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return canonical(lhs) == canonical(rhs)
    }

    /// Size of one model file, 0 when it cannot be read.
    func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// SHA-256 of a model file, read in chunks so a 1.6 GB model never lands in
    /// memory. This is the same digest the catalogue pins and Hugging Face
    /// publishes for the file.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks a model file and reports what it is, digest included.
    func verifyModel(at url: URL, pinnedSHA256: String?) throws -> ModelVerification {
        let digest = try Self.sha256(ofFileAt: url)
        return ModelVerification(fileName: url.lastPathComponent,
                                 sizeBytes: fileSize(at: url),
                                 sha256: digest,
                                 pinnedSHA256: pinnedSHA256)
    }

    /// Deletes a model file and leaves the app with a usable selection: the
    /// selection is cleared if it pointed at the removed file (the app then
    /// picks another model), and if nothing is left the bundled model comes
    /// back, so removing everything cannot leave the app unable to transcribe.
    @discardableResult
    func removeModel(at url: URL) throws -> ModelStorageNotice {
        let name = url.lastPathComponent
        let freed = fileSize(at: url)
        try FileManager.default.removeItem(at: url)

        let prefs = AppPreferences.shared
        if let selected = prefs.selectedWhisperModelPath, Self.isSameFile(selected, url.path) {
            prefs.selectedWhisperModelPath = nil
        }

        if getAvailableModels().isEmpty {
            let defaultModelURL = modelsDirectory.appendingPathComponent(Self.defaultModelName)
            copyDefaultModelIfNeeded()
            if FileManager.default.fileExists(atPath: defaultModelURL.path) {
                prefs.selectedWhisperModelPath = defaultModelURL.path
                let notice = ModelStorageNotice.restoredBundled(name: Self.defaultModelName)
                notify(notice)
                return notice
            }
        }

        let notice = ModelStorageNotice.removed(name: name, bytesFreed: freed)
        notify(notice)
        return notice
    }
    
    func getAvailableModels() -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "bin" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            print("Failed to get available models: \(error)")
            return []
        }
    }
    
    // Download model with progress callback using delegate
    func downloadModel(url: URL, name: String, progressCallback: @escaping (Double) -> Void) async throws {
        let destinationURL = modelsDirectory.appendingPathComponent(name)
        
        // Check if model already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            print("Model already exists at: \(destinationURL.path)")
            DispatchQueue.main.async {
                progressCallback(1.0)
            }
            return
        }
        
        print("Starting model download:")
        print("- URL: \(url.absoluteString)")
        print("- Destination: \(destinationURL.path)")
        
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = ModelDownloadDelegate(progressCallback: progressCallback)
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            print("Initiating download...")
            
            // Create a download task without completion handler
            let downloadTask = session.downloadTask(with: url)
            delegate.downloadTask = downloadTask
            
            // Store task for cancellation
            downloadTasksLock.lock()
            activeDownloadTasks[name] = downloadTask
            downloadTasksLock.unlock()
            
            // Add completion handling to delegate
            delegate.completionHandler = { [weak self] location, error in
                session.finishTasksAndInvalidate()
                
                // Remove task from active downloads
                self?.downloadTasksLock.lock()
                let isCurrent = self?.activeDownloadTasks[name] === downloadTask
                if isCurrent { self?.activeDownloadTasks.removeValue(forKey: name) }
                self?.downloadTasksLock.unlock()
                guard isCurrent else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                
                // Check if cancelled
                if let error = error as? URLError, error.code == .cancelled {
                    print("Download cancelled")
                    continuation.resume(throwing: CancellationError())
                    return
                }
                
                if let error = error {
                    print("Download failed with error: \(error)")
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let location = location else {
                    let error = NSError(domain: "WhisperModelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No download URL received"])
                    continuation.resume(throwing: error)
                    return
                }
                
                do {
                    print("Download completed. Moving file to destination...")
                    try FileManager.default.moveItem(at: location, to: destinationURL)
                    print("Model successfully saved to: \(destinationURL.path)")
                    
                    DispatchQueue.main.async {
                        progressCallback(1.0)
                    }
                    
                    continuation.resume(returning: ())
                } catch {
                    print("Failed to move downloaded file: \(error)")
                    continuation.resume(throwing: error)
                }
            }
            
            downloadTask.resume()
        }
    }
    
    // Cancel download task
    func cancelDownload(name: String) {
        downloadTasksLock.lock()
        defer { downloadTasksLock.unlock() }
        
        if let task = activeDownloadTasks[name] {
            task.cancel()
            activeDownloadTasks.removeValue(forKey: name)
            print("Cancelled download for: \(name)")
        }
    }
    
    // Check if specific model is downloaded
    func isModelDownloaded(name: String) -> Bool {
        let modelPath = modelsDirectory.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: modelPath)
    }
}
