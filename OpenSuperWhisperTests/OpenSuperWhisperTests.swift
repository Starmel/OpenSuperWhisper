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
