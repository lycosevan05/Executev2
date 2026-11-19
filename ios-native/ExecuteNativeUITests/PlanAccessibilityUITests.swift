import XCTest

@MainActor
final class HostedAIConsentSettingsUITests: XCTestCase {
    func testSignedReviewerCanDeclineAllowAndTurnOffAISharing() throws {
        guard let email = ProcessInfo.processInfo.environment["EXECUTE_AI_CONSENT_REVIEWER_EMAIL"],
              email == "app-review-ios-1-0@executelabs.ca" else {
            throw XCTSkip("Requires the approved synthetic reviewer session")
        }

        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let profile = app.buttons["Profile"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        profile.tap()
        XCTAssertTrue(app.staticTexts[email].firstMatch.waitForExistence(timeout: 10))

        let sharing = app.buttons["profile.ai-data-sharing"]
        for _ in 0..<6 where !sharing.isHittable { app.swipeUp() }
        XCTAssertTrue(sharing.isHittable)
        XCTAssertTrue(sharing.label.contains("Sharing with OpenAI is off"))

        sharing.tap()
        let disclosure = app.alerts["Allow AI Data Sharing?"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        let openAIDisclosure = disclosure.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "OpenAI")).firstMatch
        XCTAssertTrue(openAIDisclosure.exists)
        disclosure.buttons["Don't Allow"].tap()
        XCTAssertTrue(sharing.label.contains("Sharing with OpenAI is off"))

        sharing.tap()
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.buttons["Allow Sharing"].tap()
        XCTAssertTrue(sharing.label.contains("Turn Off AI Data Sharing"))
        sharing.tap()
        XCTAssertTrue(sharing.label.contains("Sharing with OpenAI is off"))
    }
}

@MainActor
final class PlanAccessibilityUITests: XCTestCase {
    func testLargestTextLetsPlanHeaderScrollAndBlueprintOpen() {
        let app = launchLargestTextPreview("-execute-plan-preview")

        let title = app.staticTexts["Your Performance Plan"]
        let refresh = app.buttons["Refresh plan"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(refresh.isHittable)
        XCTAssertGreaterThan(title.frame.height, 80)
        attachScreenshot("Plan header at largest accessibility text", app: app)

        let blueprint = app.buttons["Blueprint"]
        scrollTo(blueprint, app: app)
        XCTAssertFalse(refresh.isHittable, "The header should scroll offscreen at accessibility sizes")
        XCTAssertGreaterThanOrEqual(blueprint.frame.height.rounded(), 44)
        blueprint.tap()

        let heading = app.staticTexts["Long-term blueprint"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        scrollTo(heading, app: app)
        attachScreenshot("Plan Blueprint at largest accessibility text", app: app)
    }

    func testLargestTextKeepsHomeHeaderAndTabsReachable() {
        let app = launchLargestTextPreview("-execute-home-preview")
        let customize = app.buttons["Customize Home"]
        XCTAssertTrue(customize.waitForExistence(timeout: 10))

        for label in ["Progress", "Customize Home", "Profile", "Home", "Train", "Track", "Nutrition", "Plan"] {
            assertTapTarget(app.buttons[label].firstMatch)
        }
        attachScreenshot("Home and tabs at largest accessibility text", app: app)

        customize.tap()
        XCTAssertTrue(app.navigationBars["Customize Home"].waitForExistence(timeout: 5))
    }

    func testLargestTextKeepsTrackHeaderActionsReachable() {
        let app = launchLargestTextPreview("-execute-track-preview")
        let manage = app.buttons["Manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        assertTapTarget(manage)
        assertTapTarget(app.buttons["History"])
        attachScreenshot("Track at largest accessibility text", app: app)

        manage.tap()
        XCTAssertTrue(app.navigationBars["Manage Tracking"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Manage Tracking"].buttons["Done"].isHittable)
    }

    private func launchLargestTextPreview(_ argument: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            argument,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        return app
    }

    private func assertTapTarget(
        _ button: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(button.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.width.rounded(), 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.height.rounded(), 44, file: file, line: line)
    }

    private func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 {
            let frame = element.frame
            if element.isHittable && frame.minY > 75 && frame.maxY < app.frame.maxY - 110 { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let target = frame.minY < 75 && !frame.isEmpty ? 0.72 : 0.38
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: target))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Could not scroll \(element) fully into view")
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
