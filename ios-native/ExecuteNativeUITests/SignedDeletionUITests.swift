import XCTest

@MainActor
final class SignedDeletionUITests: XCTestCase {
    private static let origin = "https://127.0.0.1:55474"
    private static let targetEmail = "e68-target@example.com"
    private static let witnessEmail = "e68-witness@example.com"

    private struct Fixture: Decodable {
        let target_id: UUID
        let witness_id: UUID
        let origin: String
    }
    private struct OTP: Decodable { let code: String }
    private struct OwnerEvidence: Decodable {
        let auth_exists: Bool
        let goal_exists: Bool
        let object_exists: Bool
        var present: Bool { auth_exists && goal_exists && object_exists }
        var absent: Bool { !auth_exists && !goal_exists && !object_exists }
    }
    private struct Evidence: Decodable {
        let target: OwnerEvidence
        let witness: OwnerEvidence
        let native_deletion_count: Int
    }
    private enum Failure: Error { case fixture, missingUI(String) }

    override func setUpWithError() throws { continueAfterFailure = false }

    func testPrepareExactOwnerAndCancel() async throws {
        let fixture = try await requireFixture()
        let app = launch(fixture)
        try await signIn(Self.witnessEmail, app)
        try openProfile(Self.witnessEmail, app)
        try openDeletion(app)
        XCTAssertFalse(app.textFields["DELETE"].isEnabled)
        XCTAssertFalse(app.buttons["Permanently Delete Account"].isEnabled)
        app.buttons["Cancel"].tap()
        try signOut(app)

        try await signIn(Self.targetEmail, app)
        try openProfile(Self.targetEmail, app)
        try openDeletion(app)
        XCTAssertTrue(app.textFields["DELETE"].isEnabled)
        XCTAssertFalse(app.buttons["Permanently Delete Account"].isEnabled)
        app.buttons["Cancel"].tap()
        try require(app.navigationBars["Profile & Settings"], "Profile after cancelling deletion")
        let evidence: Evidence = try await get("/qa/evidence")
        XCTAssertTrue(evidence.target.present)
        XCTAssertTrue(evidence.witness.present)
        XCTAssertEqual(evidence.native_deletion_count, 0)
    }

    func testDeleteExactOwnerAndRelaunchSignedOut() async throws {
        let fixture = try await requireFixture()
        let app = launch(fixture)
        try openProfile(Self.targetEmail, app)
        try openDeletion(app)
        let field = app.textFields["DELETE"]
        let action = app.buttons["Permanently Delete Account"]
        XCTAssertFalse(action.isEnabled)
        field.tap()
        field.typeText("WRONG")
        XCTAssertFalse(action.isEnabled)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "DELETE")
        XCTAssertTrue(action.isEnabled)
        try reveal(action, app, "Permanent deletion action")
        action.tap()

        try require(app.textFields["Email"], "Signed-out screen after acknowledged deletion")
        XCTAssertFalse(app.buttons["Profile"].exists)
        let evidence: Evidence = try await get("/qa/evidence")
        XCTAssertTrue(evidence.target.absent)
        XCTAssertTrue(evidence.witness.present)
        XCTAssertEqual(evidence.native_deletion_count, 1)

        app.terminate()
        app.launch()
        try require(app.textFields["Email"], "Signed-out screen on cold relaunch")
        XCTAssertFalse(app.buttons["Profile"].exists)
    }

    private func requireFixture() async throws -> Fixture {
        guard ProcessInfo.processInfo.environment["EXECUTE_E68_SIGNED_DELETION"] == "1" else {
            throw XCTSkip("Requires the isolated signed E68 deletion fixture")
        }
        let fixture: Fixture = try await get("/qa/ready")
        guard fixture.origin == Self.origin, fixture.target_id != fixture.witness_id else { throw Failure.fixture }
        return fixture
    }

    private func launch(_ fixture: Fixture) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EXECUTE_STAGED_DELETION_ORIGIN"] = Self.origin
        app.launchEnvironment["EXECUTE_STAGED_DELETION_OWNER_UUID"] = fixture.target_id.uuidString
        app.launch()
        return app
    }

    private func signIn(_ email: String, _ app: XCUIApplication) async throws {
        let field = app.textFields["Email"]
        try require(field, "Email sign-in field")
        field.tap()
        field.typeText(email)
        let send = app.buttons["Continue with email"]
        if !send.isHittable { app.swipeUp() }
        try require(send, "Send email code button")
        send.tap()
        let codeField = app.textFields["Email code"]
        try require(codeField, "Email code field")
        let otp: OTP = try await get("/qa/otp", query: [.init(name: "email", value: email)])
        guard otp.code.utf8.count == 6, otp.code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure.fixture }
        codeField.tap()
        codeField.typeText(otp.code)
        let verify = app.buttons["Verify code"]
        if !verify.isHittable { app.swipeUp() }
        try require(verify, "Verify email code button")
        verify.tap()
        try require(app.buttons["Profile"], "Signed-in Home")
    }

    private func openProfile(_ email: String, _ app: XCUIApplication) throws {
        let profile = app.buttons["Profile"]
        try require(profile, "Home Profile button")
        profile.tap()
        try require(app.navigationBars["Profile & Settings"], "Profile title")
        try require(app.staticTexts[email].firstMatch, "Exact synthetic email in Profile")
    }

    private func openDeletion(_ app: XCUIApplication) throws {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Delete Account")).firstMatch
        try reveal(row, app, "Profile Delete Account row")
        row.tap()
        try require(app.navigationBars["Delete Account"], "Deletion confirmation title")
        try require(app.textFields["DELETE"], "Deletion confirmation field")
    }

    private func signOut(_ app: XCUIApplication) throws {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sign Out")).firstMatch
        try reveal(row, app, "Profile Sign Out row")
        row.tap()
        let confirm = app.buttons["Sign Out"].firstMatch
        try require(confirm, "Sign Out confirmation")
        confirm.tap()
        try require(app.textFields["Email"], "Signed out after explicit sign-out")
    }

    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, _ name: String) throws {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        guard element.isHittable else { throw Failure.missingUI(name) }
    }

    private func require(_ element: XCUIElement, _ name: String) throws {
        guard element.waitForExistence(timeout: 20) else { throw Failure.missingUI(name) }
    }

    private func get<Value: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        var url = URLComponents(string: Self.origin + path)!
        if !query.isEmpty { url.queryItems = query }
        let (body, response) = try await URLSession.shared.data(for: URLRequest(url: url.url!, timeoutInterval: 10))
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { throw Failure.fixture }
        return try JSONDecoder().decode(Value.self, from: body)
    }
}
