import Foundation

struct PhononWord: Codable, Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

struct PhononTranscriptionResult: Codable, Equatable, Sendable {
    let text: String
    let words: [PhononWord]
    let audioSeconds: Double
    let decodeSeconds: Double
    let windows: Int
    let peakResidentMemoryBytes: UInt64?
}

struct PhononPreparationResult: Codable, Equatable, Sendable {
    let loadSeconds: Double
    let compileSeconds: Double
    let loadedFunctions: [Int]
    let peakResidentMemoryBytes: UInt64?
}

@objc(PhononXPCProtocol)
protocol PhononXPCProtocol {
    func prepare(modelDirectory: String, withReply reply: @escaping (Data?, String?) -> Void)
    func transcribe(samples: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func transcribe(filePath: String, withReply reply: @escaping (Data?, String?) -> Void)
    func cancel(withReply reply: @escaping () -> Void)
}

@objc(PhononXPCProgressProtocol)
protocol PhononXPCProgressProtocol {
    func phononProgress(phase: String, seconds: Double)
}

protocol PhononTranscribing: AnyObject {
    var onPreparationProgress: ((String, Double) -> Void)? { get set }
    func prepare(modelDirectory: URL) async throws -> PhononPreparationResult
    func transcribe(samples: [Float]) async throws -> PhononTranscriptionResult
    func transcribe(fileURL: URL) async throws -> PhononTranscriptionResult
    func cancel()
}

final class PhononXPCClient: NSObject, PhononTranscribing, PhononXPCProgressProtocol, @unchecked Sendable {
    static let serviceName = "ru.starmel.OpenSuperWhisper.PhononService"

    var onPreparationProgress: ((String, Double) -> Void)?
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var pendingReplies: [ObjectIdentifier: ReplyGate] = [:]
    private var cancellationInProgress = false

    private final class ReplyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var cancellationRequested = false

        init(_ continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
        }

        func requestCancellation() {
            lock.lock()
            cancellationRequested = true
            lock.unlock()
        }

        var canSubmit: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation != nil && !cancellationRequested
        }

        func resume(with result: Result<Data, Error>) -> Bool {
            lock.lock()
            guard !cancellationRequested, let continuation else {
                lock.unlock()
                return false
            }
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return true
        }

        func resumeCancellation() {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    deinit { connection?.invalidate() }

    func prepare(modelDirectory: URL) async throws -> PhononPreparationResult {
        let data = try await call { proxy, reply in
            proxy.prepare(modelDirectory: modelDirectory.path, withReply: reply)
        }
        return try JSONDecoder().decode(PhononPreparationResult.self, from: data)
    }

    func transcribe(samples: [Float]) async throws -> PhononTranscriptionResult {
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let data = try await call { proxy, reply in
            proxy.transcribe(samples: payload, withReply: reply)
        }
        return try JSONDecoder().decode(PhononTranscriptionResult.self, from: data)
    }

    func transcribe(fileURL: URL) async throws -> PhononTranscriptionResult {
        let data = try await call { proxy, reply in
            proxy.transcribe(filePath: fileURL.path, withReply: reply)
        }
        return try JSONDecoder().decode(PhononTranscriptionResult.self, from: data)
    }

    func cancel() {
        lock.lock()
        let connection = connection
        let pendingReplies = Array(self.pendingReplies.values)
        cancellationInProgress = connection != nil
        pendingReplies.forEach { $0.requestCancellation() }
        lock.unlock()

        guard let connection else {
            completeCancellation(for: nil, pendingReplies: pendingReplies)
            return
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
            self?.completeCancellation(for: connection, pendingReplies: pendingReplies)
        } as! PhononXPCProtocol
        proxy.cancel { [weak self, weak connection] in
            self?.completeCancellation(for: connection, pendingReplies: pendingReplies)
        }
    }

    func phononProgress(phase: String, seconds: Double) {
        onPreparationProgress?(phase, seconds)
    }

    private func call(_ body: @escaping (PhononXPCProtocol, @escaping (Data?, String?) -> Void) -> Void) async throws -> Data {
        try Task.checkCancellation()
        let connection = try currentConnection()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ReplyGate(continuation)
                register(gate)
                if Task.isCancelled {
                    cancel()
                    return
                }
                submit(gate, on: connection, body: body)
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    private func register(_ gate: ReplyGate) {
        lock.lock()
        pendingReplies[ObjectIdentifier(gate)] = gate
        lock.unlock()
    }

    private func submit(
        _ gate: ReplyGate,
        on connection: NSXPCConnection,
        body: (PhononXPCProtocol, @escaping (Data?, String?) -> Void) -> Void
    ) {
        lock.lock()
        guard gate.canSubmit else {
            lock.unlock()
            return
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            self.finish(gate, with: .failure(error))
        } as! PhononXPCProtocol
        body(proxy) { data, errorMessage in
            if let data {
                self.finish(gate, with: .success(data))
            } else {
                self.finish(gate, with: .failure(NSError(
                    domain: "PhononXPC",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "The Phonon service returned no result."]
                )))
            }
        }
        lock.unlock()
    }

    private func finish(_ gate: ReplyGate, with result: Result<Data, Error>) {
        guard gate.resume(with: result) else { return }
        lock.lock()
        pendingReplies.removeValue(forKey: ObjectIdentifier(gate))
        lock.unlock()
    }

    private func completeCancellation(for connection: NSXPCConnection?, pendingReplies: [ReplyGate]) {
        lock.lock()
        for gate in pendingReplies {
            self.pendingReplies.removeValue(forKey: ObjectIdentifier(gate))
        }
        if connection == nil || self.connection === connection {
            self.connection = nil
            cancellationInProgress = false
        }
        lock.unlock()
        connection?.invalidate()
        pendingReplies.forEach { $0.resumeCancellation() }
    }

    private func currentConnection() throws -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if cancellationInProgress { throw CancellationError() }
        if let connection { return connection }

        let newConnection = NSXPCConnection(serviceName: Self.serviceName)
        newConnection.remoteObjectInterface = NSXPCInterface(with: PhononXPCProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: PhononXPCProgressProtocol.self)
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.lock.lock()
            if self.connection === newConnection { self.connection = nil }
            self.lock.unlock()
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }
}

final class PhononEngine: PCMTranscriptionEngine, ProgressReportingTranscriptionEngine {
    var engineName: String { "Phonon-2" }
    var isModelLoaded = false
    var onProgressUpdate: ((Float) -> Void)?
    var onPreparationProgress: ((String, Double) -> Void)?
    private(set) var preparationMetrics: PhononPreparationResult?
    private(set) var lastResult: PhononTranscriptionResult?

    private let modelManager: PhononModelManager
    private let client: PhononTranscribing
    private var modelDirectory: URL?

    init(
        modelManager: PhononModelManager = .shared,
        client: PhononTranscribing = PhononXPCClient()
    ) {
        self.modelManager = modelManager
        self.client = client
    }

    func initialize() async throws {
        guard PhononPlatform.isSupported else { throw PhononModelError.unsupportedPlatform }
        let directory = try await modelManager.verifyInstalledModel()
        modelDirectory = directory
        try await prepareClient(in: directory)
    }

    private func prepareClient(in directory: URL) async throws {
        client.onPreparationProgress = { [weak self] phase, seconds in
            self?.onPreparationProgress?(phase, seconds)
        }
        preparationMetrics = try await client.prepare(modelDirectory: directory)
        isModelLoaded = true
    }

    private func ensurePrepared() async throws {
        if isModelLoaded { return }
        let directory: URL
        if let modelDirectory {
            directory = modelDirectory
        } else {
            directory = try await modelManager.verifyInstalledModel()
            modelDirectory = directory
        }
        try await prepareClient(in: directory)
    }

    func transcribeSamples(_ samples: [Float], settings: Settings) async throws -> String {
        try await ensurePrepared()
        try Task.checkCancellation()
        onProgressUpdate?(0.05)
        let result = try await client.transcribe(samples: samples)
        try Task.checkCancellation()
        lastResult = result
        onProgressUpdate?(0.95)
        return format(result, settings: settings)
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        try await ensurePrepared()
        try Task.checkCancellation()
        onProgressUpdate?(0.05)
        let result = try await client.transcribe(fileURL: url)
        try Task.checkCancellation()
        lastResult = result
        onProgressUpdate?(0.95)
        return format(result, settings: settings)
    }

    func cancelTranscription() {
        client.cancel()
        isModelLoaded = false
    }
    func getSupportedLanguages() -> [String] { ["en"] }

    private func format(_ result: PhononTranscriptionResult, settings: Settings) -> String {
        let text: String
        if settings.showTimestamps {
            text = result.words.map { String(format: "[%.1f->%.1f] %@", $0.start, $0.end, $0.text) }.joined(separator: "\n")
        } else {
            text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if settings.shouldApplyAsianAutocorrect && !text.isEmpty {
            return AutocorrectWrapper.format(text)
        }
        return text
    }
}
