import XCTest
@testable import OpenSuperWhisper

final class NamedTestEngine: TranscriptionEngine {
    let engineName: String
    var isModelLoaded: Bool { true }
    init(_ name: String) { engineName = name }
    func initialize() async throws {}
    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { ["en"] }
    func transcribeAudio(url: URL, settings: Settings) async throws -> String { engineName }
}

actor EngineLoadGate {
    var requests: [String: CheckedContinuation<TranscriptionEngine, Error>] = [:]
    var count = 0
    func load(_ selection: TranscriptionService.EngineSelection) async throws -> TranscriptionEngine {
        try await withCheckedThrowingContinuation { continuation in
            count += 1
            requests[selection.engine] = continuation
        }
    }
    func hasRequest(_ name: String) -> Bool { requests[name] != nil }
    func finish(_ name: String, result: Result<TranscriptionEngine, Error>) {
        requests.removeValue(forKey: name)?.resume(with: result)
    }
}

@MainActor
final class EngineLoadingTests: XCTestCase {
    let a = TranscriptionService.EngineSelection(engine: "A", modelPath: nil, modelVersion: "v3")
    let b = TranscriptionService.EngineSelection(engine: "B", modelPath: nil, modelVersion: "v3")
    let url = URL(fileURLWithPath: "/unused.wav")

    func waitForRequest(_ name: String, gate: EngineLoadGate) async throws {
        for _ in 0..<100 {
            if await gate.hasRequest(name) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Loader was not called")
    }

    func waitForCompletion(_ service: TranscriptionService) async throws {
        for _ in 0..<100 where service.isLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(service.isLoading)
    }

    func testShutdownWaitsForSupersededLoadsAndPreventsNewWork() async throws {
        let gate = EngineLoadGate()
        let service = TranscriptionService(selection: a, engineLoader: { try await gate.load($0) })
        try await waitForRequest("A", gate: gate)
        service.loadEngine(selection: b)
        try await waitForRequest("B", gate: gate)
        var finished = false
        let shutdown = Task {
            await service.shutdown()
            finished = true
        }
        while !service.isShuttingDown { await Task.yield() }
        await gate.finish("B", result: .success(NamedTestEngine("B")))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(finished)
        await gate.finish("A", result: .success(NamedTestEngine("A")))
        await shutdown.value
        await service.shutdown()
        XCTAssertFalse(service.isLoading)
        service.loadEngine(selection: a)
        let count = await gate.count
        XCTAssertEqual(count, 2)
        do {
            _ = try await service.transcribeAudio(url: url, settings: Settings())
            XCTFail("Shutdown service accepted transcription")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLateOldLoadCannotReplaceNewSelection() async throws {
        let gate = EngineLoadGate()
        let service = TranscriptionService(selection: a, engineLoader: { try await gate.load($0) })
        try await waitForRequest("A", gate: gate)
        service.loadEngine(selection: b)
        try await waitForRequest("B", gate: gate)
        await gate.finish("B", result: .success(NamedTestEngine("B")))
        try await waitForCompletion(service)
        await gate.finish("A", result: .success(NamedTestEngine("A")))
        try await Task.sleep(nanoseconds: 20_000_000)
        let text = try await service.transcribeAudio(url: url, settings: Settings())
        XCTAssertEqual(text, "B")
    }

    func testTranscriptionWaitsForColdModelLoad() async throws {
        let gate = EngineLoadGate()
        let service = TranscriptionService(selection: a, engineLoader: { try await gate.load($0) })
        try await waitForRequest("A", gate: gate)
        let task = Task { try await service.transcribeAudio(url: url, settings: Settings()) }
        await Task.yield()
        XCTAssertTrue(service.isLoading)
        XCTAssertFalse(service.isTranscribing)
        await gate.finish("A", result: .success(NamedTestEngine("ready")))
        let text = try await task.value
        XCTAssertEqual(text, "ready")
    }

    func testCancelledWaiterDoesNotDecodeAfterModelLoads() async throws {
        let gate = EngineLoadGate()
        let service = TranscriptionService(selection: a, engineLoader: { try await gate.load($0) })
        try await waitForRequest("A", gate: gate)
        let task = Task { try await service.transcribeAudio(url: url, settings: Settings()) }
        await Task.yield()
        task.cancel()
        await gate.finish("A", result: .success(NamedTestEngine("ready")))
        do {
            _ = try await task.value
            XCTFail("Cancelled waiter decoded")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(service.transcribedText.isEmpty)
    }

    func testDuplicateSelectionLoadsOnceAndFailureIsExposed() async throws {
        let gate = EngineLoadGate()
        let service = TranscriptionService(selection: a, engineLoader: { try await gate.load($0) })
        try await waitForRequest("A", gate: gate)
        service.loadEngine(selection: a)
        let count = await gate.count
        XCTAssertEqual(count, 1)
        await gate.finish("A", result: .failure(TranscriptionError.contextInitializationFailed))
        try await waitForCompletion(service)
        XCTAssertNotNil(service.loadingError)
        do {
            _ = try await service.transcribeAudio(url: url, settings: Settings())
            XCTFail("Failed selection must not use another engine")
        } catch {}
    }
}
