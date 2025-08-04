//
//  SettingsUITests.swift
//  OpenSuperWhisperUITests
//
//  Created by user on 05.02.2025.
//

import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        
        app = XCUIApplication()
        app.launchEnvironment["UITEST_MODE"] = "1"
        app.launch()
        
        // Wait for app to fully load
        _ = app.wait(for: .runningForeground, timeout: 5.0)
    }

    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - Helper Methods
    
    private func openSettings() {
        // Look for settings menu item in menu bar or right-click menu
        let menuBarItem = app.menuBarItems.firstMatch
        if menuBarItem.exists {
            menuBarItem.click()
            
            // Look for Settings menu item
            let settingsMenuItem = app.menuItems["Settings"]
            if settingsMenuItem.exists {
                settingsMenuItem.click()
            } else {
                // Try alternative menu structure
                let preferencesMenuItem = app.menuItems["Preferences"]
                if preferencesMenuItem.exists {
                    preferencesMenuItem.click()
                }
            }
        }
        
        // Wait for settings window to appear
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3.0), "Settings window should appear")
    }
    
    private func selectTab(_ tabName: String) {
        let tab = app.buttons[tabName]
        XCTAssertTrue(tab.exists, "Tab '\(tabName)' should exist")
        tab.click()
        
        // Wait a moment for tab transition
        Thread.sleep(forTimeInterval: 0.3)
    }
    
    // MARK: - Settings Window Tests
    
    func testSettingsWindowOpens() throws {
        openSettings()
        
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.exists, "Settings window should be visible")
        
        // Check that Done button exists
        let doneButton = settingsWindow.buttons["Done"]
        XCTAssertTrue(doneButton.exists, "Done button should exist")
    }
    
    func testAllTabsExist() throws {
        openSettings()
        let settingsWindow = app.windows["Settings"]
        
        // Check all expected tabs exist
        let expectedTabs = ["Shortcuts", "Provider", "Model", "Transcription", "Text Enhancement", "Advanced"]
        
        for tabName in expectedTabs {
            let tab = settingsWindow.buttons[tabName]
            XCTAssertTrue(tab.exists, "Tab '\(tabName)' should exist")
        }
    }
    
    func testTabNavigation() throws {
        openSettings()
        let settingsWindow = app.windows["Settings"]
        
        let tabs = ["Shortcuts", "Provider", "Model", "Transcription", "Text Enhancement", "Advanced"]
        
        for tabName in tabs {
            selectTab(tabName)
            
            // Verify tab is selected by checking for tab-specific content
            switch tabName {
            case "Shortcuts":
                XCTAssertTrue(settingsWindow.staticTexts["Recording Shortcut"].exists, 
                             "Shortcuts tab content should be visible")
            case "Provider":
                XCTAssertTrue(settingsWindow.staticTexts["Speech-to-Text Provider"].exists, 
                             "Provider tab content should be visible")
            case "Model":
                XCTAssertTrue(settingsWindow.staticTexts["Whisper Model"].exists, 
                             "Model tab content should be visible")
            case "Transcription":
                XCTAssertTrue(settingsWindow.staticTexts["Language Settings"].exists, 
                             "Transcription tab content should be visible")
            case "Text Enhancement":
                XCTAssertTrue(settingsWindow.staticTexts["Text Enhancement"].exists, 
                             "Text Enhancement tab content should be visible")
            case "Advanced":
                XCTAssertTrue(settingsWindow.staticTexts["Decoding Strategy"].exists, 
                             "Advanced tab content should be visible")
            default:
                break
            }
        }
    }
    
    // MARK: - Shortcuts Tab Tests
    
    func testShortcutsTabContent() throws {
        openSettings()
        selectTab("Shortcuts")
        
        let settingsWindow = app.windows["Settings"]
        
        // Check for key UI elements
        XCTAssertTrue(settingsWindow.staticTexts["Recording Shortcut"].exists)
        XCTAssertTrue(settingsWindow.staticTexts["Toggle record:"].exists)
        XCTAssertTrue(settingsWindow.checkBoxes["Play sound when recording starts"].exists)
        XCTAssertTrue(settingsWindow.staticTexts["Instructions"].exists)
    }
    
    func testPlaySoundToggle() throws {
        openSettings()
        selectTab("Shortcuts")
        
        let settingsWindow = app.windows["Settings"]
        let playSoundToggle = settingsWindow.checkBoxes["Play sound when recording starts"]
        
        XCTAssertTrue(playSoundToggle.exists, "Play sound toggle should exist")
        
        // Test toggling the switch
        let initialState = playSoundToggle.value as? Bool ?? false
        playSoundToggle.click()
        
        // Wait for state change
        Thread.sleep(forTimeInterval: 0.2)
        
        let newState = playSoundToggle.value as? Bool ?? false
        XCTAssertNotEqual(initialState, newState, "Toggle state should change")
    }
    
    // MARK: - Provider Tab Tests
    
    func testProviderTabContent() throws {
        openSettings()
        selectTab("Provider")
        
        let settingsWindow = app.windows["Settings"]
        
        // Check for key UI elements
        XCTAssertTrue(settingsWindow.staticTexts["Speech-to-Text Provider"].exists)
        XCTAssertTrue(settingsWindow.staticTexts["Primary Provider"].exists)
        XCTAssertTrue(settingsWindow.popUpButtons.firstMatch.exists, "Provider picker should exist")
        XCTAssertTrue(settingsWindow.checkBoxes["Enable Fallback to Local Provider"].exists)
    }
    
    func testProviderSelection() throws {
        openSettings()
        selectTab("Provider")
        
        let settingsWindow = app.windows["Settings"]
        let providerPicker = settingsWindow.popUpButtons.firstMatch
        
        XCTAssertTrue(providerPicker.exists, "Provider picker should exist")
        
        // Click to open dropdown
        providerPicker.click()
        
        // Check that menu items exist
        let menu = app.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 1.0), "Provider menu should appear")
        
        // Close menu by clicking away
        settingsWindow.click()
    }
    
    func testFallbackToggle() throws {
        openSettings()
        selectTab("Provider")
        
        let settingsWindow = app.windows["Settings"]
        let fallbackToggle = settingsWindow.checkBoxes["Enable Fallback to Local Provider"]
        
        XCTAssertTrue(fallbackToggle.exists, "Fallback toggle should exist")
        
        // Test toggling
        let initialState = fallbackToggle.value as? Bool ?? false
        fallbackToggle.click()
        
        Thread.sleep(forTimeInterval: 0.2)
        
        let newState = fallbackToggle.value as? Bool ?? false
        XCTAssertNotEqual(initialState, newState, "Fallback toggle state should change")
    }
    
    // MARK: - Model Tab Tests
    
    func testModelTabContent() throws {
        openSettings()
        selectTab("Model")
        
        let settingsWindow = app.windows["Settings"]
        
        // Check for key UI elements
        XCTAssertTrue(settingsWindow.staticTexts["Whisper Model"].exists)
        XCTAssertTrue(settingsWindow.popUpButtons.firstMatch.exists, "Model picker should exist")
        XCTAssertTrue(settingsWindow.staticTexts["Models Directory:"].exists)
        XCTAssertTrue(settingsWindow.buttons["Open Folder"].exists)
    }
    
    func testOpenModelsFolder() throws {
        openSettings()
        selectTab("Model")
        
        let settingsWindow = app.windows["Settings"]
        let openFolderButton = settingsWindow.buttons["Open Folder"]
        
        XCTAssertTrue(openFolderButton.exists, "Open folder button should exist")
        
        // Click the button (this will open Finder, which we can't easily test)
        openFolderButton.click()
        
        // Just verify the button is clickable
        XCTAssertTrue(openFolderButton.exists, "Button should still exist after clicking")
    }
    
    // MARK: - Transcription Tab Tests
    
    func testTranscriptionTabContent() throws {
        openSettings()
        selectTab("Transcription")
        
        let settingsWindow = app.windows["Settings"]
        
        // Check for key sections
        XCTAssertTrue(settingsWindow.staticTexts["Language Settings"].exists)
        XCTAssertTrue(settingsWindow.staticTexts["Output Options"].exists)
        XCTAssertTrue(settingsWindow.staticTexts["Initial Prompt"].exists)
        XCTAssertTrue(settingsWindow.staticTexts["Transcriptions Directory"].exists)
    }
    
    func testLanguageSelection() throws {
        openSettings()
        selectTab("Transcription")
        
        let settingsWindow = app.windows["Settings"]
        let languagePicker = settingsWindow.popUpButtons.firstMatch
        
        XCTAssertTrue(languagePicker.exists, "Language picker should exist")
        
        // Test opening the picker
        languagePicker.click()
        
        let menu = app.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 1.0), "Language menu should appear")
        
        // Close menu
        settingsWindow.click()
    }
    
    func testOutputOptionsToggles() throws {
        openSettings()
        selectTab("Transcription")
        
        let settingsWindow = app.windows["Settings"]
        
        // Test Show Timestamps toggle
        let timestampsToggle = settingsWindow.checkBoxes["Show Timestamps"]
        XCTAssertTrue(timestampsToggle.exists, "Timestamps toggle should exist")
        
        let initialTimestampsState = timestampsToggle.value as? Bool ?? false
        timestampsToggle.click()
        Thread.sleep(forTimeInterval: 0.2)
        let newTimestampsState = timestampsToggle.value as? Bool ?? false
        XCTAssertNotEqual(initialTimestampsState, newTimestampsState)
        
        // Test Suppress Blank Audio toggle
        let suppressToggle = settingsWindow.checkBoxes["Suppress Blank Audio"]
        XCTAssertTrue(suppressToggle.exists, "Suppress blank audio toggle should exist")
        
        let initialSuppressState = suppressToggle.value as? Bool ?? false
        suppressToggle.click()
        Thread.sleep(forTimeInterval: 0.2)
        let newSuppressState = suppressToggle.value as? Bool ?? false
        XCTAssertNotEqual(initialSuppressState, newSuppressState)
    }
    
    func testTranslateToEnglishToggle() throws {
        openSettings()
        selectTab("Transcription")
        
        let settingsWindow = app.windows["Settings"]
        let translateToggle = settingsWindow.checkBoxes["Translate to English"]
        
        XCTAssertTrue(translateToggle.exists, "Translate to English toggle should exist")
        
        let initialState = translateToggle.value as? Bool ?? false
        translateToggle.click()
        Thread.sleep(forTimeInterval: 0.2)
        let newState = translateToggle.value as? Bool ?? false
        XCTAssertNotEqual(initialState, newState)
    }
    
    // MARK: - Text Enhancement Tab Tests
    
    func testTextEnhancementTabContent() throws {
        openSettings()
        selectTab("Text Enhancement")
        
        let settingsWindow = app.windows["Settings"]
        
        // Check for main toggle
        XCTAssertTrue(settingsWindow.checkBoxes["Enable Text Enhancement"].exists)
        XCTAssertTrue(settingsWindow.staticTexts["Text Enhancement"].exists)
    }
    
    func testTextEnhancementToggle() throws {
        openSettings()
        selectTab("Text Enhancement")
        
        let settingsWindow = app.windows["Settings"]
        let enhancementToggle = settingsWindow.checkBoxes["Enable Text Enhancement"]
        
        XCTAssertTrue(enhancementToggle.exists, "Text enhancement toggle should exist")
        
        // Test toggling
        let initialState = enhancementToggle.value as? Bool ?? false
        enhancementToggle.click()
        Thread.sleep(forTimeInterval: 0.5) // Wait for UI updates
        
        let newState = enhancementToggle.value as? Bool ?? false
        XCTAssertNotEqual(initialState, newState, "Enhancement toggle state should change")
        
        // Check if additional settings appear when enabled
        if newState {
            XCTAssertTrue(settingsWindow.staticTexts["OpenRouter Configuration"].waitForExistence(timeout: 2.0),
                         "Configuration section should appear when enabled")
        }
    }
    
    // MARK: - Advanced Tab Tests
    
    func testAdvancedTabContent() throws {
        openSettings()
        selectTab("Advanced")
        
        let settingsWindow = app.windows["Settings"]
        
        // Check for key sections
        XCTAssertTrue(settingsWindow.staticTexts["Decoding Strategy"].exists)
        XCTAssertTrue(settingsWindow.staticTexts["Model Parameters"].exists)
        XCTAssertTrue(settingsWindow.staticTexts["Debug Options"].exists)
    }
    
    func testBeamSearchToggle() throws {
        openSettings()
        selectTab("Advanced")
        
        let settingsWindow = app.windows["Settings"]
        let beamSearchToggle = settingsWindow.checkBoxes["Use Beam Search"]
        
        XCTAssertTrue(beamSearchToggle.exists, "Beam search toggle should exist")
        
        let initialState = beamSearchToggle.value as? Bool ?? false
        beamSearchToggle.click()
        Thread.sleep(forTimeInterval: 0.3)
        
        let newState = beamSearchToggle.value as? Bool ?? false
        XCTAssertNotEqual(initialState, newState, "Beam search toggle state should change")
        
        // Check if beam size controls appear when enabled
        if newState {
            let beamSizeLabel = settingsWindow.staticTexts["Beam Size:"]
            XCTAssertTrue(beamSizeLabel.waitForExistence(timeout: 1.0), 
                         "Beam size controls should appear when beam search is enabled")
        }
    }
    
    func testTemperatureSlider() throws {
        openSettings()
        selectTab("Advanced")
        
        let settingsWindow = app.windows["Settings"]
        let temperatureSlider = settingsWindow.sliders.firstMatch
        
        XCTAssertTrue(temperatureSlider.exists, "Temperature slider should exist")
        
        // Test slider interaction
        let initialValue = temperatureSlider.value
        temperatureSlider.adjust(toNormalizedSliderPosition: 0.5)
        Thread.sleep(forTimeInterval: 0.2)
        
        let newValue = temperatureSlider.value
        // Values might be slightly different due to step increments
        XCTAssertNotEqual(initialValue, newValue, "Slider value should change")
    }
    
    func testDebugModeToggle() throws {
        openSettings()
        selectTab("Advanced")
        
        let settingsWindow = app.windows["Settings"]
        let debugToggle = settingsWindow.checkBoxes["Debug Mode"]
        
        XCTAssertTrue(debugToggle.exists, "Debug mode toggle should exist")
        
        let initialState = debugToggle.value as? Bool ?? false
        debugToggle.click()
        Thread.sleep(forTimeInterval: 0.2)
        
        let newState = debugToggle.value as? Bool ?? false
        XCTAssertNotEqual(initialState, newState, "Debug mode toggle state should change")
    }
    
    // MARK: - Settings Persistence Tests
    
    func testSettingsPersistAfterReopen() throws {
        openSettings()
        
        // Change a setting
        selectTab("Transcription")
        let settingsWindow = app.windows["Settings"]
        let timestampsToggle = settingsWindow.checkBoxes["Show Timestamps"]
        let initialState = timestampsToggle.value as? Bool ?? false
        timestampsToggle.click()
        
        // Close settings
        let doneButton = settingsWindow.buttons["Done"]
        doneButton.click()
        
        // Reopen settings
        openSettings()
        selectTab("Transcription")
        
        // Check that setting persisted
        let reopenedWindow = app.windows["Settings"]
        let reopenedToggle = reopenedWindow.checkBoxes["Show Timestamps"]
        let newState = reopenedToggle.value as? Bool ?? false
        
        XCTAssertNotEqual(initialState, newState, "Setting should persist after reopening")
        
        // Reset to original state
        if newState != initialState {
            reopenedToggle.click()
        }
    }
    
    // MARK: - Performance Tests
    
    func testTabSwitchingPerformance() throws {
        openSettings()
        
        let tabs = ["Shortcuts", "Provider", "Model", "Transcription", "Text Enhancement", "Advanced"]
        
        measure {
            for _ in 0..<3 { // Multiple iterations
                for tabName in tabs {
                    selectTab(tabName)
                }
            }
        }
    }
    
    func testSettingsWindowOpenPerformance() throws {
        measure {
            openSettings()
            
            let settingsWindow = app.windows["Settings"]
            let doneButton = settingsWindow.buttons["Done"]
            doneButton.click()
            
            // Wait for window to close
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}