import AVFoundation
import FluidAudio
import Foundation
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class PhononBenchmarkTests: XCTestCase {
    private enum Engine: String, CaseIterable {
        case phonon
        case parakeet
        case whisper

        var testMethod: String {
            switch self {
            case .phonon: "testM5PhononFreshProcessWorker"
            case .parakeet: "testM5ParakeetFreshProcessWorker"
            case .whisper: "testM5WhisperFreshProcessWorker"
            }
        }
    }

    private static let optInMarker = "/tmp/run-osw-phonon-benchmark"
    private static let workerMarker = "/tmp/run-osw-phonon-benchmark-workers"
    private static let partsDirectory = URL(fileURLWithPath: "/tmp/osw-phonon-benchmark-parts", isDirectory: true)

    func testM5LocalEngineComparisonAndPhononAppPath() async throws {
        try XCTSkipUnless(Self.benchmarksEnabled)

        let fileManager = FileManager.default
        let repository = Self.repositoryURL
        let shortURL = URL(fileURLWithPath: "/tmp/osw-phonon-short.wav")
        let longURL = repository.appendingPathComponent("OpenSuperWhisperTests/Fixtures/long_en.m4a")
        let whisperPath = Self.whisperModelURL
        XCTAssertTrue(fileManager.fileExists(atPath: shortURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: longURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: whisperPath.path))

        let shortSamples = try Self.loadMonoPCM(url: shortURL)
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

        try? fileManager.removeItem(at: Self.partsDirectory)
        try fileManager.createDirectory(at: Self.partsDirectory, withIntermediateDirectories: true)
        fileManager.createFile(atPath: Self.workerMarker, contents: Data())
        defer {
            try? fileManager.removeItem(atPath: Self.workerMarker)
            try? fileManager.removeItem(at: Self.partsDirectory)
        }

        for engine in Engine.allCases {
            try Self.runFreshProcessWorker(engine)
        }

        var report: [String: Any] = [
            "machine": "Apple M5, 16 GB",
            "short_clip_seconds": Double(shortSamples.count) / 16_000,
            "long_clip_seconds": 97.106,
            "phonon_download_seconds_this_run": downloadSeconds,
            "phonon_pinned_download_bytes": modelManager.release.downloadSize,
            "phonon_on_disk_bytes_including_compiled_cache": modelManager.storageBytes(),
        ]
        var workerPIDs: [Int] = []
        for engine in Engine.allCases {
            let fragment = try Self.readFragment(for: engine)
            report.merge(fragment) { _, fresh in fresh }
            let sectionName: String
            switch engine {
            case .phonon: sectionName = "phonon"
            case .parakeet: sectionName = "parakeet_v3"
            case .whisper: sectionName = "whisper_large_v3_turbo"
            }
            let section = try XCTUnwrap(fragment[sectionName] as? [String: Any])
            workerPIDs.append(try XCTUnwrap(section["benchmark_worker_pid"] as? Int))
        }
        XCTAssertEqual(Set(workerPIDs).count, Engine.allCases.count)

        let output = URL(fileURLWithPath: "/tmp/osw-phonon-benchmark.json")
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)
        print("PHONON_BENCHMARK_REPORT \(output.path)")
    }

    func testM5PhononFreshProcessWorker() async throws {
        try XCTSkipUnless(Self.workersEnabled)
        try await runPhononWorker()
    }

    func testM5ParakeetFreshProcessWorker() async throws {
        try XCTSkipUnless(Self.workersEnabled)
        try await runParakeetWorker()
    }

    func testM5WhisperFreshProcessWorker() async throws {
        try XCTSkipUnless(Self.workersEnabled)
        try await runWhisperWorker()
    }

    private func runPhononWorker() async throws {
        let shortURL = URL(fileURLWithPath: "/tmp/osw-phonon-short.wav")
        let longURL = Self.repositoryURL.appendingPathComponent("OpenSuperWhisperTests/Fixtures/long_en.m4a")
        let shortSamples = try Self.loadMonoPCM(url: shortURL)
        let whisperPath = Self.whisperModelURL
        let settings = Settings()
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

        let loadStart = Date()
        let appService = TranscriptionService(selection: .current)
        try await appService.waitUntilReady()
        let loadWall = Date().timeIntervalSince(loadStart)
        guard appService.activeEngineName == "Phonon-2" else {
            let warning = appService.loadingWarning ?? appService.loadingError ?? "No diagnostic"
            XCTFail("Phonon app path fell back: \(warning)")
            await appService.shutdown()
            return
        }

        let firstShortStart = Date()
        _ = try await appService.transcribeAudio(url: shortURL, settings: settings, pcmSamples: shortSamples)
        let firstShortSeconds = Date().timeIntervalSince(firstShortStart)
        let warmStart = Date()
        let shortText = try await appService.transcribeAudio(url: shortURL, settings: settings, pcmSamples: shortSamples)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        let shortResult = try XCTUnwrap(appService.activePhononResult)

        let longStart = Date()
        let longText = try await appService.transcribeAudio(url: longURL, settings: settings)
        let longSeconds = Date().timeIntervalSince(longStart)
        let longResult = try XCTUnwrap(appService.activePhononResult)
        let preparation = try XCTUnwrap(appService.activePhononPreparation)

        let section: [String: Any] = [
            "benchmark_worker_pid": Int(ProcessInfo.processInfo.processIdentifier),
            "peak_memory_process": "PhononService XPC helper",
            "cold_prepare_wall_seconds": loadWall,
            "runtime_load_seconds": preparation.loadSeconds,
            "runtime_compile_seconds": preparation.compileSeconds,
            "first_short_wall_seconds": firstShortSeconds,
            "warm_short_wall_seconds": warmSeconds,
            "warm_short_decode_seconds": shortResult.decodeSeconds,
            "long_wall_seconds": longSeconds,
            "long_decode_seconds": longResult.decodeSeconds,
            "peak_resident_bytes": longResult.peakResidentMemoryBytes ?? 0,
            "short_transcript": shortText,
            "long_transcript": longText,
            "long_word_timings": longResult.words.map { ["word": $0.text, "start": $0.start, "end": $0.end] },
        ]
        await appService.shutdown()
        try Self.writeFragment(["phonon": section], for: .phonon)
    }

    private func runParakeetWorker() async throws {
        let shortURL = URL(fileURLWithPath: "/tmp/osw-phonon-short.wav")
        let longURL = Self.repositoryURL.appendingPathComponent("OpenSuperWhisperTests/Fixtures/long_en.m4a")
        let settings = Settings()
        let parakeet = FluidAudioEngine(modelVersion: "v3")
        let loadStart = Date()
        try await parakeet.initialize()
        let loadSeconds = Date().timeIntervalSince(loadStart)
        _ = try await parakeet.transcribeAudio(url: shortURL, settings: settings)
        let warmStart = Date()
        let shortText = try await parakeet.transcribeAudio(url: shortURL, settings: settings)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        let longStart = Date()
        let longText = try await parakeet.transcribeAudio(url: longURL, settings: settings)
        let longSeconds = Date().timeIntervalSince(longStart)
        let words = buildWordTimings(from: parakeet.lastResult?.tokenTimings ?? [])
        let section: [String: Any] = [
            "benchmark_worker_pid": Int(ProcessInfo.processInfo.processIdentifier),
            "peak_memory_process": "fresh XCTest app host",
            "cold_load_seconds": loadSeconds,
            "warm_short_wall_seconds": warmSeconds,
            "long_wall_seconds": longSeconds,
            "peak_resident_bytes": Self.peakResidentMemoryBytes() ?? 0,
            "short_transcript": shortText,
            "long_transcript": longText,
            "long_word_timings": words.map { ["word": $0.word, "start": $0.startTime, "end": $0.endTime] },
        ]
        try Self.writeFragment(["parakeet_v3": section], for: .parakeet)
    }

    private func runWhisperWorker() async throws {
        let shortURL = URL(fileURLWithPath: "/tmp/osw-phonon-short.wav")
        let longURL = Self.repositoryURL.appendingPathComponent("OpenSuperWhisperTests/Fixtures/long_en.m4a")
        let settings = Settings()
        let shortSamples = try Self.loadMonoPCM(url: shortURL)
        let whisper = WhisperEngine(modelPath: Self.whisperModelURL.path)
        let loadStart = Date()
        try await whisper.initialize()
        let loadSeconds = Date().timeIntervalSince(loadStart)
        _ = try await whisper.transcribeSamples(shortSamples, settings: settings)
        let warmStart = Date()
        let shortText = try await whisper.transcribeSamples(shortSamples, settings: settings)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        let longStart = Date()
        let long = try await whisper.transcribeAudioDetailed(url: longURL, settings: settings)
        let longSeconds = Date().timeIntervalSince(longStart)
        let section: [String: Any] = [
            "benchmark_worker_pid": Int(ProcessInfo.processInfo.processIdentifier),
            "peak_memory_process": "fresh XCTest app host",
            "cold_load_seconds": loadSeconds,
            "warm_short_wall_seconds": warmSeconds,
            "long_wall_seconds": longSeconds,
            "peak_resident_bytes": Self.peakResidentMemoryBytes() ?? 0,
            "short_transcript": shortText,
            "long_transcript": long.text,
            "long_segment_end_times_seconds": long.segments.map { Double($0.endTimeCentiseconds) / 100 },
        ]
        whisper.unload()
        try Self.writeFragment(["whisper_large_v3_turbo": section], for: .whisper)
    }

    private static var benchmarksEnabled: Bool {
        ProcessInfo.processInfo.environment["RUN_PHONON_BENCHMARKS"] == "1"
            || FileManager.default.fileExists(atPath: optInMarker)
    }

    private static var workersEnabled: Bool {
        FileManager.default.fileExists(atPath: workerMarker)
    }

    private static var repositoryURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var whisperModelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ru.starmel.OpenSuperWhisper/whisper-models/ggml-large-v3-turbo.bin")
    }

    private static func runFreshProcessWorker(_ engine: Engine) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.currentDirectoryURL = repositoryURL
        process.arguments = [
            "xcodebuild", "test-without-building",
            "-project", repositoryURL.appendingPathComponent("OpenSuperWhisper.xcodeproj").path,
            "-scheme", "OpenSuperWhisper",
            "-configuration", "Debug",
            "-derivedDataPath", derivedDataURL.path,
            "-destination", "platform=macOS,arch=arm64",
            "-only-testing:OpenSuperWhisperTests/PhononBenchmarkTests/\(engine.testMethod)",
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "DEVELOPMENT_TEAM=",
        ]

        let logURL = partsDirectory.appendingPathComponent("\(engine.rawValue).log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        try process.run()
        process.waitUntilExit()
        try log.close()

        guard process.terminationStatus == 0 else {
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "No xcodebuild output"
            throw NSError(
                domain: "PhononBenchmarkTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Fresh \(engine.rawValue) worker failed:\n\(output.suffix(8_000))"]
            )
        }
    }

    private static var derivedDataURL: URL {
        var candidate = Bundle(for: PhononBenchmarkTests.self).bundleURL
        while candidate.lastPathComponent != "Build" && candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        precondition(candidate.lastPathComponent == "Build", "Unable to locate DerivedData from test bundle")
        return candidate.deletingLastPathComponent()
    }

    private static func writeFragment(_ fragment: [String: Any], for engine: Engine) throws {
        let data = try JSONSerialization.data(withJSONObject: fragment, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: partsDirectory.appendingPathComponent("\(engine.rawValue).json"), options: .atomic)
    }

    private static func readFragment(for engine: Engine) throws -> [String: Any] {
        let data = try Data(contentsOf: partsDirectory.appendingPathComponent("\(engine.rawValue).json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func loadMonoPCM(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.sampleRate, 16_000, accuracy: 0.1)
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
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
