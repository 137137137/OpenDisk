import XCTest

final class OpenDiskUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

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

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
