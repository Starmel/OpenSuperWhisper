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

final class CustomDictionaryTests: XCTestCase {

    private func entry(_ original: String, _ replacement: String) -> CustomDictionaryEntry {
        CustomDictionaryEntry(original: original, replacement: replacement)
    }

    func testApply_replacesWholeWordCaseInsensitively() {
        let result = CustomDictionary.apply(
            "I pushed it to git hub yesterday.",
            entries: [entry("git hub", "GitHub")]
        )
        XCTAssertEqual(result, "I pushed it to GitHub yesterday.")
    }

    func testApply_doesNotReplaceInsideLargerWord() {
        let result = CustomDictionary.apply(
            "The category was clear.",
            entries: [entry("cat", "dog")]
        )
        XCTAssertEqual(result, "The category was clear.")
    }

    func testApply_matchesRegardlessOfInputCasing() {
        let result = CustomDictionary.apply(
            "GIT HUB and Git Hub and git hub",
            entries: [entry("git hub", "GitHub")]
        )
        XCTAssertEqual(result, "GitHub and GitHub and GitHub")
    }

    func testApply_handlesTermsWithPunctuation() {
        let result = CustomDictionary.apply(
            "I prefer c plus plus.",
            entries: [entry("c plus plus", "C++")]
        )
        XCTAssertEqual(result, "I prefer C++.")
    }

    func testApply_treatsReplacementAsLiteralText() {
        // Replacement contains regex-significant characters; must not be interpreted.
        let result = CustomDictionary.apply(
            "ping the channel",
            entries: [entry("channel", "#general $1")]
        )
        XCTAssertEqual(result, "ping the #general $1")
    }

    func testApply_appliesMultipleEntriesInOrder() {
        let result = CustomDictionary.apply(
            "open super whisper uses whisper cpp",
            entries: [
                entry("open super whisper", "OpenSuperWhisper"),
                entry("whisper cpp", "whisper.cpp")
            ]
        )
        XCTAssertEqual(result, "OpenSuperWhisper uses whisper.cpp")
    }

    func testApply_ignoresEmptyOriginalAndIsNoOpWithoutEntries() {
        XCTAssertEqual(CustomDictionary.apply("hello", entries: []), "hello")
        XCTAssertEqual(
            CustomDictionary.apply("hello", entries: [entry("   ", "x")]),
            "hello"
        )
        XCTAssertEqual(CustomDictionary.apply("", entries: [entry("a", "b")]), "")
    }

    func testPromptBoost_joinsUniqueReplacements() {
        let boost = CustomDictionary.promptBoost(entries: [
            entry("git hub", "GitHub"),
            entry("g hub", "GitHub"),
            entry("open super whisper", "OpenSuperWhisper"),
            entry("noise", "  ")
        ])
        XCTAssertEqual(boost, "GitHub, OpenSuperWhisper")
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
    
    func testBluetoothDetection_MACAddress() throws {
        let device = MicrophoneService.AudioDevice(
            id: "00-22-BB-71-21-0A:input",
            name: "Amiron wireless",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        // A bare MAC-address UID is only classified by querying the live CoreAudio transport type,
        // so the assertion is meaningful only when that physical device is connected — otherwise
        // skip rather than fail, which is what made this flaky in headless CI (#157).
        try XCTSkipUnless((MicrophoneService.shared.getCoreAudioDeviceID(for: device) ?? 0) != 0,
                          "Requires the physical Bluetooth device to be connected")
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
    
    func testRequiresConnection_Bluetooth() throws {
        let device = MicrophoneService.AudioDevice(
            id: "00-22-BB-71-21-0A:input",
            name: "Amiron wireless",
            manufacturer: "Apple",
            isBuiltIn: false
        )
        // Classified via the live CoreAudio transport type — only meaningful with the physical
        // device connected; skip rather than fail when it isn't (#157).
        try XCTSkipUnless((MicrophoneService.shared.getCoreAudioDeviceID(for: device) ?? 0) != 0,
                          "Requires the physical Bluetooth device to be connected")
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

// MARK: - Engine Capabilities Tests

final class EngineCapabilitiesTests: XCTestCase {
    func testTranslation_whisperAlwaysSupported() {
        XCTAssertTrue(EngineCapabilities.supportsTranslation(engine: "whisper", groqModel: "anything"))
    }

    func testTranslation_groqOnlyOnLargeV3() {
        XCTAssertTrue(EngineCapabilities.supportsTranslation(engine: "groq", groqModel: "whisper-large-v3"))
        XCTAssertFalse(EngineCapabilities.supportsTranslation(engine: "groq", groqModel: "whisper-large-v3-turbo"))
    }

    func testTranslation_parakeetAndSenseVoiceNever() {
        XCTAssertFalse(EngineCapabilities.supportsTranslation(engine: "fluidaudio", groqModel: ""))
        XCTAssertFalse(EngineCapabilities.supportsTranslation(engine: "sensevoice", groqModel: ""))
    }

    func testLanguages_parakeetV2IsEnglishOnly() {
        XCTAssertEqual(EngineCapabilities.supportedLanguages(engine: "fluidaudio", fluidAudioModelVersion: "v2"), ["en"])
    }

    func testLanguages_parakeetV3IsMultilingual() {
        let langs = EngineCapabilities.supportedLanguages(engine: "fluidaudio", fluidAudioModelVersion: "v3")
        XCTAssertGreaterThan(langs.count, 1)
        XCTAssertTrue(langs.contains("fr"))
    }

    func testLanguages_senseVoiceLimitedSet() {
        XCTAssertEqual(EngineCapabilities.supportedLanguages(engine: "sensevoice", fluidAudioModelVersion: ""),
                       ["auto", "zh", "en", "ja", "ko", "yue"])
    }

    func testLanguages_whisperUsesFullSet() {
        XCTAssertEqual(EngineCapabilities.supportedLanguages(engine: "whisper", fluidAudioModelVersion: ""),
                       LanguageUtil.availableLanguages)
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
    func testHebrewIsAvailableLanguage() {
        XCTAssertTrue(LanguageUtil.availableLanguages.contains("he"))
        XCTAssertEqual(LanguageUtil.languageNames["he"], "Hebrew")
    }

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

    func testIvritModelIsAvailableWithCorrectMetadata() {
        let ivrit = SettingsDownloadableModels.availableModels.first {
            $0.filename == "ggml-ivrit-large-v3-turbo.bin"
        }
        XCTAssertNotNil(ivrit)
        XCTAssertEqual(ivrit?.preferredLanguage, "he")
        XCTAssertTrue(ivrit?.url.absoluteString.contains("ivrit-ai/whisper-large-v3-turbo-ggml") ?? false)
    }

    func testPreferredLanguageLookupByFilename() {
        XCTAssertEqual(
            SettingsDownloadableModels.preferredLanguage(forFilename: "ggml-ivrit-large-v3-turbo.bin"), "he")
        XCTAssertNil(
            SettingsDownloadableModels.preferredLanguage(forFilename: "ggml-large-v3-turbo.bin"))
    }
}
