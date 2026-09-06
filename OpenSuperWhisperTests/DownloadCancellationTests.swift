import XCTest
@testable import OpenSuperWhisper

private actor DownloadGate {
    var waits: [String: CheckedContinuation<Void, Error>] = [:]
    var progress: [String: (Double) -> Void] = [:]
    func download(_ name: String, progress: @escaping (Double) -> Void) async throws {
        self.progress[name] = progress
        try await withCheckedThrowingContinuation { waits[name] = $0 }
    }
    func hasRequest(_ name: String) -> Bool { waits[name] != nil }
    func update(_ name: String, progress: Double) { self.progress[name]?(progress) }
    func fail(_ name: String) { waits.removeValue(forKey: name)?.resume(throwing: CancellationError()) }
}

@MainActor
final class DownloadCancellationTests: XCTestCase {
    func testFluidDownloadFailureReachesSettingsAndOnboarding() async throws {
        let prefs = AppPreferences.shared
        let language = prefs.whisperLanguage
        let engine = prefs.selectedEngine
        let version = prefs.fluidAudioModelVersion
        let modelPath = prefs.selectedWhisperModelPath
        let modifier = prefs.modifierOnlyHotkey
        let lastModifier = prefs.lastModifierOnlyHotkey
        defer {
            prefs.whisperLanguage = language
            prefs.selectedEngine = engine
            prefs.fluidAudioModelVersion = version
            prefs.selectedWhisperModelPath = modelPath
            prefs.modifierOnlyHotkey = modifier
            prefs.lastModifierOnlyHotkey = lastModifier
        }
        let settings = SettingsViewModel(downloadFluid: { _, _ in throw TranscriptionError.processingFailed })
        let settingsModel = try XCTUnwrap(settings.downloadableFluidAudioModels.first)
        do {
            try await settings.downloadFluidAudioModel(settingsModel)
            XCTFail("Settings swallowed the download error")
        } catch { XCTAssertTrue(error is TranscriptionError) }
        XCTAssertFalse(settings.isDownloading)
        let onboarding = OnboardingViewModel(downloadFluid: { _, _ in throw TranscriptionError.processingFailed })
        let onboardingModel = try XCTUnwrap(onboarding.unifiedModels.first {
            if case .parakeet = $0.type { return true }
            return false
        })
        do {
            try await onboarding.downloadModel(onboardingModel)
            XCTFail("Onboarding swallowed the download error")
        } catch { XCTAssertTrue(error is TranscriptionError) }
        XCTAssertFalse(onboarding.isDownloading)
    }

    func testLateCancelledDownloadCannotResetReplacement() async throws {
        let language = AppPreferences.shared.whisperLanguage
        defer { AppPreferences.shared.whisperLanguage = language }
        let gate = DownloadGate()
        let vm = SettingsViewModel(downloadWhisper: { _, name, progress in
            try await gate.download(name, progress: progress)
        })
        let a = SettingsDownloadableModel(name: "A", isDownloaded: false,
            url: URL(string: "https://example.invalid/a.bin")!, size: 1, description: "test")
        let b = SettingsDownloadableModel(name: "B", isDownloaded: false,
            url: URL(string: "https://example.invalid/b.bin")!, size: 1, description: "test")
        func waitFor(_ name: String) async throws {
            for _ in 0..<100 {
                if await gate.hasRequest(name) { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Download not started")
        }
        let first = Task { try await vm.downloadModel(a) }
        try await waitFor("a.bin")
        vm.cancelDownload()
        let second = Task { try await vm.downloadModel(b) }
        try await waitFor("b.bin")
        await gate.update("b.bin", progress: 0.4)
        try await Task.sleep(nanoseconds: 10_000_000)
        await gate.update("a.bin", progress: 1)
        await gate.fail("a.bin")
        try await first.value
        XCTAssertTrue(vm.isDownloading)
        XCTAssertEqual(vm.downloadingModelName, "B")
        XCTAssertEqual(vm.downloadProgress, 0.4)
        vm.cancelDownload()
        await gate.fail("b.bin")
        try await second.value
        XCTAssertFalse(vm.isDownloading)
    }
}
