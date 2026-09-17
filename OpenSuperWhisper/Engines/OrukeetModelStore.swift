import CoreML
import CryptoKit
import FluidAudio
import Foundation

/// Installs the portable Orukeet preview in its own cache. Network access happens only on installation.
enum OrukeetModelStore {
    static let revision = "43142dd1897f9ddadcd70173fcb5ff45c08aa951"
    static let archiveSHA256 = "b2a6efc4ed3280c860f29b3e2e2ea242ade14c6482c94f1c8d3e8551d5edb626"
    static let archiveBytes = 466_579_851
    static let components = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenSuperWhisper/Orukeet/coreml-baseline-20260915", isDirectory: true)
    }

    static var isInstalled: Bool {
        installed(at: directory)
    }

    static func installed(at directory: URL) -> Bool {
        let stamp = try? String(
            contentsOf: directory.appendingPathComponent(".revision"), encoding: .utf8)
        return stamp == revision
            && components.allSatisfy { name in
                let compiled = directory.appendingPathComponent("\(name).mlmodelc")
                return fileHasContents(compiled.appendingPathComponent("coremldata.bin"))
                    && fileHasContents(compiled.appendingPathComponent("weights/weight.bin"))
            } && fileHasContents(directory.appendingPathComponent("parakeet_vocab.json"))
    }

    private static func fileHasContents(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    struct Manifest: Decodable {
        struct Archive: Decodable {
            let filename: String
            let bytes: Int
            let sha256: String
        }
        let archives: [String: Archive]
    }

    static func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AsrModels {
        if !isInstalled {
            try await OrukeetInstallation.shared.install(progress: progress)
        }
        try Task.checkCancellation()
        progress(0.98)
        return try load(from: directory)
    }

    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard
            let base = URL(string: "https://huggingface.co/oruk/orukeet/resolve/\(revision)/coreml/")
        else {
            throw URLError(.badURL)
        }
        progress(0)
        // The NeMo repository's JSON manifest is counted by Hugging Face. It is also
        // consumed here to verify the pinned artifact, never fetched during transcription.
        let (metadata, response) = try await URLSession.shared.data(
            from: base.appendingPathComponent("manifest.json"))
        try validateHTTP(response)
        let archive = try validateManifest(metadata)
        try Task.checkCancellation()
        let temporary = try await downloadArchive(
            from: base.appendingPathComponent(archive.filename),
            expectedBytes: archive.bytes, progress: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        progress(0.9)
        try installArchive(at: temporary, to: directory)
    }

    static func validateManifest(_ data: Data) throws -> Manifest.Archive {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard let archive = manifest.archives["baseline"],
              archive.filename == "orukeet-r3-coreml-baseline.zip",
              archive.bytes == archiveBytes, archive.sha256 == archiveSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return archive
    }

    static func downloadArchive(
        from url: URL, expectedBytes: Int, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        guard expectedBytes > 0 else { throw CocoaError(.fileReadCorruptFile) }
        progress(0)
        let transfer = DownloadTransfer(expectedBytes: expectedBytes, progress: progress)
        let (temporary, response) = try await transfer.download(from: url)
        do {
            try validateHTTP(response)
            try Task.checkCancellation()
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // The async URLSession convenience does not forward download progress on macOS.
    private final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let expectedBytes: Int
        private let progress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var cancelled = false
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        // Both delegate callbacks run on URLSession's serial delegate queue.
        private var result: Result<(URL, URLResponse), Error>?

        init(expectedBytes: Int, progress: @escaping @Sendable (Double) -> Void) {
            self.expectedBytes = expectedBytes
            self.progress = progress
        }

        func download(from url: URL) async throws -> (URL, URLResponse) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock {
                        guard !cancelled else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        self.continuation = continuation
                        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                        let task = session.downloadTask(with: url)
                        self.task = task
                        task.resume()
                    }
                }
            } onCancel: {
                self.lock.withLock {
                    self.cancelled = true
                    self.task?.cancel()
                }
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            // The pinned manifest supplies a length even when an HF redirect does not.
            progress(min(0.9, max(0, Double(totalBytesWritten) / Double(expectedBytes) * 0.9)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            result = Result {
                guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
                let retained = FileManager.default.temporaryDirectory
                    .appendingPathComponent("OrukeetDownload-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: location, to: retained)
                return (retained, response)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                if case .success(let (url, _)) = result { try? FileManager.default.removeItem(at: url) }
                result = .failure(error)
            }
            let completion = lock.withLock {
                defer { continuation = nil; self.task = nil }
                return continuation
            }
            completion?.resume(with: result ?? .failure(URLError(.badServerResponse)))
            session.finishTasksAndInvalidate()
        }
    }

    /// Separate from acquisition so the exact installer can be regression-tested with the pinned archive offline.
    static func installArchive(at archive: URL, to destination: URL) throws {
        guard try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize == archiveBytes,
            try checksum(of: archive) == archiveSHA256
        else { throw CocoaError(.fileReadCorruptFile) }
        let files = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".install-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unpack.arguments = ["-x", "-k", archive.path, staging.path]
        try unpack.run()
        unpack.waitUntilExit()
        guard unpack.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        let bundle = staging.appendingPathComponent("orukeet-r3-coreml-baseline", isDirectory: true)
        for name in components {
            try Task.checkCancellation()
            let compiled = try MLModel.compileModel(
                at: bundle.appendingPathComponent("\(name).mlpackage"))
            defer { try? files.removeItem(at: compiled) }
            try files.moveItem(at: compiled, to: bundle.appendingPathComponent("\(name).mlmodelc"))
            try files.removeItem(at: bundle.appendingPathComponent("\(name).mlpackage"))
        }
        // Reject an incompatible vocabulary before making the install visible.
        _ = try vocabulary(in: bundle)
        try revision.write(
            to: bundle.appendingPathComponent(".revision"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        try commitInstallation(from: bundle, to: destination)
    }

    /// Replace the installed directory without a gap that can strand a previous cache.
    static func commitInstallation(from bundle: URL, to destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: bundle, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: bundle, to: destination)
        }
    }

    static func load(from directory: URL) throws -> AsrModels {
        let vocabulary = try vocabulary(in: directory)
        func component(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(
                contentsOf: directory.appendingPathComponent("\(name).mlmodelc"),
                configuration: configuration)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return try AsrModels(
            encoder: component("Encoder", .cpuAndNeuralEngine),
            preprocessor: component("Preprocessor", .cpuOnly),
            decoder: component("Decoder", .cpuAndNeuralEngine),
            joint: component("JointDecisionv3", .cpuAndNeuralEngine),
            configuration: configuration, vocabulary: vocabulary, version: .v3)
    }

    private static func vocabulary(in directory: URL) throws -> [Int: String] {
        let data = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        var result: [Int: String] = [:]
        for (key, token) in raw {
            guard let id = Int(key), (0..<8192).contains(id), result[id] == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result[id] = token
        }
        guard result.count == 8192 else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    private static func checksum(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}

/// Coalesce model preparation so selecting a model during a download cannot start
/// another transfer or replace a directory while the first install is compiling.
actor OrukeetInstallation {
    static let shared = OrukeetInstallation()

    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let progress: @Sendable (Double) -> Void
    }
    private struct Installation {
        let id: UUID
        let task: Task<Void, Error>
        var waiters: [UUID: Waiter]
        var progress: Double = 0
    }

    private var installation: Installation?
    private let operation: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void

    init(
        operation: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void = { progress in
            guard !OrukeetModelStore.isInstalled else { return }
            try await OrukeetModelStore.install(progress: progress)
        }
    ) {
        self.operation = operation
    }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        // A cancelled last waiter may still be unwinding network/compilation work.
        // Finish cleanup before another caller can start writing the same directory.
        while let current = installation, current.task.isCancelled {
            let result = await current.task.result
            finish(id: current.id, result: result)
        }
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(continuation: continuation, progress: progress)
                if installation != nil {
                    installation?.waiters[waiterID] = waiter
                    progress(installation?.progress ?? 0)
                    return
                }
                let id = UUID()
                let task = Task {
                    try await operation { fraction in
                        Task { await self.reportProgress(fraction, id: id) }
                    }
                }
                installation = Installation(id: id, task: task, waiters: [waiterID: waiter])
                progress(0)
                Task {
                    let result = await task.result
                    finish(id: id, result: result)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
        try Task.checkCancellation()
    }

    private func reportProgress(_ fraction: Double, id: UUID) {
        guard var current = installation, current.id == id else { return }
        current.progress = min(1, max(current.progress, fraction))
        installation = current
        for waiter in current.waiters.values { waiter.progress(current.progress) }
    }

    private func cancelWaiter(id: UUID) {
        guard let waiter = installation?.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if let current = installation, current.waiters.isEmpty { current.task.cancel() }
    }

    private func finish(id: UUID, result: Result<Void, Error>) {
        guard let current = installation, current.id == id else { return }
        installation = nil
        for waiter in current.waiters.values { waiter.continuation.resume(with: result) }
    }
}
