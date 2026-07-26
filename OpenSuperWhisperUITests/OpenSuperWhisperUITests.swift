//
//  OpenSuperWhisperUITests.swift
//  OpenSuperWhisperUITests
//
//  Created by user on 05.02.2025.
//

import XCTest

final class OpenSuperWhisperUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testLaunchShowsMainWindow() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(
                app.wait(for: .notRunning, timeout: 2),
                "An existing application instance must terminate before the launch regression runs"
            )
        }
        app.launchArguments = [
            "-hasCompletedOnboarding", "0",
            "-startHiddenInMenuBar", "0",
        ]
        app.launch()

        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 5),
            "The application window must appear instead of blocking during application initialization"
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
