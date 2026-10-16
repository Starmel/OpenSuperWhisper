import FluidAudio
import Foundation
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class PhononBenchmarkTests: XCTestCase {
    func testM5LocalEngineComparisonAndPhononAppPath() async throws {
        let enabled = ProcessInfo.processInfo.environment["RUN_PHONON_BENCHMARKS"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/run-osw-phonon-benchmark")
        try XCTSkipUnless(enabled)

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shortURL = URL(fileURLWithPath: "/tmp/osw-phonon-short.wav")
        let longURL = repository.appendingPathComponent("OpenSuperWhisperTests/Fixtures/long_en.m4a")
        let whisperPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ru.starmel.OpenSuperWhisper/whisper-models/ggml-large-v3-turbo.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: longURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: whisperPath.path))

        let modelManager = PhononModelManager.shared
        let downloadStarted = Date()
        if !modelManager.isModelInstalled {
            try await modelManager.downloadModel { progress in
                if Int(progress * 100).isMultiple(of: 10) {
                    print("PHONON_DOWNLOAD_PROGRESS \(Int(progress * 100))")
                }
            }
        }
        let downloadSeconds = Date().timeIntervalSince(downloadStarted)

        let convertedShortSamples = try await WhisperEngine(modelPath: whisperPath.path)
            .convertAudioToPCM(fileURL: shortURL)
        let shortSamples = try XCTUnwrap(convertedShortSamples)

        let prefs = AppPreferences.shared
        let oldEngine = prefs.selectedEngine
        let oldPath = prefs.selectedWhisperModelPath
        let oldLanguage = prefs.whisperLanguage
        let oldTimestamps = prefs.showTimestamps
        defer {
            prefs.selectedEngine = oldEngine
            prefs.selectedWhisperModelPath = oldPath
            prefs.whisperLanguage = oldLanguage
            prefs.showTimestamps = oldTimestamps
        }
        prefs.selectedEngine = "phonon"
        prefs.selectedWhisperModelPath = whisperPath.path
        prefs.whisperLanguage = "en"
        prefs.showTimestamps = false
        let settings = Settings()

        var report: [String: Any] = [
            "machine": "Apple M5, 16 GB",
            "short_clip_seconds": Double(shortSamples.count) / 16_000,
            "long_clip_seconds": 97.106,
            "phonon_download_seconds_this_run": downloadSeconds,
            "phonon_pinned_download_bytes": modelManager.release.downloadSize,
        ]

        // This is the real application selection and routing path. PCM is passed
        // through TranscriptionService, then the embedded XPC service, without a
        // temporary file. Long audio deliberately exercises the durable URL path.
        let phononLoadStart = Date()
        let appService = TranscriptionService(selection: .current)
        try await appService.waitUntilReady()
        let phononLoadWall = Date().timeIntervalSince(phononLoadStart)
        guard appService.activeEngineName == "Phonon-2" else {
            let warning = appService.loadingWarning ?? appService.loadingError ?? "No diagnostic"
            XCTFail("Phonon app path fell back: \(warning)")
            await appService.shutdown()
            return
        }

        let phononFirstShortStart = Date()
        _ = try await appService.transcribeAudio(url: shortURL, settings: settings, pcmSamples: shortSamples)
        let phononFirstShortSeconds = Date().timeIntervalSince(phononFirstShortStart)
        let phononWarmStart = Date()
        let phononShortText = try await appService.transcribeAudio(url: shortURL, settings: settings, pcmSamples: shortSamples)
        let phononWarmSeconds = Date().timeIntervalSince(phononWarmStart)
        let phononShortResult = try XCTUnwrap(appService.activePhononResult)

        let phononLongStart = Date()
        let phononLongText = try await appService.transcribeAudio(url: longURL, settings: settings)
        let phononLongSeconds = Date().timeIntervalSince(phononLongStart)
        let phononLongResult = try XCTUnwrap(appService.activePhononResult)
        let phononPreparation = try XCTUnwrap(appService.activePhononPreparation)

        report["phonon"] = [
            "cold_prepare_wall_seconds": phononLoadWall,
            "runtime_load_seconds": phononPreparation.loadSeconds,
            "runtime_compile_seconds": phononPreparation.compileSeconds,
            "first_short_wall_seconds": phononFirstShortSeconds,
            "warm_short_wall_seconds": phononWarmSeconds,
            "warm_short_decode_seconds": phononShortResult.decodeSeconds,
            "long_wall_seconds": phononLongSeconds,
            "long_decode_seconds": phononLongResult.decodeSeconds,
            "peak_resident_bytes": phononLongResult.peakResidentMemoryBytes ?? 0,
            "short_transcript": phononShortText,
            "long_transcript": phononLongText,
            "long_word_timings": phononLongResult.words.map { ["word": $0.text, "start": $0.start, "end": $0.end] },
        ]
        report["phonon_on_disk_bytes_including_compiled_cache"] = modelManager.storageBytes()
        await appService.shutdown()

        let parakeet = FluidAudioEngine(modelVersion: "v3")
        let parakeetLoadStart = Date()
        try await parakeet.initialize()
        let parakeetLoadSeconds = Date().timeIntervalSince(parakeetLoadStart)
        _ = try await parakeet.transcribeAudio(url: shortURL, settings: settings)
        let parakeetWarmStart = Date()
        let parakeetShortText = try await parakeet.transcribeAudio(url: shortURL, settings: settings)
        let parakeetWarmSeconds = Date().timeIntervalSince(parakeetWarmStart)
        let parakeetLongStart = Date()
        let parakeetLongText = try await parakeet.transcribeAudio(url: longURL, settings: settings)
        let parakeetLongSeconds = Date().timeIntervalSince(parakeetLongStart)
        let parakeetWords = buildWordTimings(from: parakeet.lastResult?.tokenTimings ?? [])
        report["parakeet_v3"] = [
            "cold_load_seconds": parakeetLoadSeconds,
            "warm_short_wall_seconds": parakeetWarmSeconds,
            "long_wall_seconds": parakeetLongSeconds,
            "peak_resident_bytes": Self.peakResidentMemoryBytes() ?? 0,
            "short_transcript": parakeetShortText,
            "long_transcript": parakeetLongText,
            "long_word_timings": parakeetWords.map { ["word": $0.word, "start": $0.startTime, "end": $0.endTime] },
        ]

        let whisper = WhisperEngine(modelPath: whisperPath.path)
        let whisperLoadStart = Date()
        try await whisper.initialize()
        let whisperLoadSeconds = Date().timeIntervalSince(whisperLoadStart)
        _ = try await whisper.transcribeSamples(shortSamples, settings: settings)
        let whisperWarmStart = Date()
        let whisperShortText = try await whisper.transcribeSamples(shortSamples, settings: settings)
        let whisperWarmSeconds = Date().timeIntervalSince(whisperWarmStart)
        let whisperLongStart = Date()
        let whisperLong = try await whisper.transcribeAudioDetailed(url: longURL, settings: settings)
        let whisperLongSeconds = Date().timeIntervalSince(whisperLongStart)
        report["whisper_large_v3_turbo"] = [
            "cold_load_seconds": whisperLoadSeconds,
            "warm_short_wall_seconds": whisperWarmSeconds,
            "long_wall_seconds": whisperLongSeconds,
            "peak_resident_bytes": Self.peakResidentMemoryBytes() ?? 0,
            "short_transcript": whisperShortText,
            "long_transcript": whisperLong.text,
            "long_segment_end_times_seconds": whisperLong.segments.map { Double($0.endTimeCentiseconds) / 100 },
        ]
        whisper.unload()

        let output = URL(fileURLWithPath: "/tmp/osw-phonon-benchmark.json")
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)
        print("PHONON_BENCHMARK_REPORT \(output.path)")
    }

    private static func peakResidentMemoryBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.ledger_phys_footprint_peak > 0
            ? UInt64(info.ledger_phys_footprint_peak)
            : UInt64(info.phys_footprint)
    }
}
