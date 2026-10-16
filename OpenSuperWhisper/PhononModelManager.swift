import CryptoKit
import Foundation

struct PhononModelFile: Codable, Equatable, Sendable {
    let path: String
    let byteCount: Int64
    let sha256: String
}

struct PhononModelRelease: Codable, Equatable, Sendable {
    let runtimeVersion: String
    let repositoryRevision: String
    let manifestVersion: String
    let compiledCacheKey: String
    let files: [PhononModelFile]

    static let pinned = PhononModelRelease(
        runtimeVersion: "1.1.2",
        repositoryRevision: "1143812fd4236522232a8c33e3115f0577e3cd7d",
        manifestVersion: "3.0",
        compiledCacheKey: "4b6bfa3a12cc3c4e-0f6c074cb6fd1c3b",
        files: [
            .init(path: "decoder.bin", byteCount: 13_301_279, sha256: "36fa7202dda85c603af60d930ab88d7e9f0d2a619490aff46f5384db924cfa70"),
            .init(path: "manifest.json", byteCount: 1_428, sha256: "ab3fb5dfd3fc07b1d8a24379d04418f458d0443ba6359d3a5ab2f098a7d64089"),
            .init(path: "Phonon-2.mlpackage/Manifest.json", byteCount: 617, sha256: "6ebc9309aea0e16bda9c7558521fef6307fac0afba9a5b4959fea45ed7cd0429"),
            .init(path: "Phonon-2.mlpackage/Data/com.apple.CoreML/model.mlmodel", byteCount: 2_500_482, sha256: "4f6790ec94fe4429b10397c013563d0a51119953ff6d3da466bbcb23a25dee2a"),
            .init(path: "Phonon-2.mlpackage/Data/com.apple.CoreML/weights/weight.bin", byteCount: 329_186_560, sha256: "93aa991318a00ed492fdbb724e7bca4e6a69c6cf671ab4f14a14ef6101e7648b"),
            .init(path: "LICENSE-WEIGHTS-CC-BY-4.0.txt", byteCount: 18_657, sha256: "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411"),
            .init(path: "NOTICE", byteCount: 3_084, sha256: "b468a23a1ce2c5181ea4050432bb68713a6468ce2e452927228d24f3d56226be"),
        ]
    )

    var downloadSize: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    var versionDirectoryName: String { "phonon-2-\(repositoryRevision.prefix(12))" }

    func downloadURL(for file: PhononModelFile) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/FermionResearch/Phonon-2-CoreML/resolve/\(repositoryRevision)/\(file.path)"
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        return components.url!
    }
}

extension PhononModelRelease {
    private enum CodingKeys: String, CodingKey {
        case runtimeVersion
        case repositoryRevision
        case manifestVersion
        case compiledCacheKey
        case files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeVersion = try container.decode(String.self, forKey: .runtimeVersion)
        repositoryRevision = try container.decode(String.self, forKey: .repositoryRevision)
        manifestVersion = try container.decode(String.self, forKey: .manifestVersion)
        files = try container.decode([PhononModelFile].self, forKey: .files)
        compiledCacheKey = try container.decodeIfPresent(String.self, forKey: .compiledCacheKey)
            ?? Self.legacyCompiledCacheKey(runtimeVersion: runtimeVersion, repositoryRevision: repositoryRevision)
            ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runtimeVersion, forKey: .runtimeVersion)
        try container.encode(repositoryRevision, forKey: .repositoryRevision)
        try container.encode(manifestVersion, forKey: .manifestVersion)
        try container.encode(compiledCacheKey, forKey: .compiledCacheKey)
        try container.encode(files, forKey: .files)
    }

    private static func legacyCompiledCacheKey(runtimeVersion: String, repositoryRevision: String) -> String? {
        guard runtimeVersion == "1.1.2",
              repositoryRevision == "1143812fd4236522232a8c33e3115f0577e3cd7d" else { return nil }
        return "4b6bfa3a12cc3c4e-0f6c074cb6fd1c3b"
    }
}

enum PhononModelError: LocalizedError, Equatable {
    case unsupportedPlatform
    case missingFile(String)
    case invalidSize(path: String, expected: Int64, actual: Int64)
    case checksumMismatch(path: String, expected: String, actual: String)
    case invalidManifestVersion(expected: String, actual: String)
    case activationRecoveryRequired(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Phonon-2 requires an Apple silicon Mac running macOS 15 or later."
        case .missingFile(let path):
            return "The Phonon-2 model is incomplete (missing \(path))."
        case let .invalidSize(path, expected, actual):
            return "The Phonon-2 download has the wrong size for \(path) (expected \(expected), got \(actual))."
        case let .checksumMismatch(path, expected, actual):
            return "The Phonon-2 checksum failed for \(path) (expected \(expected), got \(actual))."
        case let .invalidManifestVersion(expected, actual):
            return "Unsupported Phonon-2 manifest version \(actual) (expected \(expected))."
        case .activationRecoveryRequired(let reason):
            return "Phonon-2 model activation needs repair: \(reason)"
        }
    }
}

enum PhononPlatform {
    static var isSupported: Bool {
        #if arch(arm64)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }
}

protocol PhononDownloading: Sendable {
    func download(from source: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

final class URLSessionPhononDownloader: NSObject, PhononDownloading, @unchecked Sendable {
    private final class Operation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Int64, Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var session: URLSession?
        private var task: URLSessionDownloadTask?
        private var completed = false
        private var cancelled = false

        init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func start(_ source: URL, continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.downloadTask(with: source)
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
            else { task.resume() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: location, to: destination)
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
            else { finish(.success(())) }
        }

        private func finish(_ result: Result<Void, Error>) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            let continuation = continuation
            self.continuation = nil
            task = nil
            let session = session
            self.session = nil
            lock.unlock()
            session?.finishTasksAndInvalidate()
            continuation?.resume(with: result)
        }
    }

    func download(from source: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let operation = Operation(destination: destination, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(source, continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

final class PhononModelManager: @unchecked Sendable {
    struct ActivationTransaction: Codable, Equatable {
        let activePath: String
        let stagingPath: String
        let backupPath: String
        let expectedRelease: PhononModelRelease
    }

    static let shared = PhononModelManager()

    let release: PhononModelRelease
    let modelsDirectory: URL
    private let downloader: PhononDownloading
    private let fileManager: FileManager
    private let activationMove: (URL, URL) throws -> Void
    private let activationLock = NSLock()

    init(
        release: PhononModelRelease = .pinned,
        modelsDirectory: URL? = nil,
        downloader: PhononDownloading = URLSessionPhononDownloader(),
        fileManager: FileManager = .default,
        activationMove: ((URL, URL) throws -> Void)? = nil
    ) {
        self.release = release
        self.fileManager = fileManager
        self.downloader = downloader
        self.activationMove = activationMove ?? { source, destination in
            try fileManager.moveItem(at: source, to: destination)
        }
        if let modelsDirectory {
            self.modelsDirectory = modelsDirectory
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.modelsDirectory = support
                .appendingPathComponent("ru.starmel.OpenSuperWhisper", isDirectory: true)
                .appendingPathComponent("phonon-models", isDirectory: true)
        }
        _ = try? reconcileActivationTransaction()
    }

    var modelDirectory: URL { modelsDirectory.appendingPathComponent(release.versionDirectoryName, isDirectory: true) }
    var activationMarkerURL: URL { modelDirectory.appendingPathComponent("installed.json") }
    var activationJournalURL: URL {
        modelsDirectory.appendingPathComponent(".\(release.versionDirectoryName).activation.json")
    }

    var isModelInstalled: Bool {
        do {
            try reconcileActivationTransaction()
        } catch {
            return false
        }
        guard let marker = try? Data(contentsOf: activationMarkerURL),
              (try? JSONDecoder().decode(PhononModelRelease.self, from: marker)) == release else { return false }
        return release.files.allSatisfy { file in
            let url = modelDirectory.appendingPathComponent(file.path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize else { return false }
            return Int64(fileSize) == file.byteCount
        }
    }

    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard PhononPlatform.isSupported else { throw PhononModelError.unsupportedPlatform }
        try Task.checkCancellation()
        try reconcileActivationTransaction()

        let staging = modelsDirectory.appendingPathComponent(".\(release.versionDirectoryName)-\(UUID().uuidString).download", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            if !fileManager.fileExists(atPath: activationJournalURL.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        var completedBytes: Int64 = 0
        for file in release.files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            let base = completedBytes
            try await downloader.download(from: release.downloadURL(for: file), to: destination) { received, _ in
                progress(min(1, Double(base + max(0, received)) / Double(self.release.downloadSize)))
            }
            try Self.verify(file: file, at: destination, fileManager: fileManager)
            completedBytes += file.byteCount
            progress(Double(completedBytes) / Double(release.downloadSize))
        }

        try validateManifest(in: staging)
        let marker = try JSONEncoder().encode(release)
        try marker.write(to: staging.appendingPathComponent("installed.json"), options: .atomic)
        try Task.checkCancellation()

        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try activate(staging: staging)
        progress(1)
    }

    func verifyInstalledModel() async throws -> URL {
        try reconcileActivationTransaction()
        let directory = modelDirectory
        let release = release
        let fileManager = fileManager
        return try await Task.detached(priority: .utility) {
            let markerURL = directory.appendingPathComponent("installed.json")
            guard let marker = try? Data(contentsOf: markerURL),
                  (try? JSONDecoder().decode(PhononModelRelease.self, from: marker)) == release else {
                throw PhononModelError.missingFile("installed.json")
            }
            for file in release.files {
                try Task.checkCancellation()
                try Self.verify(file: file, at: directory.appendingPathComponent(file.path), fileManager: fileManager)
            }
            let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let actual = manifest?["version"] as? String ?? "missing"
            guard actual == release.manifestVersion else {
                throw PhononModelError.invalidManifestVersion(expected: release.manifestVersion, actual: actual)
            }
            return directory
        }.value
    }

    func deleteModel() throws {
        try reconcileActivationTransaction()
        let cache = compiledCacheDirectoryURL
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try fileManager.removeItem(at: modelDirectory)
        }
        if fileManager.fileExists(atPath: cache.path) {
            try fileManager.removeItem(at: cache)
        }
    }

    func storageBytes() -> Int64 {
        try? reconcileActivationTransaction()
        var paths = Set([modelDirectory.standardizedFileURL.path, compiledCacheDirectoryURL.standardizedFileURL.path])
        for candidate in activationCandidateDirectories() {
            paths.insert(candidate.standardizedFileURL.path)
        }
        let journalBytes = ((try? fileManager.attributesOfItem(atPath: activationJournalURL.path)[.size] as? NSNumber)?.int64Value) ?? 0
        return paths.reduce(journalBytes) { total, path in
            total + Self.directorySize(URL(fileURLWithPath: path), fileManager: fileManager)
        }
    }

    private func validateManifest(in directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let actual = manifest?["version"] as? String ?? "missing"
        guard actual == release.manifestVersion else {
            throw PhononModelError.invalidManifestVersion(expected: release.manifestVersion, actual: actual)
        }
    }

    @discardableResult
    func beginActivationTransaction(staging: URL, backup: URL) throws -> ActivationTransaction {
        activationLock.lock()
        defer { activationLock.unlock() }
        return try writeActivationTransaction(staging: staging, backup: backup)
    }

    private func activate(staging: URL) throws {
        activationLock.lock()
        defer { activationLock.unlock() }
        let active = modelDirectory
        let backup = modelsDirectory.appendingPathComponent(
            ".\(release.versionDirectoryName)-\(UUID().uuidString).backup",
            isDirectory: true
        )
        _ = try writeActivationTransaction(staging: staging, backup: backup)

        if fileManager.fileExists(atPath: active.path) {
            do {
                try activationMove(active, backup)
            } catch {
                let activationError = error
                try reconcileActivationTransactionLocked()
                throw activationError
            }
        }

        do {
            try activationMove(staging, active)
        } catch {
            let activationError = error
            try reconcileActivationTransactionLocked()
            throw activationError
        }

        try reconcileActivationTransactionLocked()
    }

    private func writeActivationTransaction(staging: URL, backup: URL) throws -> ActivationTransaction {
        let transaction = ActivationTransaction(
            activePath: modelDirectory.standardizedFileURL.path,
            stagingPath: staging.standardizedFileURL.path,
            backupPath: backup.standardizedFileURL.path,
            expectedRelease: release
        )
        try validate(transaction)
        let data = try JSONEncoder().encode(transaction)
        try data.write(to: activationJournalURL, options: .atomic)
        return transaction
    }

    private func reconcileActivationTransaction() throws {
        activationLock.lock()
        defer { activationLock.unlock() }
        try reconcileActivationTransactionLocked()
    }

    private func reconcileActivationTransactionLocked() throws {
        guard fileManager.fileExists(atPath: activationJournalURL.path) else {
            if activationCandidateDirectories().contains(where: { $0.pathExtension == "backup" }) {
                throw PhononModelError.activationRecoveryRequired("an activation backup exists without its transaction record")
            }
            return
        }

        let transaction: ActivationTransaction
        do {
            let data = try Data(contentsOf: activationJournalURL)
            transaction = try JSONDecoder().decode(ActivationTransaction.self, from: data)
            try validate(transaction)
        } catch let error as PhononModelError {
            throw error
        } catch {
            throw PhononModelError.activationRecoveryRequired("the activation transaction record is corrupt")
        }

        let active = URL(fileURLWithPath: transaction.activePath, isDirectory: true)
        let staging = URL(fileURLWithPath: transaction.stagingPath, isDirectory: true)
        let backup = URL(fileURLWithPath: transaction.backupPath, isDirectory: true)

        if isValidInstalledModel(at: active) {
            try removeIfPresent(backup)
            try removeIfPresent(staging)
            try removeIfPresent(activationJournalURL)
            return
        }

        guard !fileManager.fileExists(atPath: active.path) else {
            throw PhononModelError.activationRecoveryRequired("the active model is present but invalid; all activation candidates were preserved")
        }
        guard isValidInstalledModel(at: backup) else {
            throw PhononModelError.activationRecoveryRequired("the active model is missing and its recorded backup is invalid; all activation candidates were preserved")
        }

        try fileManager.moveItem(at: backup, to: active)
        guard isValidInstalledModel(at: active) else {
            throw PhononModelError.activationRecoveryRequired("the restored model did not validate; all activation candidates were preserved")
        }
        try removeIfPresent(staging)
        try removeIfPresent(activationJournalURL)
    }

    private func validate(_ transaction: ActivationTransaction) throws {
        let root = modelsDirectory.standardizedFileURL
        let active = URL(fileURLWithPath: transaction.activePath, isDirectory: true).standardizedFileURL
        let staging = URL(fileURLWithPath: transaction.stagingPath, isDirectory: true).standardizedFileURL
        let backup = URL(fileURLWithPath: transaction.backupPath, isDirectory: true).standardizedFileURL
        let expectedPrefix = ".\(release.versionDirectoryName)-"
        guard transaction.expectedRelease == release,
              active.path == modelDirectory.standardizedFileURL.path,
              staging.deletingLastPathComponent().path == root.path,
              backup.deletingLastPathComponent().path == root.path,
              staging.lastPathComponent.hasPrefix(expectedPrefix),
              staging.pathExtension == "download",
              backup.lastPathComponent.hasPrefix(expectedPrefix),
              backup.pathExtension == "backup",
              staging.path != backup.path,
              staging.path != active.path,
              backup.path != active.path else {
            throw PhononModelError.activationRecoveryRequired("the activation transaction record does not match the pinned model or storage paths")
        }
    }

    private func isValidInstalledModel(at directory: URL) -> Bool {
        do {
            let marker = try Data(contentsOf: directory.appendingPathComponent("installed.json"))
            guard try JSONDecoder().decode(PhononModelRelease.self, from: marker) == release else { return false }
            for file in release.files {
                try Self.verify(file: file, at: directory.appendingPathComponent(file.path), fileManager: fileManager)
            }
            try validateManifest(in: directory)
            return true
        } catch {
            return false
        }
    }

    private func activationCandidateDirectories() -> [URL] {
        let prefix = ".\(release.versionDirectoryName)-"
        let contents = (try? fileManager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        return contents.filter {
            $0.lastPathComponent.hasPrefix(prefix)
                && ($0.pathExtension == "backup" || $0.pathExtension == "download")
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func verify(file: PhononModelFile, at url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { throw PhononModelError.missingFile(file.path) }
        let size = (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == file.byteCount else {
            throw PhononModelError.invalidSize(path: file.path, expected: file.byteCount, actual: size)
        }
        let actual = try sha256(url)
        guard actual == file.sha256 else {
            throw PhononModelError.checksumMismatch(path: file.path, expected: file.sha256, actual: actual)
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 4 * 1_024 * 1_024)
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var compiledCacheDirectoryURL: URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("phonon-coreml", isDirectory: true)
            .appendingPathComponent(release.compiledCacheKey, isDirectory: true)
    }

    private static func directorySize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
