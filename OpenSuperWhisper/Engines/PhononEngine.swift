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
    var isPrepared: Bool { get }
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
    private var connectionID: UInt64?
    private var nextConnectionID: UInt64 = 0
    private var preparedConnectionID: UInt64?
    private var pendingReplies: [ObjectIdentifier: ReplyGate] = [:]
    private var cancellationInProgress = false

    private struct ConnectionHandle {
        let connection: NSXPCConnection
        let id: UInt64
    }

    private struct CallResponse {
        let data: Data
        let connectionID: UInt64
    }

    private enum ClientError: LocalizedError {
        case notPrepared
        case connectionInvalidated

        var errorDescription: String? {
            switch self {
            case .notPrepared: return "Phonon-2 is not prepared."
            case .connectionInvalidated: return "The Phonon-2 helper connection was interrupted."
            }
        }
    }

    private final class ReplyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CallResponse, Error>?
        private var cancellationRequested = false

        init(_ continuation: CheckedContinuation<CallResponse, Error>) {
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

        var isCancellationRequested: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationRequested
        }

        func resume(with result: Result<CallResponse, Error>) -> Bool {
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

    var isPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != nil
            && connectionID != nil
            && preparedConnectionID == connectionID
            && !cancellationInProgress
    }

    func prepare(modelDirectory: URL) async throws -> PhononPreparationResult {
        let response = try await call { proxy, reply in
            proxy.prepare(modelDirectory: modelDirectory.path, withReply: reply)
        }
        let result = try JSONDecoder().decode(PhononPreparationResult.self, from: response.data)
        guard markPrepared(connectionID: response.connectionID) else {
            throw ClientError.connectionInvalidated
        }
        return result
    }

    func transcribe(samples: [Float]) async throws -> PhononTranscriptionResult {
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let response = try await call(requiresPrepared: true) { proxy, reply in
            proxy.transcribe(samples: payload, withReply: reply)
        }
        return try JSONDecoder().decode(PhononTranscriptionResult.self, from: response.data)
    }

    func transcribe(fileURL: URL) async throws -> PhononTranscriptionResult {
        let response = try await call(requiresPrepared: true) { proxy, reply in
            proxy.transcribe(filePath: fileURL.path, withReply: reply)
        }
        return try JSONDecoder().decode(PhononTranscriptionResult.self, from: response.data)
    }

    func cancel() {
        lock.lock()
        if cancellationInProgress {
            lock.unlock()
            return
        }
        let connection = connection
        let pendingReplies = Array(self.pendingReplies.values)
        let preservePreparedConnection = connection != nil
            && connectionID != nil
            && preparedConnectionID == connectionID
        cancellationInProgress = connection != nil
        if !preservePreparedConnection {
            preparedConnectionID = nil
        }
        pendingReplies.forEach { $0.requestCancellation() }
        lock.unlock()

        guard let connection else {
            completeCancellation(
                for: nil,
                pendingReplies: pendingReplies,
                preservePreparedConnection: false
            )
            return
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.completeCancellation(
                for: connection,
                pendingReplies: pendingReplies,
                preservePreparedConnection: false
            )
        } as! PhononXPCProtocol
        proxy.cancel { [weak self] in
            self?.completeCancellation(
                for: connection,
                pendingReplies: pendingReplies,
                preservePreparedConnection: preservePreparedConnection
            )
        }
    }

    func phononProgress(phase: String, seconds: Double) {
        onPreparationProgress?(phase, seconds)
    }

    private func call(
        requiresPrepared: Bool = false,
        _ body: @escaping (PhononXPCProtocol, @escaping (Data?, String?) -> Void) -> Void
    ) async throws -> CallResponse {
        try Task.checkCancellation()
        let connection = try currentConnection(requiresPrepared: requiresPrepared)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ReplyGate(continuation)
                if let error = register(gate, on: connection) {
                    _ = gate.resume(with: .failure(error))
                    return
                }
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

    private func register(_ gate: ReplyGate, on connection: ConnectionHandle) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        if cancellationInProgress { return CancellationError() }
        guard self.connection === connection.connection,
              connectionID == connection.id else {
            return ClientError.connectionInvalidated
        }
        pendingReplies[ObjectIdentifier(gate)] = gate
        return nil
    }

    private func submit(
        _ gate: ReplyGate,
        on connection: ConnectionHandle,
        body: (PhononXPCProtocol, @escaping (Data?, String?) -> Void) -> Void
    ) {
        lock.lock()
        guard gate.canSubmit else {
            lock.unlock()
            return
        }
        if cancellationInProgress {
            lock.unlock()
            finish(gate, with: .failure(CancellationError()))
            return
        }
        guard self.connection === connection.connection,
              connectionID == connection.id else {
            lock.unlock()
            finish(gate, with: .failure(ClientError.connectionInvalidated))
            return
        }
        let proxy = connection.connection.remoteObjectProxyWithErrorHandler { [weak self, weak xpcConnection = connection.connection] error in
            guard let self, let xpcConnection else { return }
            self.failConnection(xpcConnection, with: error)
        } as! PhononXPCProtocol
        body(proxy) { data, errorMessage in
            if let data {
                self.finish(gate, with: .success(CallResponse(data: data, connectionID: connection.id)))
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

    private func finish(_ gate: ReplyGate, with result: Result<CallResponse, Error>) {
        guard gate.resume(with: result) else { return }
        lock.lock()
        pendingReplies.removeValue(forKey: ObjectIdentifier(gate))
        lock.unlock()
    }

    private func completeCancellation(
        for connection: NSXPCConnection?,
        pendingReplies: [ReplyGate],
        preservePreparedConnection: Bool
    ) {
        lock.lock()
        for gate in pendingReplies {
            self.pendingReplies.removeValue(forKey: ObjectIdentifier(gate))
        }
        let canPreserveConnection = preservePreparedConnection
            && connection != nil
            && self.connection === connection
            && connectionID != nil
            && preparedConnectionID == connectionID
        if canPreserveConnection {
            cancellationInProgress = false
        } else if connection == nil {
            cancellationInProgress = false
        } else if self.connection == nil || self.connection === connection {
            self.connection = nil
            connectionID = nil
            preparedConnectionID = nil
            cancellationInProgress = false
        }
        lock.unlock()
        if !canPreserveConnection {
            connection?.invalidate()
        }
        pendingReplies.forEach { $0.resumeCancellation() }
    }

    private func markPrepared(connectionID: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard connection != nil,
              self.connectionID == connectionID,
              !cancellationInProgress else { return false }
        preparedConnectionID = connectionID
        return true
    }

    private func failConnection(_ failedConnection: NSXPCConnection, with error: Error) {
        lock.lock()
        guard connection === failedConnection else {
            lock.unlock()
            return
        }
        connection = nil
        connectionID = nil
        preparedConnectionID = nil
        cancellationInProgress = false
        let pendingReplies = Array(self.pendingReplies.values)
        self.pendingReplies.removeAll()
        lock.unlock()

        failedConnection.invalidate()
        for gate in pendingReplies {
            if gate.isCancellationRequested {
                gate.resumeCancellation()
            } else {
                _ = gate.resume(with: .failure(error))
            }
        }
    }

    private func currentConnection(requiresPrepared: Bool) throws -> ConnectionHandle {
        lock.lock()
        defer { lock.unlock() }
        if cancellationInProgress { throw CancellationError() }
        if let connection, let connectionID {
            if requiresPrepared && preparedConnectionID != connectionID {
                throw ClientError.notPrepared
            }
            return ConnectionHandle(connection: connection, id: connectionID)
        }
        if requiresPrepared { throw ClientError.notPrepared }

        let newConnection = NSXPCConnection(serviceName: Self.serviceName)
        nextConnectionID &+= 1
        let newConnectionID = nextConnectionID
        newConnection.remoteObjectInterface = NSXPCInterface(with: PhononXPCProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: PhononXPCProgressProtocol.self)
        newConnection.exportedObject = self
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.failConnection(newConnection, with: ClientError.connectionInvalidated)
        }
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.failConnection(newConnection, with: ClientError.connectionInvalidated)
        }
        newConnection.resume()
        connection = newConnection
        connectionID = newConnectionID
        return ConnectionHandle(connection: newConnection, id: newConnectionID)
    }
}

final class PhononEngine: PCMTranscriptionEngine, ProgressReportingTranscriptionEngine {
    var engineName: String { "Phonon-2" }
    var isModelLoaded: Bool { client.isPrepared }
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
    }

    private func ensurePrepared() async throws {
        if client.isPrepared { return }
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
