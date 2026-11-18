import XCTest

@MainActor
final class PlanAccessibilityUITests: XCTestCase {
    func testLargestTextLetsPlanHeaderScrollAndBlueprintOpen() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-execute-plan-preview",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

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
