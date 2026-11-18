import Combine
import CryptoKit
import Foundation

/// One GGUF file of the Qwen3-ASR engine.
///
/// The engine needs both of them: the text model alone cannot hear, and the
/// `mmproj` alone has no decoder. They are one download from the user's point of
/// view but two files on disk, each with its own pinned digest.
struct Qwen3ASRModelFile: Identifiable, Equatable {
    /// The half of the engine this file is: `model` or `audio-projector`.
    let id: String
    let displayName: String
    let fileName: String
    let downloadURL: URL
    /// Pinned by the repository, and the only place the digest lives.
    let sha256: String
    /// The published size, so a file that is present but not the right one is
    /// told apart from a file that is simply not there.
    let sizeBytes: Int64

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum Qwen3ASRError: Error, LocalizedError {
    /// The weights are not on disk. Carries the files that are missing, because
    /// the remedy names them.
    case notInstalled(missing: [String])
    /// A file is there but is not the pinned size, so it is not the published
    /// file: a partial download, a copy of the wrong quantisation, or a file an
    /// older build left behind.
    case fileNotVerified(String, expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case downloadFailed(String)
    case cancellation

    var errorDescription: String? {
        switch self {
        case .notInstalled(let missing):
            return "The Qwen3-ASR weights are not on disk (\(missing.joined(separator: ", "))). "
                 + "The app downloads them the first time the engine runs; if this comes back, "
                 + "download them in Settings → Models, or pick another engine there."
        case .fileNotVerified(let name, let expected, let actual):
            let expectedText = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            let actualText = ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
            return "\(name) is not the file the Qwen3-ASR model ships: expected \(expectedText), found \(actualText). "
                 + "Remove it in Settings → Models and download it again."
        case .checksumMismatch(let expected, let actual):
            return "The downloaded Qwen3-ASR file does not match its pinned checksum "
                 + "(expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .downloadFailed(let reason):
            return "The Qwen3-ASR download failed: \(reason)"
        case .cancellation:
            return "The Qwen3-ASR download was cancelled."
        }
    }
}

/// Owns the Qwen3-ASR weights: app-owned storage, pinned digests, atomic install.
///
/// The weights are not shipped in the app bundle — 2.5 GB in every update is the
/// wrong trade. They live in
/// `~/Library/Application Support/<bundle id>/qwen3-asr-models/`, exactly like the
/// whisper models and the transform weights next door, so uninstalling the app
/// removes them and reinstalling fetches them again.
///
/// Nothing is substituted quietly: an engine whose files are not there fails
/// with the name of the file to download, and never falls back to another
/// engine's weights.
final class Qwen3ASRModelManager {
    static let shared = Qwen3ASRModelManager()

    /// The text model: `ggml-org/Qwen3-ASR-1.7B-GGUF`, Q8_0. Architecture
    /// `qwen3vl`, converted from `Qwen/Qwen3-ASR-1.7B` (Apache-2.0).
    static let modelFileID = "model"

    /// Its audio projector: the `qwen3a` encoder that turns 16 kHz PCM into the
    /// embeddings the text model is prompted with.
    static let projectorFileID = "audio-projector"

    static let availableFiles: [Qwen3ASRModelFile] = [
        Qwen3ASRModelFile(
            id: Qwen3ASRModelManager.modelFileID,
            displayName: "Qwen3-ASR 1.7B (Q8_0)",
            fileName: "Qwen3-ASR-1.7B-Q8_0.gguf",
            downloadURL: URL(string: "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/Qwen3-ASR-1.7B-Q8_0.gguf")!,
            sha256: "58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57",
            sizeBytes: 2_165_034_944
        ),
        Qwen3ASRModelFile(
            id: Qwen3ASRModelManager.projectorFileID,
            displayName: "Qwen3-ASR 1.7B audio projector (Q8_0)",
            fileName: "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf",
            downloadURL: URL(string: "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf")!,
            sha256: "46c1d533af3f354ceb37ce855dbceff7da7fa7cf1e6a523df3b13440bd164c0d",
            sizeBytes: 355_709_344
        )
    ]

    /// Where the GGUF files live. Overridable so tests can use a temporary
    /// directory instead of the user's Application Support.
    let directory: URL
    private let catalogue: [Qwen3ASRModelFile]
    private let fileManager: FileManager

    private var activeDownloads: [String: URLSessionDownloadTask] = [:]
    private let downloadLock = NSLock()

    init(
        directory: URL? = nil,
        catalogue: [Qwen3ASRModelFile] = Qwen3ASRModelManager.availableFiles,
        fileManager: FileManager = .default
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.catalogue = catalogue
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        removeStalePartialDownloads()
    }

    /// `~/Library/Application Support/<bundle id>/qwen3-asr-models/`
    static var defaultDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "ru.starmel.OpenSuperWhisper"
        return applicationSupport
            .appendingPathComponent(bundleID)
            .appendingPathComponent("qwen3-asr-models")
    }

    // MARK: - Catalogue

    var files: [Qwen3ASRModelFile] { catalogue }

    func file(forID id: String) -> Qwen3ASRModelFile? {
        catalogue.first { $0.id == id }
    }

    var modelFile: Qwen3ASRModelFile { file(forID: Self.modelFileID) ?? catalogue[0] }

    var projectorFile: Qwen3ASRModelFile {
        file(forID: Self.projectorFileID) ?? catalogue[catalogue.count - 1]
    }

    func fileURL(for file: Qwen3ASRModelFile) -> URL {
        directory.appendingPathComponent(file.fileName)
    }

    // MARK: - Installed state

    /// Whether the file is on disk at the published size.
    ///
    /// Deliberately not a checksum: hashing 2.5 GB is seconds of work, and this
    /// is asked on every engine load. The digest is checked where it can be
    /// checked once — at install, and on demand from the Model tab's `Verify`.
    func hasInstalledFile(_ file: Qwen3ASRModelFile) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL(for: file).path) else {
            return false
        }
        return (attributes[.size] as? NSNumber)?.int64Value == file.sizeBytes
    }

    /// The catalogue files that are not installed.
    var missingFiles: [Qwen3ASRModelFile] {
        catalogue.filter { !hasInstalledFile($0) }
    }

    /// The paths the engine loads, or `nil` while any of the two files is not
    /// installed — see `Qwen3ASREngine.initialize()` for the error that names
    /// what is wrong.
    var installedPaths: (model: String, projector: String)? {
        guard missingFiles.isEmpty else { return nil }
        return (fileURL(for: modelFile).path, fileURL(for: projectorFile).path)
    }

    /// The engine's own precondition, phrased as the error the user sees.
    func requireInstalledPaths() throws -> (model: String, projector: String) {
        if let paths = installedPaths {
            return paths
        }
        var missing: [String] = []
        for file in catalogue {
            let url = fileURL(for: file)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                missing.append(file.displayName)
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if size != file.sizeBytes {
                throw Qwen3ASRError.fileNotVerified(file.fileName,
                                                    expected: file.sizeBytes,
                                                    actual: size)
            }
        }
        throw Qwen3ASRError.notInstalled(missing: missing)
    }

    /// The app's own hash-of-a-model-file helper, so the digest the Model tab
    /// reports and the digest the install checks are computed the same way.
    static func sha256(ofFileAt url: URL) throws -> String {
        try WhisperModelManager.sha256(ofFileAt: url)
    }

    // MARK: - Install

    /// Installs `source` as `file`, atomically and only after the bytes on disk
    /// in the app's own directory hash to the pinned digest.
    func install(fileAt source: URL, file: Qwen3ASRModelFile) throws {
        // The engine's own first-run download and the Model tab's button can
        // land here at the same time for the same file; one at a time keeps the
        // `.part` file from being written twice.
        downloadLock.lock()
        defer { downloadLock.unlock() }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = fileURL(for: file)
        let partial = partialURL(for: file)
        try? fileManager.removeItem(at: partial)
        try? fileManager.removeItem(at: destination)

        // Copy into the destination directory first, so the hash below is
        // computed over the bytes that actually land, and the final move is a
        // same-volume rename that either happened or did not.
        try fileManager.copyItem(at: source, to: partial)

        let digest: String
        do {
            digest = try Self.sha256(ofFileAt: partial)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw Qwen3ASRError.downloadFailed("\(error)")
        }
        guard digest == file.sha256.lowercased() else {
            try? fileManager.removeItem(at: partial)
            throw Qwen3ASRError.checksumMismatch(expected: file.sha256, actual: digest)
        }

        do {
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw Qwen3ASRError.downloadFailed("\(error)")
        }
    }

    /// Fetches one file with a URLSession download task (progress, atomic
    /// install, checksum before use) — the same idiom the whisper and transform
    /// downloads use.
    func download(_ file: Qwen3ASRModelFile, progress: @escaping (Double) -> Void) async throws {
        if hasInstalledFile(file) {
            progress(1.0)
            return
        }

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = ModelDownloadDelegate(progressCallback: progress)
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 24 * 60 * 60

            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            let downloadTask = session.downloadTask(with: file.downloadURL)
            delegate.downloadTask = downloadTask

            downloadLock.lock()
            activeDownloads[file.id] = downloadTask
            downloadLock.unlock()

            delegate.completionHandler = { [weak self] location, error in
                session.finishTasksAndInvalidate()

                guard let self else {
                    continuation.resume(throwing: Qwen3ASRError.cancellation)
                    return
                }

                self.downloadLock.lock()
                let isCurrent = self.activeDownloads[file.id] === downloadTask
                if isCurrent { self.activeDownloads.removeValue(forKey: file.id) }
                self.downloadLock.unlock()
                guard isCurrent else {
                    continuation.resume(throwing: Qwen3ASRError.cancellation)
                    return
                }

                if let error = error as? URLError, error.code == .cancelled {
                    continuation.resume(throwing: Qwen3ASRError.cancellation)
                    return
                }
                if let error {
                    continuation.resume(throwing: Qwen3ASRError.downloadFailed(error.localizedDescription))
                    return
                }
                guard let location else {
                    continuation.resume(throwing: Qwen3ASRError.downloadFailed("no file was received"))
                    return
                }

                do {
                    try self.install(fileAt: location, file: file)
                    try? FileManager.default.removeItem(at: location)
                    progress(1.0)
                    continuation.resume()
                } catch {
                    try? FileManager.default.removeItem(at: location)
                    continuation.resume(throwing: error)
                }
            }

            downloadTask.resume()
        }
    }

    func cancelDownload(fileID: String) {
        downloadLock.lock()
        defer { downloadLock.unlock() }
        activeDownloads[fileID]?.cancel()
        activeDownloads.removeValue(forKey: fileID)
    }

    /// Removes one installed file. Idempotent.
    func remove(_ file: Qwen3ASRModelFile) throws {
        cancelDownload(fileID: file.id)
        try? fileManager.removeItem(at: fileURL(for: file))
        try? fileManager.removeItem(at: partialURL(for: file))
    }

    /// Removes both halves of the engine. Partial: a removal that fails halfway
    /// leaves the other file in place, which the next load reports as usual.
    func removeAll() throws {
        for file in catalogue { try remove(file) }
    }

    private func partialURL(for file: Qwen3ASRModelFile) -> URL {
        directory.appendingPathComponent(file.fileName + ".part")
    }

    /// A partial download from a killed app is never resumable: drop it.
    private func removeStalePartialDownloads() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.pathExtension == "part" {
            try? fileManager.removeItem(at: entry)
        }
    }
}
