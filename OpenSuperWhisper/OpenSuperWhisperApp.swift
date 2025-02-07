//
//  OpenSuperWhisperApp.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import SwiftUI

@main
struct OpenSuperWhisperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 400, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

    }

    init() {
        // Request microphone access on app launch
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        _ = ShortcutManager.shared
    }
}
