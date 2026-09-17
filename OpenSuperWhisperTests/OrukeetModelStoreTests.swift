import XCTest
@testable import OpenSuperWhisper

final class OrukeetModelStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func manifest(filename: String = "orukeet-r3-coreml-baseline.zip",
                          bytes: Int = OrukeetModelStore.archiveBytes,
                          sha256: String = OrukeetModelStore.archiveSHA256) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["archives": ["baseline": [
            "filename": filename, "bytes": bytes, "sha256": sha256,
        ]]])
    }

    func testManifestRejectsChangedArtifactMetadata() throws {
        XCTAssertNoThrow(try OrukeetModelStore.validateManifest(manifest()))
        XCTAssertThrowsError(try OrukeetModelStore.validateManifest(manifest(filename: "other.zip")))
        XCTAssertThrowsError(try OrukeetModelStore.validateManifest(manifest(bytes: 1)))
        XCTAssertThrowsError(try OrukeetModelStore.validateManifest(manifest(sha256: "incorrect")))
        XCTAssertThrowsError(try OrukeetModelStore.validateManifest(Data("{}".utf8)))
    }

    func testIncompleteCacheIsNotInstalled() throws {
        let directory = try temporaryDirectory()
        try OrukeetModelStore.revision.write(to: directory.appendingPathComponent(".revision"),
                                            atomically: true, encoding: .utf8)
        XCTAssertFalse(OrukeetModelStore.installed(at: directory))
        XCTAssertThrowsError(try OrukeetModelStore.load(from: directory))
    }

    func testCorruptArchivePreservesExistingCache() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("previous")
        try Data("valid previous install".utf8).write(to: marker)
        let archive = directory.appendingPathComponent("corrupt.zip")
        try Data("corrupt".utf8).write(to: archive)
        XCTAssertThrowsError(try OrukeetModelStore.installArchive(at: archive, to: destination))
        XCTAssertEqual(try Data(contentsOf: marker), Data("valid previous install".utf8))
    }

    func testFailedCommitRestoresExistingCache() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("previous")
        try Data("previous".utf8).write(to: marker)
        XCTAssertThrowsError(try OrukeetModelStore.commitInstallation(
            from: directory.appendingPathComponent("missing"), to: destination))
        XCTAssertEqual(try Data(contentsOf: marker), Data("previous".utf8))
    }

    func testReplacementCommitsNewContentsWithoutLeavingBackup() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("installed")
        let replacement = directory.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("model"))
        try Data("new".utf8).write(to: replacement.appendingPathComponent("model"))
        try OrukeetModelStore.commitInstallation(from: replacement, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("model")), Data("new".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["installed"])
    }

    func testCancellingFirstCallerPreservesOtherWaiterAndProgress() async throws {
        try await checkSharedCancellation(cancelFirst: true)
    }

    func testCancellingSecondCallerPreservesFirstWaiterAndProgress() async throws {
        try await checkSharedCancellation(cancelFirst: false)
    }

    private func checkSharedCancellation(cancelFirst: Bool) async throws {
        let gate = OrukeetInstallationTestGate()
        let started = expectation(description: "one shared installation")
        started.assertForOverFulfill = true
        let firstJoined = expectation(description: "first subscriber")
        let secondJoined = expectation(description: "second subscriber")
        let survivorProgress = expectation(description: "remaining subscriber receives progress")
        let cancelledReturned = expectation(description: "cancelled subscriber returns promptly")
        let installation = OrukeetInstallation { progress in
            started.fulfill()
            await gate.wait()
            try Task.checkCancellation()
            progress(0.5)
            // Let the relayed progress reach the remaining waiter before completing.
            await gate.waitForProgress()
        }
        let first = Task {
            do {
                try await installation.install { value in
                    if value == 0 { firstJoined.fulfill() }
                    if value == 0.5 && !cancelFirst {
                        survivorProgress.fulfill()
                        Task { await gate.progressReceived() }
                    }
                }
            } catch {
                if cancelFirst { cancelledReturned.fulfill() }
                throw error
            }
        }
        await fulfillment(of: [firstJoined, started], timeout: 2)
        let second = Task {
            do {
                try await installation.install { value in
                    if value == 0 { secondJoined.fulfill() }
                    if value == 0.5 && cancelFirst {
                        survivorProgress.fulfill()
                        Task { await gate.progressReceived() }
                    }
                }
            } catch {
                if !cancelFirst { cancelledReturned.fulfill() }
                throw error
            }
        }
        await fulfillment(of: [secondJoined], timeout: 2)
        let cancelled = cancelFirst ? first : second
        let survivor = cancelFirst ? second : first
        cancelled.cancel()
        await fulfillment(of: [cancelledReturned], timeout: 2)
        await gate.open()
        await fulfillment(of: [survivorProgress], timeout: 2)
        // Also unblock a failing implementation so the test does not leave a task suspended.
        await gate.progressReceived()
        try await survivor.value
        do {
            try await cancelled.value
            XCTFail("Cancelled caller must not report success")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLastCancellationStopsInstallAndRetryWaitsForCleanup() async throws {
        let gate = OrukeetInstallationTestGate()
        let probe = OrukeetInstallationTestProbe()
        let started = expectation(description: "first installation started")
        let cancelledReturned = expectation(description: "lone caller returns promptly")
        let retryStarted = expectation(description: "retry starts after cleanup")
        let installation = OrukeetInstallation { _ in
            let attempt = await probe.start()
            if attempt == 1 {
                started.fulfill()
                await gate.wait()
                await probe.end()
                try Task.checkCancellation()
                XCTFail("Last caller cancellation must cancel underlying work")
            } else {
                retryStarted.fulfill()
                await probe.end()
            }
        }
        let first = Task {
            do { try await installation.install { _ in } } catch {
                cancelledReturned.fulfill()
                throw error
            }
        }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        await fulfillment(of: [cancelledReturned], timeout: 2)
        let retry = Task { try await installation.install { _ in } }
        await gate.open()
        await fulfillment(of: [retryStarted], timeout: 2)
        try await retry.value
        do {
            try await first.value
            XCTFail("Cancelled caller must not report success")
        } catch { XCTAssertTrue(error is CancellationError) }
        let counts = await probe.counts()
        XCTAssertEqual(counts.attempts, 2)
        XCTAssertEqual(counts.maximumActive, 1)
    }

    func testOrukeetHasItsOwnSelectionAndLanguages() throws {
        let model = try XCTUnwrap(SettingsFluidAudioModels.availableModels.first { $0.version == "orukeet" })
        XCTAssertEqual(model.name, "Orukeet (preview)")
        XCTAssertFalse(model.isDownloaded)
        let languages = LanguageUtil.supportedLanguages(engine: "fluidaudio", fluidAudioModelVersion: model.version)
        XCTAssertEqual(Set(languages).count, 25)
        XCTAssertTrue(languages.contains("mt"))
        XCTAssertTrue(languages.contains("el"))
        XCTAssertFalse(languages.contains("zh"))
    }

    // Opt in with the immutable archive downloaded from the model card. Default CI uses no weights.
    func testPinnedArchiveInstallsAndLoadsOffline() throws {
        guard let path = ProcessInfo.processInfo.environment["ORUKEET_COREML_ARCHIVE"] else {
            throw XCTSkip("Set ORUKEET_COREML_ARCHIVE to run the real Core ML installation test")
        }
        let destination = try temporaryDirectory().appendingPathComponent("installed")
        try OrukeetModelStore.installArchive(at: URL(fileURLWithPath: path), to: destination)
        XCTAssertTrue(OrukeetModelStore.installed(at: destination))
        XCTAssertNoThrow(try OrukeetModelStore.load(from: destination))
        try FileManager.default.removeItem(at: destination.appendingPathComponent("Encoder.mlmodelc"))
        XCTAssertFalse(OrukeetModelStore.installed(at: destination))
        XCTAssertThrowsError(try OrukeetModelStore.load(from: destination))
    }
    @MainActor
    func testRealEngineRepeatedTranscriptionAndCachedReload() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORUKEET_AUDIO_DIR"] else {
            throw XCTSkip("Set ORUKEET_AUDIO_DIR to opt into a real Hugging Face install and audio smoke test")
        }
        let directory = URL(fileURLWithPath: path)
        var previous: [String: String] = [:]
        for round in 0..<2 {
            let engine = FluidAudioEngine(modelVersion: "orukeet")
            try await engine.initialize()
            XCTAssertTrue(engine.isModelLoaded)
            XCTAssertEqual(Set(engine.getSupportedLanguages()).count, 25)
            for name in ["en", "de", "fr", "silence"] {
                let start = Date()
                let text = try await engine.transcribeAudio(url: directory.appendingPathComponent(name + ".wav"), settings: Settings())
                if name == "silence" { XCTAssertTrue(text.isEmpty) } else { XCTAssertFalse(text.isEmpty) }
                if let expected = previous[name] { XCTAssertEqual(text, expected) }
                previous[name] = text
                print("ORUKEET_SMOKE round=\(round) clip=\(name) seconds=\(Date().timeIntervalSince(start)) text=\(text)")
            }
        }
    }

}

private actor OrukeetInstallationTestGate {
    private var isOpen = false
    private var receivedProgress = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var progressContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if !isOpen { await withCheckedContinuation { continuation = $0 } }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
    func waitForProgress() async {
        if !receivedProgress { await withCheckedContinuation { progressContinuation = $0 } }
    }
    func progressReceived() {
        receivedProgress = true
        progressContinuation?.resume()
        progressContinuation = nil
    }
}

private actor OrukeetInstallationTestProbe {
    private var attempts = 0
    private var active = 0
    private var maximumActive = 0
    func start() -> Int {
        attempts += 1
        active += 1
        maximumActive = max(maximumActive, active)
        return attempts
    }
    func end() { active -= 1 }
    func counts() -> (attempts: Int, maximumActive: Int) { (attempts, maximumActive) }
}
