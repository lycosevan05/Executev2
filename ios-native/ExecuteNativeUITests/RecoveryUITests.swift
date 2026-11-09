import XCTest

@MainActor
final class RecoveryUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-execute-recovery-preview"] + arguments
        app.launch()
        return app
    }
    private func tap(_ id: String, app: XCUIApplication) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        for _ in 0..<16 {
            let frame = button.frame
            if button.isHittable && frame.midY > 80 && frame.maxY < app.frame.maxY - 110 { break }
            if id.hasPrefix("recovery.tab.") { app.swipeDown() } else { app.swipeUp() }
        }
        button.tap()
    }
    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testProductionHomeRouteOpensRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["-execute-recovery-ui-tests"]
        app.launch()
        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 10))
        let recovery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recovery")).firstMatch
        for _ in 0..<12 {
            let frame = recovery.frame
            if recovery.isHittable && frame.minY > 150 && frame.maxY < app.frame.maxY - 140 { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: frame.minY < 150 ? 0.72 : 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(recovery.exists)
        screenshot("Home Recovery action before navigation (fixture)", app: app)
        recovery.tap()
        XCTAssertTrue(app.navigationBars["Recovery"].waitForExistence(timeout: 10))
        for _ in 0..<3 where !app.sliders["recovery.input.Energy Level"].exists { app.swipeUp() }
        XCTAssertTrue(app.sliders["recovery.input.Energy Level"].waitForExistence(timeout: 10))
        screenshot("Recovery production route with fixture services", app: app)
    }
    func testAccessibilityTextLayout() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.sliders["recovery.input.Energy Level"].waitForExistence(timeout: 10))
        screenshot("Recovery accessibility text fixture", app: app)
        tap("recovery.save", app: app)
        XCTAssertTrue(app.staticTexts["Check-in saved."].waitForExistence(timeout: 10))
    }
    func testCheckInGuidanceEditAndTasks() {
        let app = launch()
        XCTAssertTrue(app.sliders["recovery.input.Energy Level"].waitForExistence(timeout: 10))
        screenshot("Recovery check-in fixture", app: app)
        tap("recovery.save", app: app)
        XCTAssertTrue(app.staticTexts["Check-in saved."].waitForExistence(timeout: 10))
        tap("recovery.task.mobility", app: app)
        XCTAssertEqual(app.buttons["recovery.task.mobility"].value as? String, "Completed")
        screenshot("Recovery guidance fixture", app: app)
        tap("recovery.tab.Check-In", app: app)
        tap("recovery.edit", app: app)
        XCTAssertTrue(app.sliders["recovery.input.Energy Level"].waitForExistence(timeout: 5))
    }
    func testLimitationsAddAndArchive() {
        let app = launch()
        tap("recovery.tab.Limitations", app: app)
        tap("recovery.addLimitation", app: app)
        tap("recovery.limitation.save", app: app)
        XCTAssertTrue(app.switches["recovery.limitation.active"].waitForExistence(timeout: 5))
        screenshot("Recovery limitations fixture", app: app)
        app.buttons["Archive limitation"].tap()
        XCTAssertTrue(app.staticTexts["Inactive · retained in your history"].waitForExistence(timeout: 5))
    }
    func testGuidanceFailureRetainsCheckInAndRetry() {
        let app = launch(["-execute-recovery-guidance-failure"])
        tap("recovery.save", app: app)
        XCTAssertTrue(app.staticTexts["Guidance offline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Check-in saved."].exists)
        screenshot("Recovery guidance retry fixture", app: app)
        XCTAssertTrue(app.buttons["Try again"].exists)
    }
    func testMyWeekSourceShowsTasksWithoutCheckIn() {
        let app = launch(["-execute-recovery-my-week"])
        XCTAssertTrue(app.buttons["recovery.task.mobility"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Log Readiness"].exists)
    }
}
