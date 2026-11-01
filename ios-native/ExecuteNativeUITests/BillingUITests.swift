import XCTest

@MainActor
final class BillingUITests: XCTestCase {
    private func launch(restorable: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-execute-billing-ui-tests"]
        if restorable { app.launchArguments.append("-execute-restore-entitled") }
        app.launch()
        return app
    }

    func testProfileOpensBillingAndPurchaseUpdatesMembership() {
        let app = launch()
        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 10))
        app.buttons["Profile"].tap()
        let upgrade = app.buttons["profile.billing"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 5))
        upgrade.tap()
        let annual = app.buttons["billing.plan.annual"]
        XCTAssertTrue(annual.waitForExistence(timeout: 5))
        annual.tap()
        let purchase = app.buttons["billing.subscribe"]
        if !purchase.isHittable { app.swipeUp() }
        purchase.tap()
        XCTAssertTrue(app.staticTexts["Premium active"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Billing purchase confirmed (mock)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNutritionOpensBillingAndRestoreUpdatesMembership() {
        let app = launch(restorable: true)
        XCTAssertTrue(app.buttons["Nutrition"].waitForExistence(timeout: 10))
        app.buttons["Nutrition"].tap()
        let ai = app.buttons["nutrition.aiLog"]
        XCTAssertTrue(ai.waitForExistence(timeout: 5))
        if !ai.isHittable { app.swipeUp() }
        ai.tap()
        XCTAssertTrue(app.buttons["billing.plan.monthly"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Billing monthly and annual options (mock)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let restore = app.buttons["billing.restore"]
        if !restore.isHittable { app.swipeUp() }
        restore.tap()
        XCTAssertTrue(app.staticTexts["Premium active"].waitForExistence(timeout: 5))
    }

    func testLegalDestinationsAndEmptyRestore() {
        let app = launch()
        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 10))
        app.buttons["Profile"].tap()
        app.buttons["profile.billing"].tap()
        let restore = app.buttons["billing.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        app.swipeUp()
        restore.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "No active App Store subscription")).firstMatch.waitForExistence(timeout: 5))
        app.swipeUp()
        app.buttons["billing.privacy"].tap()
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.swipeUp()
        app.buttons["billing.terms"].tap()
        XCTAssertTrue(app.navigationBars["Terms of Use"].waitForExistence(timeout: 5))
    }
}
