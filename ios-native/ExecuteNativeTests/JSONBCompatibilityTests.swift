import XCTest
@testable import ExecuteNative

final class JSONBCompatibilityTests: XCTestCase {
    func testRepresentativePayloadIgnoresUnknownJSONBFieldsAndPreservesRawData() throws {
        let json = """
        {
          "id": "550E8400-E29B-41D4-A716-446655440000",
          "owner_id": "550E8400-E29B-41D4-A716-446655440001",
          "owner_email": "member@example.com",
          "created_by": "member@example.com",
          "user_email": "member@example.com",
          "created_date": "2026-08-29T12:00:00Z",
          "updated_date": "2026-08-29T12:30:00Z",
          "data": {
            "date": "2026-08-29",
            "calories_consumed": 2210,
            "water_ml": 1800,
            "future_field": { "source": "legacy-client" }
          }
        }
        """

        let row = try JSONDecoder.execute.decode(BackendRow.self, from: Data(json.utf8))
        let record = try EntityRecord<DailyLogPayload>(row: row)

        XCTAssertEqual(record.payload.date, "2026-08-29")
        XCTAssertEqual(record.payload.caloriesConsumed, 2210)
        XCTAssertEqual(record.metadata.data["future_field"]?.objectValue?["source"]?.stringValue, "legacy-client")
        XCTAssertEqual(record.ownerEmail, "member@example.com")
    }

    func testAIResponseNormalizerHandlesMarkdownFences() throws {
        struct Answer: Decodable, Equatable { let answer: String }
        let value = try AIResponseNormalizer.decode(Answer.self, from: "```json\n{\"answer\":\"ready\"}\n```")
        XCTAssertEqual(value, Answer(answer: "ready"))
    }
}

@MainActor
final class NavigationTests: XCTestCase {
    func testSelectingActiveTabResetsItsPath() {
        let router = AppRouter()
        let binding = router.pathBinding(for: .home)
        binding.wrappedValue = [.goals]
        router.select(.home)
        XCTAssertTrue(router.pathBinding(for: .home).wrappedValue.isEmpty)
    }
}
