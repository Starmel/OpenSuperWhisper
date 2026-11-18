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

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ObservableObject {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var copyTranscriptionItem: NSMenuItem?
    private var microphoneService = MicrophoneService.shared
    private var microphoneObserver: AnyCancellable?
    private var recordingRetentionTimer: Timer?
    private var hideMainWindowAtLaunch = false
    
    private var terminationTask: Task<Void, Never>?

    /// Set when Settings is asked for while the main window is not on screen.
    /// ContentView is what presents the sheet, and it does not exist until the
    /// window does, so the request is held until the window is key again.
    private var hasPendingSettingsRequest = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor in
            await TranscriptionService.shared.shutdown()
            await TranscriptionQueue.shared.stopProcessingQueue()
            TransformRuntime.shared.unload()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A paste delivery writes the transcript over the clipboard and puts the
        // previous contents back 1.5 s later, from a block inside this process. If
        // the process died inside that window, the contents are still on disk
        // (`ClipboardRecovery`) and this is where they come back — before anything
        // else in the app has a chance to put something else on the clipboard.
        // Nothing is pending in the ordinary case, so this is a file-existence
        // check on a normal launch; under test it is a no-op by construction (the
        // decision lives in `launchStep`, which a test drives for both branches —
        // this one line is verified by reading it, and the Readme says so).
        ClipboardRecovery.launchStep(isRunningTests: OpenSuperWhisperApp.isRunningTests)

        guard !OpenSuperWhisperApp.isRunningTests else {
            disableWindowFrameAutosave()
            return
        }

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
        menu.delegate = self
        
        menu.addItem(NSMenuItem(title: "OpenSuperWhisper", action: #selector(openApp), keyEquivalent: "o"))

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copyLastTranscription(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isHidden = true
        copyTranscriptionItem = copyItem
        menu.addItem(copyItem)
        
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

        // The status menu is the only way into Settings for a window that is
        // hidden or closed, so it needs the counterpart of the app menu's
        // Settings… item (see `openSettings(_:)`).
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let uninstallItem = NSMenuItem(
            title: "Uninstall OpenSuperWhisper…",
            action: #selector(uninstallApp(_:)),
            keyEquivalent: ""
        )
        uninstallItem.target = self
        menu.addItem(uninstallItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu, let item = copyTranscriptionItem else { return }
        item.isHidden = true
        item.representedObject = nil
        do {
            guard let transcription = try RecordingStore.shared.latestSuccessfulTranscription() else { return }
            let words = transcription.split(whereSeparator: { $0.isWhitespace })
            let beginning = words.prefix(6).joined(separator: " ")
            let preview = String(beginning.prefix(32))
                + (words.count > 6 || beginning.count > 32 ? "…" : "")
            let title = NSMutableAttributedString(string: "Copy")
            title.append(NSAttributedString(string: "\n\(preview)", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
            ]))
            item.attributedTitle = title
            item.representedObject = transcription
            item.isHidden = false
        } catch {
            AppErrorCenter.shared.report("Last transcription could not be loaded", error: error)
        }
    }

    @objc private func copyLastTranscription(_ sender: NSMenuItem) {
        guard let transcription = sender.representedObject as? String else { return }
        ClipboardUtil.copyToClipboard(transcription)
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

    /// The status menu's counterpart of the app menu's Settings… item. Unlike
    /// that one it cannot assume a window is on screen: ContentView is what
    /// presents the sheet, so the window is brought forward first and the
    /// notification is posted as soon as there is something to receive it.
    @objc private func openSettings(_ sender: Any?) {
        let windowWasOnScreen = mainWindow?.isVisible == true
        showMainWindow()

        if windowWasOnScreen {
            NotificationCenter.default.post(name: .openSettings, object: nil)
        } else {
            // Posted from anyWindowDidBecomeKey once the window is back.
            hasPendingSettingsRequest = true
        }
    }

    private func presentPendingSettingsRequest() {
        guard hasPendingSettingsRequest else { return }
        hasPendingSettingsRequest = false
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    /// The menu-bar entry point for the same operation Settings offers. A menu
    /// item cannot present a sheet, so the consequences are spelled out in an
    /// alert instead.
    @objc private func uninstallApp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Uninstall OpenSuperWhisper?"
        alert.informativeText = """
            This removes the app and everything it has stored on this Mac: your \
            dictation history, the downloaded speech and transform models, your \
            settings and the installer receipt. It cannot be undone.

            \(UninstallService.untouchedNote)
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try UninstallService.startUninstall(resetPermissions: false)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Uninstall failed"
            failure.informativeText = error.localizedDescription
            failure.alertStyle = .warning
            failure.runModal()
            return
        }
        NSApplication.shared.terminate(nil)
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
              Self.isMainAppWindow(window)
        else { return }

        if window !== mainWindow {
            adoptMainWindow(window)
        }

        presentPendingSettingsRequest()
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

    /// No window of a test process may autosave its frame.
    ///
    /// AppKit writes `NSWindow Frame <name>` into `UserDefaults.standard` — the
    /// domain the developer's own app reads, since the test bundle runs under the
    /// app's bundle id — for a window that carries a frame autosave name, on its
    /// own and with no test able to put the key back. The name SwiftUI gives the
    /// WindowGroup window is exactly the one production remembers the user's
    /// position under, and SwiftUI sets it after this method returns, so every
    /// window AppKit announces is cleared of it. Production keeps its name: the
    /// position he left his window in still persists.
    private func disableWindowFrameAutosave() {
        for window in NSApplication.shared.windows {
            window.setFrameAutosaveName("")
        }

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didUpdateNotification
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clearFrameAutosaveName(_:)),
                name: name,
                object: nil
            )
        }
    }

    @objc private func clearFrameAutosaveName(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !window.frameAutosaveName.isEmpty
        else { return }

        window.setFrameAutosaveName("")
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
