//
//  OpenSuperWhisperApp.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@main
struct OpenSuperWhisperApp: App {
    static let isRunningTests = NSClassFromString("XCTestCase") != nil

    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.isRunningTests {
                    EmptyView()
                } else if !appState.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    ContentView()
                }
            }
            .frame(width: 450)
            .frame(minHeight: 400, maxHeight: 900)
            .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 450, height: 650)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    if let delegate = NSApplication.shared.delegate as? AppDelegate {
                        delegate.showMainWindow()
                    }
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "openMainWindow"))
    }

    init() {
        guard !Self.isRunningTests else { return }
        _ = ShortcutManager.shared
        _ = MicrophoneService.shared
        WhisperModelManager.shared.ensureDefaultModelPresent()
    }
}

extension OpenSuperWhisperApp {
    static func startTranscriptionQueue() {
        Task { @MainActor in
            TranscriptionQueue.shared.startProcessingQueue()
        }
    }
}

class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            AppPreferences.shared.hasCompletedOnboarding = hasCompletedOnboarding
        }
    }

    init() {
        var onboarding = AppPreferences.shared.hasCompletedOnboarding
        #if DEBUG
        if let force = DevConfig.shared.forceShowOnboarding {
            onboarding = !force
        }
        #endif
        self.hasCompletedOnboarding = onboarding
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var languageSubmenu: NSMenu?
    private var microphoneService = MicrophoneService.shared
    private var microphoneObserver: AnyCancellable?
    private var recordingRetentionTimer: Timer?
    private var hideMainWindowAtLaunch = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !OpenSuperWhisperApp.isRunningTests else { return }

        setupStatusBarItem()

        // The WindowGroup window usually does not exist yet at this point:
        // SwiftUI creates it after applicationDidFinishLaunching, so it is
        // adopted lazily from windowDidBecomeKey instead.
        if let window = Self.resolveMainWindow() {
            adoptMainWindow(window)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        // SwiftUI owns the WindowGroup window and can replace its delegate,
        // so windowWillClose on AppDelegate is not guaranteed to fire. The
        // notification is delivered regardless of who the delegate is.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        let prefs = AppPreferences.shared
        if prefs.startHiddenInMenuBar && prefs.hasCompletedOnboarding {
            hideMainWindowAtLaunch = true
            mainWindow?.orderOut(nil)
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        OpenSuperWhisperApp.startTranscriptionQueue()
        observeMicrophoneChanges()
        
        IndicatorWindowManager.shared.warmUp()
        
        startRecordingRetentionSchedule()

        Task { @MainActor in
            await RecordingStore.shared.backfillMissingDurations()
        }
    }

    private func startRecordingRetentionSchedule() {
        cleanupOutdatedRecordings()
        
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.cleanupOutdatedRecordings()
        }
        timer.tolerance = 60 * 60
        recordingRetentionTimer = timer
    }

    private func cleanupOutdatedRecordings() {
        let prefs = AppPreferences.shared
        guard prefs.autoDeleteRecordingsEnabled else { return }
        let days = prefs.autoDeleteRecordingsAfterDays
        Task { @MainActor in
            try? await RecordingStore.shared.deleteRecordings(olderThanDays: days)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard isAudioFile(url) else {
            return false
        }

        queueAudioURLs([url])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let audioURLs = filenames
            .map { URL(fileURLWithPath: $0) }
            .filter { isAudioFile($0) }

        sender.reply(toOpenOrPrint: audioURLs.isEmpty ? .failure : .success)
        queueAudioURLs(audioURLs)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let audioURLs = urls.filter { isAudioFile($0) }
        queueAudioURLs(audioURLs)
    }

    private func queueAudioURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            showMainWindow()

            for url in urls {
                await TranscriptionQueue.shared.addFileToQueue(url: url)
            }
        }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType.conforms(to: .audio)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }
    
    private func observeMicrophoneChanges() {
        microphoneObserver = microphoneService.$availableMicrophones
            .sink { [weak self] _ in
                self?.updateStatusBarMenu()
            }
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            if let iconImage = NSImage(named: "tray_icon") {
                iconImage.size = NSSize(width: 48, height: 48)
                iconImage.isTemplate = true
                button.image = iconImage
            } else {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "OpenSuperWhisper")
            }
            
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
        }
        
        updateStatusBarMenu()
    }
    
    private func updateStatusBarMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "OpenSuperWhisper", action: #selector(openApp), keyEquivalent: "o"))
        
        let transcriptionLanguageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageSubmenu = NSMenu()
        
        if let languageSubmenu {
            populateLanguageSubmenu(languageSubmenu)
        }
        
        transcriptionLanguageItem.submenu = languageSubmenu
        menu.addItem(transcriptionLanguageItem)
        
        // Listen for language preference changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languagePreferenceChanged),
            name: .appPreferencesLanguageChanged,
            object: nil
        )
        
        menu.addItem(NSMenuItem.separator())
        
        let microphoneMenu = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        
        let microphones = microphoneService.availableMicrophones
        let currentMic = microphoneService.currentMicrophone
        
        if microphones.isEmpty {
            let noDeviceItem = NSMenuItem(title: "No microphones available", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            submenu.addItem(noDeviceItem)
        } else {
            let builtInMicrophones = microphones.filter { $0.isBuiltIn }
            let externalMicrophones = microphones.filter { !$0.isBuiltIn }
            
            for microphone in builtInMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                
                if let current = currentMic, current.id == microphone.id {
                    item.state = .on
                }
                
                submenu.addItem(item)
            }
            
            if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                submenu.addItem(NSMenuItem.separator())
            }
            
            for microphone in externalMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                
                if let current = currentMic, current.id == microphone.id {
                    item.state = .on
                }
                
                submenu.addItem(item)
            }
        }
        
        microphoneMenu.submenu = submenu
        menu.addItem(microphoneMenu)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? MicrophoneService.AudioDevice else { return }
        microphoneService.selectMicrophone(device)
        updateStatusBarMenu()
    }
    
    @objc private func statusBarButtonClicked(_ sender: Any) {
        statusItem?.button?.performClick(nil)
    }
    
    @objc private func openApp() {
        showMainWindow()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let languageCode = sender.representedObject as? String else { return }
        
        // Update preferences
        AppPreferences.shared.whisperLanguage = languageCode
        
        // Update menu item states
        if let submenu = sender.menu {
            for item in submenu.items {
                item.state = .off
            }
            sender.state = .on
        }
    }
    
    @objc private func languagePreferenceChanged() {
        updateLanguageMenuSelection()
    }
    
    private func updateLanguageMenuSelection() {
        guard let languageSubmenu = languageSubmenu else { return }
        populateLanguageSubmenu(languageSubmenu)
    }
    
    private func populateLanguageSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()
        
        let supportedLanguages = LanguageUtil.supportedLanguages(
            engine: AppPreferences.shared.selectedEngine,
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion
        )
        let currentLanguage = AppPreferences.shared.whisperLanguage
        
        for languageCode in supportedLanguages {
            let languageName = LanguageUtil.languageNames[languageCode] ?? languageCode
            let languageItem = NSMenuItem(title: languageName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            languageItem.target = self
            languageItem.representedObject = languageCode
            languageItem.state = (currentLanguage == languageCode) ? .on : .off
            submenu.addItem(languageItem)
        }
    }
    
    /// The WindowGroup window must be told apart from the other windows the
    /// app creates: the status item's NSStatusBarWindow, the borderless
    /// indicator NSPanel and SwiftUI sheet host windows.
    static func isMainAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && !window.isSheet && window.styleMask.contains(.titled)
    }

    private static func resolveMainWindow() -> NSWindow? {
        NSApplication.shared.windows.first(where: isMainAppWindow)
    }

    /// SwiftUI creates the WindowGroup window after applicationDidFinishLaunching
    /// and can recreate it later, so the reference is (re)captured whenever a
    /// main-type window becomes key.
    @objc private func anyWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              Self.isMainAppWindow(window),
              window !== mainWindow
        else { return }
        adoptMainWindow(window)
    }

    private func adoptMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.delegate = self
        window.minSize = NSSize(width: 450, height: 400)
        window.maxSize = NSSize(width: 450, height: 900)

        if hideMainWindowAtLaunch {
            hideMainWindowAtLaunch = false
            window.orderOut(nil)
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    @objc private func anyWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, Self.isMainAppWindow(closing) else { return }
        // Deferred so the check runs after the window has actually closed.
        DispatchQueue.main.async {
            let anyMainWindowVisible = NSApplication.shared.windows.contains {
                $0 !== closing && Self.isMainAppWindow($0) && $0.isVisible
            }
            if !anyMainWindowVisible {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }

    func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)

        if mainWindow == nil {
            mainWindow = Self.resolveMainWindow()
        }

        if let window = mainWindow {
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            let url = URL(string: "openSuperWhisper://openMainWindow")!
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        return NSSize(width: 450, height: frameSize.height)
    }
}
