//
//  OpenDiskUITests.swift
//  OpenDiskUITests
//

import XCTest

final class OpenDiskUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Smoke test: the app launches, reaches the foreground, and shows its
    /// main window. Deliberately avoids querying specific UI elements so the
    /// test stays robust as the interface evolves.
    @MainActor
    func testAppLaunchesAndShowsMainWindow() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App should reach the foreground after launch"
        )
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 30),
            "Main window should appear after launch"
        )

        // Attach a screenshot so a failure elsewhere in the suite still
        // leaves evidence of what launch looked like.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
