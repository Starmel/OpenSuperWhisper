import CoreML
import CryptoKit
import Foundation

/// GigaAM-v3 e2e RNNT Core ML export (https://huggingface.co/smkrv/gigaam-v3-e2e-rnnt-coreml, MIT),
/// pinned to a revision; every file is checked against its size and SHA-256 before compiling.
enum GigaAMModel {
    struct RemoteFile {
        let path: String
        let size: Int64
        let sha256: String
    }

    enum ModelError: LocalizedError {
        case notInstalled
        case unsupportedOS
        case badResponse(String, Int)
        case integrityCheckFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "GigaAM model is not downloaded. Download it in Settings → Model."
            case .unsupportedOS:
                return "GigaAM requires macOS 15 or newer."
            case .badResponse(let path, let status):
                return "Failed to download \(path) (HTTP \(status))."
            case .integrityCheckFailed(let path):
                return "Downloaded file \(path) failed the integrity check."
            }
        }
    }

    static let repository = "smkrv/gigaam-v3-e2e-rnnt-coreml"
    static let revision = "846833ef075fde2a8e50521d093ddb9ed7b7fd45"
    static let encoder = "GigaAMv3Encoder"
    static let decoder = "GigaAMv3DecoderStep"
    static let joint = "GigaAMv3JointStep"
    static let vocabularyFile = "tokens.json"

    static let files: [RemoteFile] = [
        RemoteFile(path: "GigaAMv3Encoder.mlpackage/Manifest.json", size: 617,
                   sha256: "6589ff6d3d3f814561449073ee12160bafb9f467c89159dc6a7240ef68235b04"),
        RemoteFile(path: "GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 419_364,
                   sha256: "f66bd914e5379bcddbbe7ef9d485c7e712443e5f5a880ce98a0cc0aafe3aeeeb"),
        RemoteFile(path: "GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 441_545_792,
                   sha256: "cacb9c2b41a62b3fcdb3522c0571a3196648dfe39dfb1df9a31969239c8e3877"),
        RemoteFile(path: "GigaAMv3DecoderStep.mlpackage/Manifest.json", size: 617,
                   sha256: "392239871ff24dbc7d1091dbe11982f202d8ce53e3ce9fb2f11cd671881ebbf9"),
        RemoteFile(path: "GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 7_367,
                   sha256: "71194a592055ad6a24ae4c980edcd52a25ea51c079b79f736033d07e00d6dfa5"),
        RemoteFile(path: "GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 2_297_280,
                   sha256: "5b23897e619a78cea140dbf3677efc92a58ed7935542047df7d452f03cf98edd"),
        RemoteFile(path: "GigaAMv3JointStep.mlpackage/Manifest.json", size: 617,
                   sha256: "378654b204d17a89750d807c95aa3bc4e3893bb808ca4c0e2f22259e3b210c42"),
        RemoteFile(path: "GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 2_916,
                   sha256: "9fa81aeaf320573eca794c17ad825d4c3ea7219f35414387732994df43a7bec3"),
        RemoteFile(path: "GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 1_356_098,
                   sha256: "bbd11afc9f9954dea7ddf860e13e57a24ae908e061c80ac3e8b0b9693fb4886d"),
        RemoteFile(path: vocabularyFile, size: 12_406,
                   sha256: "260c932355adc98a7440d49887f72a2fca42256971ad07a4e91265e93859ff69"),
    ]

    /// The Core ML export targets macOS 15.
    static var isSupported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    static var baseDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return applicationSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ru.starmel.OpenSuperWhisper")
            .appendingPathComponent("gigaam-models")
    }

    /// Installed, compiled model. Only ever replaced as a whole directory.
    static var directory: URL {
        baseDirectory.appendingPathComponent("v3-e2e-rnnt")
    }

    static func compiledModelURL(_ package: String, in directory: URL = directory) -> URL {
        directory.appendingPathComponent("\(package).mlmodelc")
    }

    static func vocabularyURL(in directory: URL = directory) -> URL {
        directory.appendingPathComponent(vocabularyFile)
    }

    private static func markerURL(in directory: URL) -> URL {
        directory.appendingPathComponent("revision")
    }

    /// The revision marker is written last, after every package compiled and
    /// before the directory is moved into place, so it marks a complete install.
    static var isInstalled: Bool {
        (try? String(contentsOf: markerURL(in: directory), encoding: .utf8)) == revision
    }

    static func install(progress: @escaping (Double) -> Void) async throws {
        guard isSupported else { throw ModelError.unsupportedOS }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let staging = baseDirectory.appendingPathComponent("staging-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }

        let sources = staging.appendingPathComponent("sources")
        let output = staging.appendingPathComponent("model")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

        // Downloads take 95% of the progress bar, compilation the rest.
        var completedBytes: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = sources.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = completedBytes
            try await fetch(file, to: destination) { bytes in
                progress(0.95 * Double(base + bytes) / Double(totalSize))
            }
            completedBytes += file.size
        }

        for package in [encoder, decoder, joint] {
            try Task.checkCancellation()
            let compiled = try await MLModel.compileModel(at: sources.appendingPathComponent("\(package).mlpackage"))
            try fileManager.moveItem(at: compiled, to: compiledModelURL(package, in: output))
        }
        try fileManager.moveItem(at: sources.appendingPathComponent(vocabularyFile), to: vocabularyURL(in: output))
        try revision.write(to: markerURL(in: output), atomically: true, encoding: .utf8)

        try Task.checkCancellation()
        if fileManager.fileExists(atPath: directory.path) {
            _ = try fileManager.replaceItemAt(directory, withItemAt: output)
        } else {
            try fileManager.moveItem(at: output, to: directory)
        }
        progress(1)
    }

    private static func fetch(
        _ file: RemoteFile,
        to destination: URL,
        progress: @escaping (Int64) -> Void
    ) async throws {
        let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }

        guard try sha256(of: destination) == file.sha256,
              (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == file.size else {
            throw ModelError.integrityCheckFailed(file.path)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let destination: URL
        let progress: (Int64) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        private var moveError: Error?

        init(destination: URL, progress: @escaping (Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                moveError = ModelError.badResponse(downloadTask.originalRequest?.url?.lastPathComponent ?? "", status)
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                moveError = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error as? URLError, error.code == .cancelled {
                continuation?.resume(throwing: CancellationError())
            } else if let error = error ?? moveError {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
            continuation = nil
        }
    }
}

/// Download state for the settings UI.
@MainActor
final class GigaAMModelStore: ObservableObject {
    static let shared = GigaAMModelStore()

    @Published private(set) var isInstalled = GigaAMModel.isInstalled
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0

    private var downloadTask: Task<Void, Error>?

    func download() async throws {
        if let downloadTask {
            return try await downloadTask.value
        }
        isDownloading = true
        progress = 0
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            try await GigaAMModel.install { fraction in
                Task { @MainActor in
                    guard let self, self.isDownloading else { return }
                    self.progress = fraction
                }
            }
        }
        downloadTask = task
        defer {
            downloadTask = nil
            isDownloading = false
            isInstalled = GigaAMModel.isInstalled
        }
        try await task.value
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }
}
