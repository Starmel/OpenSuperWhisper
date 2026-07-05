//
//  OpenSuperWhisperTests.swift
//  OpenSuperWhisperTests
//
//  Created by user on 05.02.2025.
//

import XCTest
import Carbon
import ApplicationServices
import AVFoundation
@testable import OpenSuperWhisper

final class OpenSuperWhisperTests: XCTestCase {

    override func setUpWithError() throws {
    }

    override func tearDownWithError() throws {
    }

    func testPerformanceExample() throws {
        self.measure {
        }
    }
}

final class WhisperEngineMultiChannelTests: XCTestCase {
    func testMakeTargetFormat_withSixChannels_returnsFormat() {
        let engine = WhisperEngine()
        let format = engine.makeTargetFormat(channelCount: 6)
        
        XCTAssertNotNil(format)
        XCTAssertEqual(format?.channelCount, 6)
        XCTAssertEqual(format?.sampleRate, 16000)
    }
    
    func testMakeTargetFormat_withZeroChannels_returnsNil() {
        let engine = WhisperEngine()
        XCTAssertNil(engine.makeTargetFormat(channelCount: 0))
    }
}

final class WhisperEngineConversionTests: XCTestCase {

    private var tempFiles: [URL] = []

    override func tearDownWithError() throws {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles.removeAll()
    }

    private func makeSineWAV(duration: Double, sampleRate: Double, frequency: Double = 440, settings: [String: Any]? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-conversion-test-\(UUID().uuidString).wav")
        tempFiles.append(url)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        let file = try AVAudioFile(
            forWriting: url, settings: settings ?? format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "test", code: 2)
        }
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            samples[i] = 0.5 * sinf(Float(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    private func longestNearZeroRun(in samples: [Float], threshold: Float = 1e-4) -> Int {
        var longest = 0
        var current = 0
        for sample in samples {
            if abs(sample) < threshold {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    // Bug: converter tail is never flushed (.endOfStream), so trailing samples are dropped.
    func testSequentialConversionPreservesFullDuration() async throws {
        let url = try makeSineWAV(duration: 3.0, sampleRate: 44100)
        let engine = WhisperEngine()

        let samples = try await engine.convertAudioToPCM(fileURL: url)
        let result = try XCTUnwrap(samples)

        // 3 s * 44100 * (16000/44100) = exactly 48000 output samples.
        // Without flushing the converter (.endOfStream) the resampler tail is lost.
        let expected = Int(3.0 * 16000)
        print("[DIAG] sequential count=\(result.count) expected=\(expected) diff=\(result.count - expected)")
        XCTAssertLessThanOrEqual(
            abs(result.count - expected), 2,
            "Sequential conversion dropped samples: got \(result.count), expected \(expected)"
        )

        let tail = result.suffix(320)
        let tailRMS = sqrt(tail.reduce(Float(0)) { $0 + $1 * $1 } / Float(tail.count))
        print("[DIAG] sequential tailRMS=\(tailRMS)")
        XCTAssertGreaterThan(tailRMS, 0.1, "Tail of converted audio is silent — end of recording was lost")
    }

    // Bug: parallel segment stitching leaves zero-filled gaps / misaligned boundaries.
    func testParallelConversionProducesContinuousAudio() async throws {
        // > 10 seconds triggers the parallel conversion path
        let url = try makeSineWAV(duration: 15.0, sampleRate: 48000)
        let engine = WhisperEngine()

        let samples = try await engine.convertAudioToPCM(fileURL: url)
        let result = try XCTUnwrap(samples)

        let expected = Int(15.0 * 16000)
        print("[DIAG] parallel count=\(result.count) expected=\(expected) diff=\(result.count - expected)")
        XCTAssertLessThanOrEqual(
            abs(result.count - expected), 2,
            "Parallel conversion produced wrong duration: got \(result.count), expected \(expected)"
        )

        // At 16 kHz a 440 Hz sine crosses zero every ~18 samples and stays below the
        // threshold for at most 1 sample per crossing. Any longer run of near-zero
        // samples is a gap at a worker segment boundary.
        let interior = Array(result.dropFirst(1600).dropLast(1600))
        let gap = longestNearZeroRun(in: interior)
        print("[DIAG] parallel longest near-zero run=\(gap)")
        XCTAssertLessThan(gap, 3, "Found a silent gap of \(gap) samples inside continuous audio — segment stitching is broken")
    }

    func testParallelConversionMatchesSequentialResult() async throws {
        let url = try makeSineWAV(duration: 15.0, sampleRate: 44100)
        let engine = WhisperEngine()

        let samples = try await engine.convertAudioToPCM(fileURL: url)
        let parallel = try XCTUnwrap(samples)

        let expected = Int(15.0 * 16000)
        print("[DIAG] parallel441 count=\(parallel.count) expected=\(expected) diff=\(parallel.count - expected)")
        XCTAssertLessThanOrEqual(
            abs(parallel.count - expected), 2,
            "Parallel conversion length mismatch: got \(parallel.count), expected \(expected)"
        )

        // Overall energy must match a clean 0.5-amplitude sine (RMS ~0.35).
        // Gaps or overlapping segments change the energy noticeably.
        let rms = sqrt(parallel.reduce(Float(0)) { $0 + $1 * $1 } / Float(parallel.count))
        print("[DIAG] parallel441 rms=\(rms)")
        XCTAssertEqual(rms, 0.3535, accuracy: 0.01, "RMS of converted audio deviates from source sine")
    }

    // The recorder now writes 16-bit integer PCM at 16 kHz — the exact format
    // produced on the hotkey critical path must convert losslessly.
    func testRecorderFormatInt16Wav16kConverts() async throws {
        let recorderSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        let url = try makeSineWAV(duration: 3.0, sampleRate: 16000, settings: recorderSettings)
        let engine = WhisperEngine()

        let samples = try await engine.convertAudioToPCM(fileURL: url)
        let result = try XCTUnwrap(samples)

        let expected = Int(3.0 * 16000)
        XCTAssertLessThanOrEqual(
            abs(result.count - expected), 2,
            "Int16 recorder format conversion length mismatch: got \(result.count), expected \(expected)"
        )

        let rms = sqrt(result.reduce(Float(0)) { $0 + $1 * $1 } / Float(result.count))
        XCTAssertEqual(rms, 0.3535, accuracy: 0.01, "RMS deviates — Int16 recording is not decoded correctly")
    }
}

final class WhisperStateIsolationTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    // Each transcription runs whisper_full_with_state on a fresh whisper_state,
    // so noContext = false keeps context between 30s windows of one recording
    // but a silent/hallucinated recording can never poison the next one.
    func testFreshStatePerCallKeepsRecordingsIsolated() async throws {
        let modelURL = Self.repoRoot.appendingPathComponent("ggml-tiny.en.bin")
        let audioURL = Self.repoRoot.appendingPathComponent("jfk.wav")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelURL.path)
                && FileManager.default.fileExists(atPath: audioURL.path),
            "tiny model / jfk sample not present in repo root"
        )

        let context = try XCTUnwrap(
            MyWhisperContext.initFromFileNoState(path: modelURL.path, params: WhisperContextParams())
        )
        let engine = WhisperEngine()
        let converted = try await engine.convertAudioToPCM(fileURL: audioURL)
        let speech = try XCTUnwrap(converted)
        let silence = [Float](repeating: 0, count: 16000 * 2)

        func transcribe(_ pcm: [Float]) throws -> String {
            var params = WhisperFullParams()
            params.noContext = false
            params.greedyBestOf = 5
            params.language = "en"
            var cParams = params.toC()

            XCTAssertTrue(context.initState(), "Fresh whisper_state must be created per call")
            defer { context.freeState() }

            guard context.full(samples: pcm, params: &cParams) else {
                XCTFail("whisper_full_with_state failed")
                return ""
            }

            var text = ""
            for i in 0..<context.fullNSegments {
                text += context.fullGetSegmentText(iSegment: i) ?? ""
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let first = try transcribe(speech)
        _ = try transcribe(silence)
        let second = try transcribe(speech)

        XCTAssertTrue(first.lowercased().contains("your country"), "Unexpected transcription: \(first)")
        XCTAssertEqual(
            first, second,
            "Transcription changed after a silent recording — decoding state leaks between calls"
        )
    }

    // The bundled Silero VAD is always on in production: silence must yield no
    // speech segments (no hallucinations), while trimmed speech still
    // transcribes correctly.
    func testBundledVadDropsSilenceAndKeepsSpeech() async throws {
        let modelURL = Self.repoRoot.appendingPathComponent("ggml-tiny.en.bin")
        let audioURL = Self.repoRoot.appendingPathComponent("jfk.wav")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelURL.path)
                && FileManager.default.fileExists(atPath: audioURL.path),
            "tiny model / jfk sample not present in repo root"
        )

        let vadModelPath = try XCTUnwrap(
            WhisperEngine.vadModelPath,
            "Silero VAD model must be bundled with the app"
        )
        let vad = try XCTUnwrap(MyWhisperVadContext(modelPath: vadModelPath))

        // Pure silence: no speech segments at all.
        let silence = [Float](repeating: 0, count: 16000 * 3)
        let silenceSegments = try XCTUnwrap(vad.speechSegments(in: silence))
        XCTAssertTrue(silenceSegments.isEmpty, "VAD must not detect speech in pure silence")

        // Speech padded with 5s of silence on both sides: VAD trims the
        // padding and the trimmed audio still transcribes correctly.
        let engine = WhisperEngine()
        let converted = try await engine.convertAudioToPCM(fileURL: audioURL)
        let speech = try XCTUnwrap(converted)
        let padding = [Float](repeating: 0, count: 16000 * 5)
        let padded = padding + speech + padding

        let segments = try XCTUnwrap(vad.speechSegments(in: padded))
        XCTAssertFalse(segments.isEmpty, "VAD must detect speech in the padded sample")

        let trimmed = WhisperEngine.speechOnlySamples(from: padded, segments: segments)
        XCTAssertLessThan(
            trimmed.count, padded.count - 8 * 16000,
            "VAD trimming must drop most of the 10s of padded silence"
        )

        let context = try XCTUnwrap(
            MyWhisperContext.initFromFileNoState(path: modelURL.path, params: WhisperContextParams())
        )
        var params = WhisperFullParams()
        params.noContext = false
        params.language = "en"
        var cParams = params.toC()

        XCTAssertTrue(context.initState())
        defer { context.freeState() }
        guard context.full(samples: trimmed, params: &cParams) else {
            XCTFail("whisper_full_with_state failed on VAD-trimmed audio")
            return
        }

        var text = ""
        for i in 0..<context.fullNSegments {
            text += context.fullGetSegmentText(iSegment: i) ?? ""
        }
        XCTAssertTrue(
            text.lowercased().contains("your country"),
            "Speech not recognized after VAD trimming: \(text)"
        )
    }
}

final class AudioRecorderTempCleanupTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-cleanup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func createFile(named name: String, modifiedDaysAgo days: Double) throws -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x1]))
        let date = Date().addingTimeInterval(-days * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    // Bug: orphaned temp recordings were never cleaned up and accumulated forever.
    func testRemovesOnlyFilesOlderThanMaxAge() throws {
        let oldFile = try createFile(named: "old.wav", modifiedDaysAgo: 2)
        let freshFile = try createFile(named: "fresh.wav", modifiedDaysAgo: 0)

        AudioRecorder.cleanupOldTemporaryFiles(in: directory, olderThan: 24 * 60 * 60)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path), "Stale temp recording must be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFile.path), "Recent temp recording must be kept")
    }

    func testMissingDirectoryDoesNotCrash() {
        let missing = directory.appendingPathComponent("does-not-exist")
        AudioRecorder.cleanupOldTemporaryFiles(in: missing, olderThan: 24 * 60 * 60)
    }
}

final class MicrophoneInventoryTests: XCTestCase {
    
    func testPrintConnectedMicrophones() throws {
        let service = MicrophoneService.shared
        service.refreshAvailableMicrophones()
        let available = service.availableMicrophones
        print("Available microphones count: \(available.count)")
        for device in available {
            print("Microphone:")
            print("  name: \(device.name)")
            print("  id: \(device.id)")
            print("  manufacturer: \(device.manufacturer ?? "nil")")
            print("  isBuiltIn: \(device.isBuiltIn)")
            print("  isContinuity: \(service.isContinuityMicrophone(device))")
            print("  isBluetooth: \(service.isBluetoothMicrophone(device))")
        }
        
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.microphone, .external, .builtInMicrophone]
        }
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        
        print("AVCaptureDevice count: \(discoverySession.devices.count)")
        for device in discoverySession.devices {
            print("AVCaptureDevice:")
            print("  localizedName: \(device.localizedName)")
            print("  uniqueID: \(device.uniqueID)")
            print("  manufacturer: \(device.manufacturer)")
            print("  deviceType: \(device.deviceType.rawValue)")
            if #available(macOS 13.0, *) {
                print("  isConnected: \(device.isConnected)")
            }
            print("  transportType: \(device.transportType)")
        }
    }
}

// MARK: - Keyboard Layout Tests

final class ClipboardUtilKeyboardLayoutTests: XCTestCase {
    
    private var originalInputSourceID: String?
    
    override func setUpWithError() throws {
        originalInputSourceID = ClipboardUtil.getCurrentInputSourceID()
    }
    
    override func tearDownWithError() throws {
        if let originalID = originalInputSourceID {
            _ = ClipboardUtil.switchToInputSource(withID: originalID)
        }
    }
    
    func testGetAvailableInputSources() throws {
        let sources = ClipboardUtil.getAvailableInputSources()
        XCTAssertFalse(sources.isEmpty, "Should have at least one input source")
        print("Available input sources: \(sources)")
    }
    
    func testGetCurrentInputSourceID() throws {
        let currentID = ClipboardUtil.getCurrentInputSourceID()
        XCTAssertNotNil(currentID, "Should be able to get current input source ID")
        print("Current input source: \(currentID ?? "nil")")
    }
    
    func testFindKeycodeForV_USLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched {
            throw XCTSkip("US layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in US layout")
        XCTAssertEqual(keycode, 9, "Keycode for 'v' in US QWERTY should be 9")
    }
    
    func testFindKeycodeForV_DvorakQwertyLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "DVORAK-QWERTYCMD")
        if !switched {
            throw XCTSkip("Dvorak-QWERTY layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in Dvorak-QWERTY layout")
        print("Dvorak-QWERTY keycode for 'v': \(keycode ?? 0)")
    }
    
    func testFindKeycodeForV_DvorakLeftHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Left")
        if !switched {
            throw XCTSkip("Dvorak Left-Handed layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in Dvorak Left-Handed layout")
        print("Dvorak Left-Handed keycode for 'v': \(keycode ?? 0)")
    }
    
    func testFindKeycodeForV_DvorakRightHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Right")
        if !switched {
            throw XCTSkip("Dvorak Right-Handed layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in Dvorak Right-Handed layout")
        print("Dvorak Right-Handed keycode for 'v': \(keycode ?? 0)")
    }
    
    func testFindKeycodeForV_RussianLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Russian")
        if !switched {
            throw XCTSkip("Russian layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNil(keycode, "Should NOT find keycode for 'v' in Russian layout (no Latin 'v')")
    }
    
    func testIsQwertyCommandLayout_USLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched {
            throw XCTSkip("US layout not available")
        }
        
        XCTAssertTrue(ClipboardUtil.isQwertyCommandLayout(), "US layout should be detected as QWERTY command layout")
    }
    
    func testIsQwertyCommandLayout_DvorakQwerty() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "DVORAK-QWERTYCMD")
        if !switched {
            throw XCTSkip("Dvorak-QWERTY layout not available")
        }
        
        XCTAssertTrue(ClipboardUtil.isQwertyCommandLayout(), "Dvorak-QWERTY should be detected as QWERTY command layout")
    }
    
    func testIsQwertyCommandLayout_DvorakLeftHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Left")
        if !switched {
            throw XCTSkip("Dvorak Left-Handed layout not available")
        }
        
        XCTAssertFalse(ClipboardUtil.isQwertyCommandLayout(), "Dvorak Left-Handed should NOT be detected as QWERTY command layout")
    }
    
    func testIsQwertyCommandLayout_DvorakRightHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Right")
        if !switched {
            throw XCTSkip("Dvorak Right-Handed layout not available")
        }
        
        XCTAssertFalse(ClipboardUtil.isQwertyCommandLayout(), "Dvorak Right-Handed should NOT be detected as QWERTY command layout")
    }
}

final class MicrophoneServiceContinuityTests: XCTestCase {
    
    func testContinuityDetection_iPhoneApple() {
        let device = MicrophoneService.AudioDevice(
            id: "com.apple.continuity.iphone",
            name: "iPhone Microphone",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isContinuityMicrophone(device))
    }
    
    func testContinuityDetection_ContinuityApple() {
        let device = MicrophoneService.AudioDevice(
            id: "com.apple.continuity.mic",
            name: "Continuity Microphone",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isContinuityMicrophone(device))
    }
    
    func testContinuityDetection_NotApple() {
        let device = MicrophoneService.AudioDevice(
            id: "com.vendor.iphone",
            name: "iPhone Microphone",
            manufacturer: "Vendor",
            isBuiltIn: false
        )
        XCTAssertFalse(MicrophoneService.shared.isContinuityMicrophone(device))
    }
    
    func testContinuityDetection_AppleBuiltIn() {
        let device = MicrophoneService.AudioDevice(
            id: "builtin",
            name: "MacBook Pro Microphone",
            manufacturer: "Apple",
            isBuiltIn: true
        )
        XCTAssertFalse(MicrophoneService.shared.isContinuityMicrophone(device))
    }
}

final class MicrophoneServiceBluetoothTests: XCTestCase {
    
    func testBluetoothDetection_BluetoothInName() {
        let device = MicrophoneService.AudioDevice(
            id: "some-id",
            name: "Bluetooth Headphones",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
    
    func testBluetoothDetection_BluetoothInID() {
        let device = MicrophoneService.AudioDevice(
            id: "bluetooth-device-123",
            name: "Headphones",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
    
    func testBluetoothDetection_MACAddress() {
        let device = MicrophoneService.AudioDevice(
            id: "00-22-BB-71-21-0A:input",
            name: "Amiron wireless",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
    
    func testBluetoothDetection_NotBluetooth() {
        let device = MicrophoneService.AudioDevice(
            id: "builtin",
            name: "MacBook Pro Microphone",
            manufacturer: "Apple",
            isBuiltIn: true
        )
        XCTAssertFalse(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
}

final class MicrophoneServiceRequiresConnectionTests: XCTestCase {
    
    func testRequiresConnection_iPhone() {
        let device = MicrophoneService.AudioDevice(
            id: "B95EA61C-AC67-43B3-8AB4-8AE800000003",
            name: "Микрофон (iPhone nagibator)",
            manufacturer: "Apple Inc.",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isContinuityMicrophone(device))
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device) || MicrophoneService.shared.isContinuityMicrophone(device))
    }
    
    func testRequiresConnection_Bluetooth() {
        let device = MicrophoneService.AudioDevice(
            id: "00-22-BB-71-21-0A:input",
            name: "Amiron wireless",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        XCTAssertTrue(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
    
    func testRequiresConnection_BuiltIn() {
        let device = MicrophoneService.AudioDevice(
            id: "BuiltInMicrophoneDevice",
            name: "Микрофон MacBook Pro",
            manufacturer: "Apple Inc.",
            isBuiltIn: true
        )
        XCTAssertFalse(MicrophoneService.shared.isContinuityMicrophone(device))
        XCTAssertFalse(MicrophoneService.shared.isBluetoothMicrophone(device))
    }
}

// MARK: - Paste Integration Tests

final class ClipboardUtilPasteIntegrationTests: XCTestCase {
    
    private static var sharedTextEditProcess: NSRunningApplication?
    private static var sharedAppElement: AXUIElement?
    private static var originalInputSourceID: String?
    private static var testCounter = 0
    
    private func log(_ message: String) {
        let logMessage = "[TEST \(Date())] \(message)\n"
        print(logMessage)
        let logFile = "/tmp/paste_test_log.txt"
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let handle = FileHandle(forWritingAtPath: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logFile, contents: data)
            }
        }
    }
    
    override class func setUp() {
        super.setUp()
        print("[TEST] ========== CLASS SETUP ==========")
        originalInputSourceID = ClipboardUtil.getCurrentInputSourceID()
        print("[TEST] Original layout: \(originalInputSourceID ?? "nil")")
        
        _ = ClipboardUtil.switchToInputSource(withID: "US")
        print("[TEST] Switched to US layout for setup")
        
        terminateTextEditIfRunning()
        testCounter = 0
    }
    
    override class func tearDown() {
        print("[TEST] ========== CLASS TEARDOWN ==========")
        if let originalID = originalInputSourceID {
            _ = ClipboardUtil.switchToInputSource(withID: originalID)
        }
        terminateTextEditIfRunning()
        sharedTextEditProcess = nil
        sharedAppElement = nil
        super.tearDown()
    }
    
    override func setUpWithError() throws {
        Self.testCounter += 1
        log("--- Test #\(Self.testCounter) SETUP ---")
        try super.setUpWithError()
    }
    
    override func tearDownWithError() throws {
        log("--- Test #\(Self.testCounter) TEARDOWN ---")
        try super.tearDownWithError()
    }
    
    private static func terminateTextEditIfRunning() {
        let runningApps = NSWorkspace.shared.runningApplications
        var terminated = false
        for app in runningApps where app.bundleIdentifier == "com.apple.TextEdit" {
            print("[TEST] Force terminating TextEdit (pid: \(app.processIdentifier))")
            app.forceTerminate()
            terminated = true
        }
        if terminated {
            Thread.sleep(forTimeInterval: 0.5)
        }
        sharedTextEditProcess = nil
        sharedAppElement = nil
    }
    
    private func terminateTextEditIfRunning() {
        Self.terminateTextEditIfRunning()
    }
    
    private func launchTextEditIfNeeded() throws -> AXUIElement {
        if let appElement = Self.sharedAppElement,
           let process = Self.sharedTextEditProcess,
           !process.isTerminated {
            log("TextEdit already running (pid: \(process.processIdentifier))")
            return appElement
        }
        
        log("Launching TextEdit...")
        let workspace = NSWorkspace.shared
        
        guard let textEditURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            throw XCTSkip("TextEdit not found")
        }
        
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        
        let semaphore = DispatchSemaphore(value: 0)
        var launchedApp: NSRunningApplication?
        
        workspace.openApplication(at: textEditURL, configuration: configuration) { app, error in
            launchedApp = app
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 5.0)
        
        guard let app = launchedApp else {
            throw XCTSkip("Failed to launch TextEdit")
        }
        
        log("TextEdit launched (pid: \(app.processIdentifier))")
        Self.sharedTextEditProcess = app
        Thread.sleep(forTimeInterval: 1.0)
        Self.sharedAppElement = AXUIElementCreateApplication(app.processIdentifier)
        
        dismissOpenDialogIfPresent()
        createNewDocumentIfNeeded()
        
        return Self.sharedAppElement!
    }
    
    private func activateTextEdit() {
        Self.sharedTextEditProcess?.activate()
        Thread.sleep(forTimeInterval: 0.3)
    }
    
    private func sendKeyStroke(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        
        keyDown.flags = flags
        keyUp.flags = flags
        
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
    
    private func dismissOpenDialogIfPresent() {
        log("Dismissing open dialog if present...")
        activateTextEdit()
        sendKeyStroke(keyCode: 53)
        Thread.sleep(forTimeInterval: 0.5)
        sendKeyStroke(keyCode: 53)
        Thread.sleep(forTimeInterval: 0.3)
    }
    
    private func createNewDocumentIfNeeded() {
        log("Creating new document...")
        activateTextEdit()
        sendKeyStroke(keyCode: 45, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 1.0)
        
        clickInTextArea()
    }
    
    private func clickInTextArea() {
        log("Clicking in text area...")
        guard let process = Self.sharedTextEditProcess else { return }
        
        let appElement = AXUIElementCreateApplication(process.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowValue) == .success,
              let windows = windowValue as? [AXUIElement],
              let mainWindow = windows.first else {
            log("No windows found")
            return
        }
        
        var scrollAreaValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(mainWindow, kAXChildrenAttribute as CFString, &scrollAreaValue) == .success,
           let children = scrollAreaValue as? [AXUIElement] {
            for child in children {
                var roleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success,
                   let role = roleValue as? String,
                   role == "AXScrollArea" {
                    var textAreaValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &textAreaValue) == .success,
                       let textAreaChildren = textAreaValue as? [AXUIElement] {
                        for textChild in textAreaChildren {
                            var textRoleValue: CFTypeRef?
                            if AXUIElementCopyAttributeValue(textChild, kAXRoleAttribute as CFString, &textRoleValue) == .success,
                               let textRole = textRoleValue as? String,
                               textRole == "AXTextArea" {
                                log("Found text area, setting focus...")
                                AXUIElementSetAttributeValue(textChild, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                                Thread.sleep(forTimeInterval: 0.3)
                                return
                            }
                        }
                    }
                }
            }
        }
        log("Text area not found, clicking in center of window...")
    }
    
    private func selectAllAndDelete() {
        log("Selecting all and deleting...")
        activateTextEdit()
        sendKeyStroke(keyCode: 0, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.1)
        sendKeyStroke(keyCode: 51)
        Thread.sleep(forTimeInterval: 0.2)
    }
    
    // MARK: - Basic Layouts
    
    func testPasteWithUSLayout() throws {
        try testPasteWithLayout(layoutID: "US", testText: "Hello from US layout test")
    }
    
    func testPasteWithABCLayout() throws {
        try testPasteWithLayout(layoutID: "ABC", testText: "Hello from ABC layout test")
    }
    
    func testPasteWithUSInternationalLayout() throws {
        try testPasteWithLayout(layoutID: "USInternational", testText: "Hello from US International layout test")
    }
    
    func testPasteWithBritishLayout() throws {
        try testPasteWithLayout(layoutID: "British", testText: "Hello from British layout test")
    }
    
    func testPasteWithColemakLayout() throws {
        try testPasteWithLayout(layoutID: "Colemak", testText: "Hello from Colemak layout test")
    }
    
    // MARK: - Dvorak Layouts
    
    func testPasteWithDvorakQwertyLayout() throws {
        try testPasteWithLayout(layoutID: "DVORAK-QWERTYCMD", testText: "Hello from Dvorak-QWERTY layout test")
    }
    
    func testPasteWithDvorakLeftHandLayout() throws {
        try testPasteWithLayout(layoutID: "Dvorak-Left", testText: "Hello from Dvorak Left-Handed layout test")
    }
    
    func testPasteWithDvorakRightHandLayout() throws {
        try testPasteWithLayout(layoutID: "Dvorak-Right", testText: "Hello from Dvorak Right-Handed layout test")
    }
    
    // MARK: - Cyrillic Layouts
    
    func testPasteWithRussianLayout() throws {
        try testPasteWithLayout(layoutID: "Russian", testText: "Привет из теста русской раскладки")
    }
    
    func testPasteWithUkrainianLayout() throws {
        try testPasteWithLayout(layoutID: "Ukrainian", testText: "Привіт з тесту української розкладки")
    }
    
    // MARK: - European Layouts
    
    func testPasteWithGermanLayout() throws {
        try testPasteWithLayout(layoutID: "German", testText: "Hallo aus dem deutschen Layout-Test")
    }
    
    func testPasteWithFrenchLayout() throws {
        try testPasteWithLayout(layoutID: "French", testText: "Bonjour du test de disposition française")
    }
    
    func testPasteWithSpanishLayout() throws {
        try testPasteWithLayout(layoutID: "Spanish", testText: "Hola desde la prueba de teclado español")
    }
    
    func testPasteWithItalianLayout() throws {
        try testPasteWithLayout(layoutID: "Italian", testText: "Ciao dal test del layout italiano")
    }
    
    func testPasteWithPortugueseLayout() throws {
        try testPasteWithLayout(layoutID: "Portuguese", testText: "Olá do teste de layout português")
    }
    
    func testPasteWithPolishLayout() throws {
        try testPasteWithLayout(layoutID: "Polish", testText: "Cześć z testu polskiego układu")
    }
    
    func testPasteWithGreekLayout() throws {
        try testPasteWithLayout(layoutID: "Greek", testText: "Γειά σου από τη δοκιμή ελληνικής διάταξης")
    }
    
    func testPasteWithTurkishLayout() throws {
        try testPasteWithLayout(layoutID: "Turkish", testText: "Türkçe klavye testinden merhaba")
    }
    
    func testPasteWithSwissGermanLayout() throws {
        try testPasteWithLayout(layoutID: "Swiss German", testText: "Grüezi vom Schweizer Layout-Test")
    }
    
    func testPasteWithDutchLayout() throws {
        try testPasteWithLayout(layoutID: "Dutch", testText: "Hallo van de Nederlandse layout test")
    }
    
    func testPasteWithSwedishLayout() throws {
        try testPasteWithLayout(layoutID: "Swedish", testText: "Hej från det svenska layouttestet")
    }
    
    func testPasteWithNorwegianLayout() throws {
        try testPasteWithLayout(layoutID: "Norwegian", testText: "Hei fra den norske layouttesten")
    }
    
    func testPasteWithDanishLayout() throws {
        try testPasteWithLayout(layoutID: "Danish", testText: "Hej fra den danske layouttest")
    }
    
    func testPasteWithFinnishLayout() throws {
        try testPasteWithLayout(layoutID: "Finnish", testText: "Terve suomalaisesta näppäimistötestistä")
    }
    
    func testPasteWithCzechLayout() throws {
        try testPasteWithLayout(layoutID: "Czech", testText: "Ahoj z testu českého rozložení")
    }
    
    func testPasteWithHungarianLayout() throws {
        try testPasteWithLayout(layoutID: "Hungarian", testText: "Helló a magyar billentyűzet tesztből")
    }
    
    func testPasteWithRomanianLayout() throws {
        try testPasteWithLayout(layoutID: "Romanian", testText: "Bună din testul de layout românesc")
    }
    
    // MARK: - Asian Layouts
    
    func testPasteWithChinesePinyinLayout() throws {
        try testPasteWithLayout(layoutID: "Pinyin", testText: "你好从中文拼音布局测试")
    }
    
    func testPasteWithChineseTraditionalLayout() throws {
        try testPasteWithLayout(layoutID: "Traditional", testText: "你好從繁體中文佈局測試")
    }
    
    func testPasteWithJapaneseLayout() throws {
        try testPasteWithLayout(layoutID: "Japanese", testText: "こんにちは日本語レイアウトテストから")
    }
    
    func testPasteWithJapaneseRomajiLayout() throws {
        try testPasteWithLayout(layoutID: "Romaji", testText: "Hello from Japanese Romaji layout test")
    }
    
    func testPasteWithKoreanLayout() throws {
        try testPasteWithLayout(layoutID: "Korean", testText: "안녕하세요 한국어 레이아웃 테스트에서")
    }
    
    func testPasteWithVietnameseLayout() throws {
        try testPasteWithLayout(layoutID: "Vietnamese", testText: "Xin chào từ bài kiểm tra bố cục tiếng Việt")
    }
    
    func testPasteWithThaiLayout() throws {
        try testPasteWithLayout(layoutID: "Thai", testText: "สวัสดีจากการทดสอบคีย์บอร์ดภาษาไทย")
    }
    
    // MARK: - Middle Eastern Layouts
    
    func testPasteWithArabicLayout() throws {
        try testPasteWithLayout(layoutID: "Arabic", testText: "مرحبا من اختبار تخطيط اللغة العربية")
    }
    
    func testPasteWithHebrewLayout() throws {
        try testPasteWithLayout(layoutID: "Hebrew", testText: "שלום ממבחן פריסת עברית")
    }
    
    func testPasteWithPersianLayout() throws {
        try testPasteWithLayout(layoutID: "Persian", testText: "سلام از آزمایش چیدمان فارسی")
    }
    
    // MARK: - Helper Method
    
    private func testPasteWithLayout(layoutID: String, testText: String) throws {
        log("Testing layout: \(layoutID)")
        
        _ = ClipboardUtil.switchToInputSource(withID: "US")
        log("Switched to US for TextEdit operations")
        
        _ = try launchTextEditIfNeeded()
        selectAllAndDelete()
        activateTextEdit()
        
        let switched = ClipboardUtil.switchToInputSource(withID: layoutID)
        if !switched {
            log("Layout \(layoutID) not available, skipping")
            throw XCTSkip("\(layoutID) layout not available")
        }
        log("Switched to layout: \(layoutID)")
        
        Thread.sleep(forTimeInterval: 0.2)
        
        activateTextEdit()
        clickInTextArea()
        
        log("Inserting text: \(testText)")
        ClipboardUtil.insertText(testText)
        
        Thread.sleep(forTimeInterval: 0.5)
        
        activateTextEdit()
        Thread.sleep(forTimeInterval: 0.2)
        
        let resultText = getTextFromTextEdit()
        log("Result text: \(resultText ?? "nil")")
        XCTAssertEqual(resultText, testText, "Text should be pasted correctly with \(layoutID) layout")
    }
    
    private func getTextFromTextEdit() -> String? {
        guard let process = Self.sharedTextEditProcess else { return nil }
        
        let appElement = AXUIElementCreateApplication(process.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowValue) == .success,
              let windows = windowValue as? [AXUIElement],
              let mainWindow = windows.first else {
            return nil
        }
        
        var scrollAreaValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(mainWindow, kAXChildrenAttribute as CFString, &scrollAreaValue) == .success,
           let children = scrollAreaValue as? [AXUIElement] {
            for child in children {
                var roleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success,
                   let role = roleValue as? String,
                   role == "AXScrollArea" {
                    var textAreaValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &textAreaValue) == .success,
                       let textAreaChildren = textAreaValue as? [AXUIElement] {
                        for textChild in textAreaChildren {
                            var textRoleValue: CFTypeRef?
                            if AXUIElementCopyAttributeValue(textChild, kAXRoleAttribute as CFString, &textRoleValue) == .success,
                               let textRole = textRoleValue as? String,
                               textRole == "AXTextArea" {
                                var valueRef: CFTypeRef?
                                if AXUIElementCopyAttributeValue(textChild, kAXValueAttribute as CFString, &valueRef) == .success,
                                   let text = valueRef as? String {
                                    return text
                                }
                            }
                        }
                    }
                }
            }
        }
        return nil
    }
    
    func testPasteAllAvailableLayouts() throws {
        log("Testing all available layouts")
        let layouts = ClipboardUtil.getAvailableInputSources()
        log("Available layouts: \(layouts)")
        var results: [(layout: String, success: Bool, error: String?)] = []
        
        for layout in layouts {
            log("Testing layout: \(layout)")
            
            _ = ClipboardUtil.switchToInputSource(withID: "US")
            
            _ = try launchTextEditIfNeeded()
            selectAllAndDelete()
            activateTextEdit()
            
            let switched = ClipboardUtil.switchToInputSource(withID: layout)
            if !switched {
                log("Failed to switch to \(layout)")
                results.append((layout, false, "Failed to switch"))
                continue
            }
            
            Thread.sleep(forTimeInterval: 0.2)
            
            activateTextEdit()
            clickInTextArea()
            
            let testText = "Test for \(layout)"
            ClipboardUtil.insertText(testText)
            
            Thread.sleep(forTimeInterval: 0.5)
            
            activateTextEdit()
            Thread.sleep(forTimeInterval: 0.2)
            
            let resultText = getTextFromTextEdit() ?? ""
            let success = resultText == testText
            log("Layout \(layout): expected '\(testText)', got '\(resultText)' - \(success ? "OK" : "FAIL")")
            results.append((layout, success, success ? nil : "Expected '\(testText)', got '\(resultText)'"))
        }
        
        print("\n=== Paste Test Results ===")
        for result in results {
            let status = result.success ? "✅" : "❌"
            print("\(status) \(result.layout): \(result.error ?? "OK")")
        }
        print("===========================\n")
        
        let failedLayouts = results.filter { !$0.success }
        XCTAssertTrue(failedLayouts.isEmpty, "Failed layouts: \(failedLayouts.map { $0.layout })")
    }
}

// MARK: - Keyboard Layout Provider Tests

final class KeyboardLayoutProviderTests: XCTestCase {
    
    private let provider = KeyboardLayoutProvider.shared
    private var originalInputSourceID: String?
    
    override func setUpWithError() throws {
        originalInputSourceID = ClipboardUtil.getCurrentInputSourceID()
    }
    
    override func tearDownWithError() throws {
        if let originalID = originalInputSourceID {
            _ = ClipboardUtil.switchToInputSource(withID: originalID)
        }
    }
    
    // MARK: - Physical Type Detection
    
    func testDetectPhysicalType_returnsValue() {
        let physicalType = provider.detectPhysicalType()
        print("Detected physical keyboard type: \(physicalType)")
        XCTAssertTrue([.ansi, .iso, .jis].contains(physicalType))
    }
    
    // MARK: - Label Resolution
    
    func testResolveLabels_returnsLabelsForCurrentLayout() {
        let labels = provider.resolveLabels()
        XCTAssertNotNil(labels, "Should resolve labels for current layout")
        if let labels = labels {
            XCTAssertEqual(labels.count, KeyboardLayoutProvider.ansiKeycodes.count,
                           "Should have a label for every ANSI keycode")
        }
    }
    
    func testResolveLabels_USLayout_hasExpectedKeys() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched { throw XCTSkip("US layout not available") }
        
        let labels = provider.resolveLabels()
        XCTAssertNotNil(labels)
        guard let labels = labels else { return }
        
        XCTAssertEqual(labels[0], "A", "Keycode 0 should be A in US layout")
        XCTAssertEqual(labels[1], "S", "Keycode 1 should be S in US layout")
        XCTAssertEqual(labels[13], "W", "Keycode 13 should be W in US layout")
        XCTAssertEqual(labels[50], "`", "Keycode 50 should be ` in US layout")
    }
    
    func testResolveLabels_RussianLayout_hasCyrillicKeys() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Russian")
        if !switched { throw XCTSkip("Russian layout not available") }
        
        let labels = provider.resolveLabels()
        XCTAssertNotNil(labels)
        guard let labels = labels else { return }
        
        XCTAssertEqual(labels[0], "Ф", "Keycode 0 should be Ф in Russian layout")
        XCTAssertEqual(labels[1], "Ы", "Keycode 1 should be Ы in Russian layout")
    }
    
    // MARK: - resolveInfo (full validation)
    
    func testResolveInfo_USLayout_returnsInfo() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched { throw XCTSkip("US layout not available") }
        
        let info = provider.resolveInfo()
        if provider.detectPhysicalType() == .ansi {
            XCTAssertNotNil(info, "US layout on ANSI keyboard should produce info")
        }
    }
    
    func testResolveInfo_RussianLayout_returnsInfo() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Russian")
        if !switched { throw XCTSkip("Russian layout not available") }
        
        let info = provider.resolveInfo()
        if provider.detectPhysicalType() == .ansi {
            XCTAssertNotNil(info, "Russian layout on ANSI keyboard should produce info (Cyrillic labels)")
        }
    }
    
    func testResolveInfo_GermanLayout_returnsInfo() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "German")
        if !switched { throw XCTSkip("German layout not available") }
        
        let info = provider.resolveInfo()
        if provider.detectPhysicalType() == .ansi {
            XCTAssertNotNil(info, "German layout on ANSI keyboard should produce info")
        }
    }
    
    func testResolveInfo_nonANSI_returnsNil() throws {
        let physicalType = provider.detectPhysicalType()
        if physicalType != .ansi {
            let info = provider.resolveInfo()
            XCTAssertNil(info, "Non-ANSI physical keyboard should return nil from resolveInfo")
        } else {
            throw XCTSkip("This machine has ANSI keyboard, cannot test non-ANSI rejection")
        }
    }
    
    // MARK: - All Available Layouts
    
    func testResolveLabels_allAvailableLayouts() {
        let layouts = ClipboardUtil.getAvailableInputSources()
        var results: [(layout: String, labelCount: Int, success: Bool)] = []
        
        for layout in layouts {
            let switched = ClipboardUtil.switchToInputSource(withID: layout)
            guard switched else {
                results.append((layout, 0, false))
                continue
            }
            
            let labels = provider.resolveLabels()
            let count = labels?.count ?? 0
            let ok = count == KeyboardLayoutProvider.ansiKeycodes.count
            results.append((layout, count, ok))
        }
        
        print("\n=== Keyboard Layout Provider Results ===")
        for r in results {
            let status = r.success ? "OK" : "SKIP"
            print("[\(status)] \(r.layout): \(r.labelCount) labels")
        }
        print("=========================================\n")
    }
}

@MainActor
final class AddSpaceAfterSentenceTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        AppPreferences.shared.addSpaceAfterSentence = true
    }
    
    override func tearDown() {
        AppPreferences.shared.addSpaceAfterSentence = true
        super.tearDown()
    }
    
    func testApplyPostProcessing_addsSpaceWhenEndsWithPeriod() {
        let result = IndicatorViewModel.applyPostProcessing("Hello world.")
        XCTAssertEqual(result, "Hello world. ")
    }
    
    func testApplyPostProcessing_noSpaceWhenNoPeriod() {
        let result = IndicatorViewModel.applyPostProcessing("Hello world")
        XCTAssertEqual(result, "Hello world")
    }
    
    func testApplyPostProcessing_noSpaceWhenDisabled() {
        AppPreferences.shared.addSpaceAfterSentence = false
        let result = IndicatorViewModel.applyPostProcessing("Hello world.")
        XCTAssertEqual(result, "Hello world.")
    }
    
    func testApplyPostProcessing_emptyString() {
        let result = IndicatorViewModel.applyPostProcessing("")
        XCTAssertEqual(result, "")
    }
    
    func testApplyPostProcessing_onlyPeriod() {
        let result = IndicatorViewModel.applyPostProcessing(".")
        XCTAssertEqual(result, ". ")
    }
    
    func testApplyPostProcessing_endsWithQuestionMark() {
        let result = IndicatorViewModel.applyPostProcessing("How are you?")
        XCTAssertEqual(result, "How are you? ")
    }
    
    func testApplyPostProcessing_endsWithExclamationMark() {
        let result = IndicatorViewModel.applyPostProcessing("Wow!")
        XCTAssertEqual(result, "Wow! ")
    }
    
    func testApplyPostProcessing_endsWithComma() {
        let result = IndicatorViewModel.applyPostProcessing("First,")
        XCTAssertEqual(result, "First, ")
    }
    
    func testApplyPostProcessing_endsWithColon() {
        let result = IndicatorViewModel.applyPostProcessing("Note:")
        XCTAssertEqual(result, "Note: ")
    }
    
    func testApplyPostProcessing_endsWithSemicolon() {
        let result = IndicatorViewModel.applyPostProcessing("Done;")
        XCTAssertEqual(result, "Done; ")
    }
    
    func testApplyPostProcessing_endsWithEllipsis() {
        let result = IndicatorViewModel.applyPostProcessing("Well...")
        XCTAssertEqual(result, "Well... ")
    }
    
    func testApplyPostProcessing_multipleSentences() {
        let result = IndicatorViewModel.applyPostProcessing("First sentence. Second sentence.")
        XCTAssertEqual(result, "First sentence. Second sentence. ")
    }
    
    func testApplyPostProcessing_endsWithLetterNoSpace() {
        let result = IndicatorViewModel.applyPostProcessing("No punctuation here")
        XCTAssertEqual(result, "No punctuation here")
    }
    
    func testApplyPostProcessing_defaultPreferenceIsEnabled() {
        UserDefaults.standard.removeObject(forKey: "addSpaceAfterSentence")
        let result = IndicatorViewModel.applyPostProcessing("Test.")
        XCTAssertEqual(result, "Test. ")
    }
}

final class FocusUtilsCaretPositionTests: XCTestCase {

    // Primary screen 1440x900 with a larger secondary display to the right,
    // shifted 100 pt up (typical multi-monitor setup).
    private let primaryMaxY: CGFloat = 900
    private let screens = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 1440, y: 100, width: 1920, height: 1080)
    ]

    // Bug: apps returning an all-zero caret rect pinned the indicator to a screen corner.
    func testZeroCaretRectIsRejected() {
        XCTAssertNil(FocusUtils.validatedCaretPoint(
            fromAXRect: .zero, primaryScreenMaxY: primaryMaxY, screenFrames: screens
        ))
        XCTAssertFalse(FocusUtils.isValidCaretRect(.zero))
    }

    func testValidCaretRectIsConvertedToCocoa() {
        let rect = CGRect(x: 100, y: 200, width: 1, height: 16)
        let point = FocusUtils.validatedCaretPoint(
            fromAXRect: rect, primaryScreenMaxY: primaryMaxY, screenFrames: screens
        )
        XCTAssertEqual(point, NSPoint(x: 100, y: 700))
    }

    // Bug: Terminal.app reports .success with x:0 y:<screen height> w:0 h:0 —
    // that point maps exactly to the bottom-left corner of the screen.
    func testZeroSizeCaretRectIsRejected() {
        let terminalRect = CGRect(x: 0, y: primaryMaxY, width: 0, height: 0)
        XCTAssertNil(FocusUtils.validatedCaretPoint(
            fromAXRect: terminalRect, primaryScreenMaxY: primaryMaxY, screenFrames: screens
        ))

        // Zero size at any position means the app doesn't know the real bounds.
        XCTAssertFalse(FocusUtils.isValidCaretRect(CGRect(x: 300, y: 300, width: 0, height: 0)))
    }

    func testZeroWidthCaretWithLineHeightIsAccepted() {
        // A collapsed caret legitimately has zero width but always a line height.
        let rect = CGRect(x: 300, y: 300, width: 0, height: 16)
        let point = FocusUtils.validatedCaretPoint(
            fromAXRect: rect, primaryScreenMaxY: primaryMaxY, screenFrames: screens
        )
        XCTAssertEqual(point, NSPoint(x: 300, y: 600))
    }

    func testCaretPointOutsideAllScreensIsRejected() {
        // AX y=5000 converts to Cocoa y=-4100, below every screen.
        let rect = CGRect(x: 100, y: 5000, width: 1, height: 16)
        XCTAssertNil(FocusUtils.validatedCaretPoint(
            fromAXRect: rect, primaryScreenMaxY: primaryMaxY, screenFrames: screens
        ))
    }

    func testCaretOnSecondScreenIsAccepted() {
        // Cocoa target (2000, 500) on the secondary display: AX y = 900 - 500 = 400.
        let rect = CGRect(x: 2000, y: 400, width: 1, height: 16)
        let point = FocusUtils.validatedCaretPoint(
            fromAXRect: rect, primaryScreenMaxY: primaryMaxY, screenFrames: screens
        )
        XCTAssertEqual(point, NSPoint(x: 2000, y: 500))
    }

    func testConvertAXPointToCocoaFlipsY() {
        let point = FocusUtils.convertAXPointToCocoa(CGPoint(x: 10, y: 40), primaryScreenMaxY: 900)
        XCTAssertEqual(point, NSPoint(x: 10, y: 860))
    }

    // Bug: NSRect.contains excludes the top edge, so a point exactly on the
    // screen border fell through to the wrong screen.
    func testPointOnScreenEdgeIsContained() {
        XCTAssertEqual(FocusUtils.frameIndex(containing: NSPoint(x: 0, y: 900), frames: screens), 0)
        XCTAssertEqual(FocusUtils.frameIndex(containing: NSPoint(x: 1440, y: 100), frames: screens), 0)
    }

    func testPointInDeadZoneBetweenScreensIsNotContained() {
        // Below the secondary display, right of the primary one.
        XCTAssertNil(FocusUtils.frameIndex(containing: NSPoint(x: 1500, y: 50), frames: screens))
    }

    // MARK: Focused element anchor (fallback when caret bounds are unavailable)

    func testElementAnchorPointIsTopCenterOfFrame() {
        // AX frame: input field at x:200 y:100, 400x30 → top center AX (400, 100)
        // → Cocoa (400, 800).
        let frame = CGRect(x: 200, y: 100, width: 400, height: 30)
        let point = FocusUtils.validatedElementAnchorPoint(
            forAXFrame: frame, primaryScreenMaxY: primaryMaxY, screenFrames: screens
        )
        XCTAssertEqual(point, NSPoint(x: 400, y: 800))
    }

    func testDegenerateElementFrameIsRejected() {
        XCTAssertNil(FocusUtils.validatedElementAnchorPoint(
            forAXFrame: .zero, primaryScreenMaxY: primaryMaxY, screenFrames: screens
        ))
        XCTAssertNil(FocusUtils.validatedElementAnchorPoint(
            forAXFrame: CGRect(x: 100, y: 100, width: 0, height: 30),
            primaryScreenMaxY: primaryMaxY, screenFrames: screens
        ))
    }

    func testOffScreenElementFrameIsRejected() {
        // Top center converts to Cocoa y = 900 - 5000 = -4100, below every screen.
        let frame = CGRect(x: 100, y: 5000, width: 400, height: 30)
        XCTAssertNil(FocusUtils.validatedElementAnchorPoint(
            forAXFrame: frame, primaryScreenMaxY: primaryMaxY, screenFrames: screens
        ))
    }
}

final class IndicatorWindowGeometryTests: XCTestCase {

    // Bug: the panel was 200x60 for a 200x36 card — during the appear
    // animation the card moves 20 pt down, and everything outside the window
    // bounds is cut off, so the bottom rounded corners were visibly clipped.
    func testPanelFitsCardAtWorstAnimationPhase() {
        let halfWindow = IndicatorWindow.windowSize.height / 2
        // Animation start: the card is scaled down and pushed fully down.
        let worstBottomExtent = IndicatorWindow.cardSize.height / 2 * IndicatorWindow.appearInitialScale
            + IndicatorWindow.appearOffset
        XCTAssertLessThanOrEqual(worstBottomExtent, halfWindow,
                                 "Appear animation doesn't fit inside the panel vertically")

        // Spring overshoot scales the card slightly above 1.
        let springOvershoot: CGFloat = 1.1
        let worstSideExtent = IndicatorWindow.cardSize.width / 2 * springOvershoot
        XCTAssertLessThanOrEqual(worstSideExtent, IndicatorWindow.windowSize.width / 2,
                                 "Card doesn't fit inside the panel horizontally")

        let worstTopExtent = IndicatorWindow.cardSize.height / 2 * springOvershoot
        XCTAssertLessThanOrEqual(worstTopExtent, halfWindow,
                                 "Spring overshoot doesn't fit inside the panel at the top")
    }

    // Bug: the hidden transform translated +y, which in Core Animation
    // coordinates on macOS is up — the card appeared from above sliding down
    // instead of rising bottom-up towards its resting position.
    @MainActor
    func testHiddenTransformPushesCardDown() {
        let view = NSView(frame: NSRect(origin: .zero, size: IndicatorWindow.windowSize))
        let transform = IndicatorWindowManager.hiddenTransform(for: view)

        // The card center must map below its resting position (smaller y in
        // CA coordinates) and keep the same x.
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let mappedX = transform.m11 * center.x + transform.m21 * center.y + transform.m41
        let mappedY = transform.m12 * center.x + transform.m22 * center.y + transform.m42
        XCTAssertEqual(mappedX, center.x, accuracy: 0.001)
        XCTAssertEqual(mappedY, center.y - IndicatorWindow.appearOffset, accuracy: 0.001,
                       "Hidden state must sit below the resting position")
    }

    // Bug: NSHostingView's default sizingOptions let SwiftUI's ideal size
    // drive the window frame — the panel shrank to the card size right after
    // contentView was set and the window bounds clipped the whole animation.
    @MainActor
    func testWindowKeepsPanelSizeAfterPresent() async throws {
        let manager = IndicatorWindowManager.shared
        let vm = manager.prepare()
        manager.presentWindow(for: vm, nearPoint: NSPoint(x: 700, y: 500))

        // Give AppKit a runloop turn to apply any pending autosizing.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(manager.window?.frame.size, IndicatorWindow.windowSize,
                       "The panel must keep its size; SwiftUI content must not resize the window")

        manager.hide()
        try await Task.sleep(nanoseconds: 700_000_000)
    }
}

@MainActor
final class NoMicrophoneGuardTests: XCTestCase {

    /// Forces `MicrophoneService.shared` to report no active microphone for the
    /// duration of `body`, restoring the previous state afterwards.
    private func withNoMicrophone(_ body: () -> Void) {
        let service = MicrophoneService.shared
        let savedSelected = service.selectedMicrophone
        let savedCurrent = service.currentMicrophone

        service.selectedMicrophone = nil
        service.currentMicrophone = nil
        defer {
            service.selectedMicrophone = savedSelected
            service.currentMicrophone = savedCurrent
        }

        XCTAssertNil(service.getActiveMicrophone(), "Precondition: no active microphone")
        body()
    }

    func testIndicatorViewModel_startRecording_withNoMicrophone_showsNoMicrophoneState() {
        withNoMicrophone {
            let viewModel = IndicatorViewModel()
            viewModel.startRecording()

            XCTAssertTrue(viewModel.state == .noMicrophone,
                          "Indicator should show the no-microphone state instead of a fake 'recording' state")
            XCTAssertFalse(viewModel.recorder.isRecording,
                           "Recorder must not be recording when there is no microphone")

            viewModel.cleanup()
        }
    }

    func testContentViewModel_startRecording_withNoMicrophone_doesNotStartRecording() {
        withNoMicrophone {
            let viewModel = ContentViewModel()
            viewModel.startRecording()

            XCTAssertTrue(viewModel.state == .idle,
                          "In-app recording must not begin when there is no microphone")
            XCTAssertFalse(viewModel.recorder.isRecording,
                           "Recorder must not be recording when there is no microphone")
        }
    }
}

final class TextUtilTests: XCTestCase {

    // MARK: - wordCount

    func testWordCount_simpleText() {
        XCTAssertEqual(TextUtil.wordCount("hello world"), 2)
    }

    func testWordCount_emptyString() {
        XCTAssertEqual(TextUtil.wordCount(""), 0)
    }

    func testWordCount_multipleSpaces() {
        XCTAssertEqual(TextUtil.wordCount("hello   world"), 2)
    }

    func testWordCount_newlines() {
        XCTAssertEqual(TextUtil.wordCount("hello\nworld"), 2)
    }

    func testWordCount_singleWord() {
        XCTAssertEqual(TextUtil.wordCount("hello"), 1)
    }

    func testWordCount_leadingTrailingWhitespace() {
        XCTAssertEqual(TextUtil.wordCount("  hi there  "), 2)
    }

    // MARK: - formatDuration

    func testFormatDuration_zero() {
        XCTAssertEqual(TextUtil.formatDuration(0), "0s")
    }

    func testFormatDuration_seconds() {
        XCTAssertEqual(TextUtil.formatDuration(30), "30s")
    }

    func testFormatDuration_minutesAndSeconds() {
        XCTAssertEqual(TextUtil.formatDuration(65), "1m 5s")
    }

    func testFormatDuration_exactMinutes() {
        XCTAssertEqual(TextUtil.formatDuration(120), "2m 0s")
    }

    func testFormatDuration_hoursMinutesSeconds() {
        XCTAssertEqual(TextUtil.formatDuration(3661), "1h 1m 1s")
    }

    func testFormatDuration_exactHours() {
        XCTAssertEqual(TextUtil.formatDuration(3600), "1h 0m 0s")
    }
}

final class HebrewIvritSupportTests: XCTestCase {

    // MARK: Task 1 — Hebrew language
    func testHebrewIsAvailableLanguage() {
        XCTAssertTrue(LanguageUtil.availableLanguages.contains("he"))
        XCTAssertEqual(LanguageUtil.languageNames["he"], "Hebrew")
    }

    // MARK: Task 2 — model struct filename/preferredLanguage
    func testDownloadableModelDefaultsFilenameToURLBasename() {
        let model = SettingsDownloadableModel(
            name: "X", isDownloaded: false,
            url: URL(string: "https://example.com/path/ggml-foo.bin?download=true")!,
            size: 1, description: "d")
        XCTAssertEqual(model.filename, "ggml-foo.bin")
        XCTAssertNil(model.preferredLanguage)
    }

    func testDownloadableModelHonorsExplicitFilenameAndLanguage() {
        let model = SettingsDownloadableModel(
            name: "X", isDownloaded: false,
            url: URL(string: "https://example.com/ggml-model.bin?download=true")!,
            size: 1, description: "d",
            filename: "ggml-custom.bin", preferredLanguage: "he")
        XCTAssertEqual(model.filename, "ggml-custom.bin")
        XCTAssertEqual(model.preferredLanguage, "he")
    }

    func testExistingStandardModelsKeepURLBasenameFilenames() {
        for m in SettingsDownloadableModels.availableModels where m.preferredLanguage == nil {
            XCTAssertEqual(m.filename, m.url.lastPathComponent)
        }
    }

    // MARK: Task 3 — ivrit.ai model entry
    func testIvritModelIsAvailableWithCorrectMetadata() {
        let ivrit = SettingsDownloadableModels.availableModels.first {
            $0.filename == "ggml-ivrit-large-v3-turbo.bin"
        }
        XCTAssertNotNil(ivrit)
        XCTAssertEqual(ivrit?.preferredLanguage, "he")
        XCTAssertEqual(ivrit?.url.host, "huggingface.co")
        XCTAssertTrue(ivrit?.url.absoluteString.contains("ivrit-ai/whisper-large-v3-turbo-ggml") ?? false)
    }

    // MARK: Task 4 — preferred-language lookup
    func testPreferredLanguageLookupForIvritModel() {
        XCTAssertEqual(
            SettingsDownloadableModels.preferredLanguage(forFilename: "ggml-ivrit-large-v3-turbo.bin"),
            "he")
    }

    func testPreferredLanguageLookupForStandardModelIsNil() {
        XCTAssertNil(SettingsDownloadableModels.preferredLanguage(forFilename: "ggml-large-v3-turbo.bin"))
    }

    func testPreferredLanguageLookupForUnknownFilenameIsNil() {
        XCTAssertNil(SettingsDownloadableModels.preferredLanguage(forFilename: "does-not-exist.bin"))
    }

    // MARK: Task 5 — conditional model visibility
    private func makeLanguageModel(downloaded: Bool) -> SettingsDownloadableModel {
        SettingsDownloadableModel(
            name: "Turbo V3 Hebrew", isDownloaded: downloaded,
            url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin?download=true")!,
            size: 1, description: "d",
            filename: "ggml-ivrit-large-v3-turbo.bin", preferredLanguage: "he")
    }

    func testLanguageModelHiddenWhenNotDownloadedAndLanguageNotSelected() {
        let model = makeLanguageModel(downloaded: false)
        XCTAssertFalse(SettingsDownloadableModels.isVisible(model, selectedLanguage: "en", systemLanguage: "en"))
    }

    func testLanguageModelVisibleWhenSelectedLanguageMatches() {
        let model = makeLanguageModel(downloaded: false)
        XCTAssertTrue(SettingsDownloadableModels.isVisible(model, selectedLanguage: "he", systemLanguage: "en"))
    }

    func testLanguageModelVisibleWhenSystemLanguageMatches() {
        let model = makeLanguageModel(downloaded: false)
        XCTAssertTrue(SettingsDownloadableModels.isVisible(model, selectedLanguage: "en", systemLanguage: "he"))
    }

    func testLanguageModelVisibleWhenAlreadyDownloaded() {
        let model = makeLanguageModel(downloaded: true)
        XCTAssertTrue(SettingsDownloadableModels.isVisible(model, selectedLanguage: "en", systemLanguage: "en"))
    }

    func testStandardModelAlwaysVisible() {
        let model = SettingsDownloadableModel(
            name: "Turbo V3 large", isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
            size: 1, description: "d")
        XCTAssertTrue(SettingsDownloadableModels.isVisible(model, selectedLanguage: "en", systemLanguage: "en"))
    }

    // MARK: Task 6 — Hugging Face page URL
    func testHuggingFacePageURLForIvritModel() {
        let ivrit = SettingsDownloadableModels.availableModels.first {
            $0.filename == "ggml-ivrit-large-v3-turbo.bin"
        }
        XCTAssertEqual(
            ivrit?.huggingFacePageURL?.absoluteString,
            "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml")
    }

    func testHuggingFacePageURLForStandardModel() {
        let standard = SettingsDownloadableModels.availableModels.first {
            $0.filename == "ggml-large-v3-turbo.bin"
        }
        XCTAssertEqual(
            standard?.huggingFacePageURL?.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp")
    }
}

final class MouseButtonTests: XCTestCase {

    func testRawValueRoundTrips() {
        for button in MouseButton.allCases {
            XCTAssertEqual(MouseButton(rawValue: button.rawValue), button)
        }
    }

    func testUnknownRawValueDefaultsToNil() {
        XCTAssertNil(MouseButton(rawValue: "not-a-button"))
    }

    func testButtonNumberMapping() {
        // macOS numbers buttons from zero: 2 = middle, 3+ = extra (thumb) buttons.
        XCTAssertEqual(MouseButton.middle.buttonNumber, 2)
        XCTAssertEqual(MouseButton.button4.buttonNumber, 3)
        XCTAssertEqual(MouseButton.button5.buttonNumber, 4)
        XCTAssertEqual(MouseButton.button6.buttonNumber, 5)
    }

    func testNoneIsNotAValidButtonNumber() {
        XCTAssertEqual(MouseButton.none.buttonNumber, -1)
    }

    func testSelectableButtonsExcludeNone() {
        let selectable = MouseButton.allCases.filter { $0 != .none }
        XCTAssertFalse(selectable.contains(.none))
        XCTAssertEqual(selectable.count, 4)
        for button in selectable {
            XCTAssertFalse(button.displayName.isEmpty)
            XCTAssertFalse(button.shortSymbol.isEmpty)
        }
    }
}
