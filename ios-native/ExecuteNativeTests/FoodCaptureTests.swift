import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import ExecuteNative

@MainActor final class FoodCaptureTests: XCTestCase {
    private let user = ExecuteUser(id: UUID(), email: "capture@example.invalid", displayName: "Synthetic")
    private let date = "2026-11-15"
    private func expect(_ expected: Bool, _ actual: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(actual, expected, file: file, line: line) }
    private func model(_ data: CaptureData, defaults: UserDefaults? = nil, ai: CaptureAI? = nil, lookup: CaptureLookup? = nil,
                       photo: @escaping () -> Bool = { true }, allowed: @escaping (UUID) -> Bool = { _ in true }) -> FoodCaptureModel {
        let model = FoodCaptureModel(data: data, ai: ai, lookup: lookup ?? CaptureLookup(), defaults: defaults ?? UserDefaults(suiteName: "CaptureTest.\(UUID())")!, canUsePhoto: photo, canAct: allowed)
        model.start(user: user, date: date); return model
    }
    private func product(_ values: [String: JSONValue] = [:]) -> JSONValue {
        .object(["product_name": .string("Synthetic cereal"), "serving_size": .string("25 g"), "nutriments": .object([
            "energy-kcal_100g": .number(400), "proteins_100g": .number(10), "carbohydrates_100g": .number(50), "fat_100g": .number(15)
        ].merging(values) { _, new in new })])
    }

    func testBarcodeCheckDigitsLeadingZerosAndUPCEExpansion() {
        XCTAssertEqual(FoodBarcode.normalized(" 0360-0029 1452 "), "036000291452")
        XCTAssertEqual(FoodBarcode.normalized("0036000291452"), "0036000291452")
        XCTAssertEqual(FoodBarcode.normalized("3017620422003"), "3017620422003")
        XCTAssertEqual(FoodBarcode.expandedUPCE("04252614"), "042100005264")
        XCTAssertNil(FoodBarcode.normalized("3017620422004"))
        XCTAssertNil(FoodBarcode.normalized("code:3017620422003"))
        XCTAssertNil(FoodBarcode.normalized("３０１７６２０４２２００３"))
        XCTAssertNil(FoodBarcode.expandedUPCE("94252614"))
    }

    func testBarcodeUsesOneCompleteServingBasisAndRetainsFractions() throws {
        let serving: [String: JSONValue] = ["energy-kcal_serving": .number(100), "proteins_serving": .number(2.5), "carbohydrates_serving": .number(12.5), "fat_serving": .number(3.75)]
        let review = try FoodBarcode.review(product: product(serving), code: "3017620422003")
        XCTAssertEqual(review.draft.calories, 100); XCTAssertEqual(review.draft.fats, 3.75)
        XCTAssertEqual(review.portion, "1 serving (25 g)")
        let payload = try review.payload(date: date, token: "fixture", time: "12:00")
        XCTAssertEqual(payload["barcode"], .string("3017620422003"))
        XCTAssertEqual(payload["log_method"], .string("barcode"))
        XCTAssertEqual(try payload.decoded(as: NutritionFoodLog.self).foods?.first?.portion, "1 serving (25 g)")
    }

    func testIncompleteServingFallsBackToComplete100BasisWithoutMixing() throws {
        let review = try FoodBarcode.review(product: product(["energy-kcal_serving": .number(100)]), code: "3017620422003")
        XCTAssertEqual(review.draft.calories, 400); XCTAssertEqual(review.draft.protein, 10)
        XCTAssertEqual(review.portion, "100 g or ml (database basis)")
        var incomplete = product().objectValue!
        incomplete["nutriments"] = .object(["energy-kcal_100g": .number(400), "proteins_100g": .number(10)])
        XCTAssertThrowsError(try FoodBarcode.review(product: .object(incomplete), code: "3017620422003"))
        XCTAssertThrowsError(try FoodBarcode.review(product: product(["fat_100g": .number(-1)]), code: "3017620422003"))
        XCTAssertThrowsError(try FoodBarcode.review(product: product(), code: "invalid"))
    }

    private func imageData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 800)).image { context in
            UIColor.yellow.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 49.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 123.0, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Synthetic Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Synthetic private comment"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }

    func testPhotoPreparationBoundsPixelsAndDropsMetadata() throws {
        let original = try imageData()
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil((originalProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        let prepared = try FoodPhoto.jpeg(original)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? Int.max, 1280)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        XCTAssertNil((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertLessThanOrEqual(prepared.count, 2_000_000)
        XCTAssertThrowsError(try FoodPhoto.jpeg(Data("not an image".utf8)))
        XCTAssertThrowsError(try FoodPhoto.jpeg(Data(repeating: 1, count: 20_000_001)))
    }

    func testPhotoValidationUsesItemSumsAndRejectsPartialOrNegativeFoods() throws {
        let estimate = CaptureAI.estimate
        let review = try FoodPhoto.review(estimate)
        XCTAssertEqual(review.draft.calories, 300); XCTAssertEqual(review.draft.protein, 15)
        XCTAssertEqual(review.draft.method, .photo)
        XCTAssertThrowsError(try FoodPhoto.review(NutritionAIEstimate(foods: [], totalCalories: 100, totalProtein: 1, totalCarbs: 1, totalFats: 1)))
        XCTAssertThrowsError(try FoodPhoto.review(NutritionAIEstimate(foods: [NutritionFoodItem(name: "Bad", portion: nil, calories: -1, protein: 1, carbs: 1, fats: 1)], totalCalories: nil, totalProtein: nil, totalCarbs: nil, totalFats: nil)))
    }

    func testPhotoExplicitRequestUsesExistingImageContractWithoutStorage() async throws {
        let ai = CaptureAI(), data = CaptureData(), model = model(data, ai: ai)
        let jpeg = try FoodPhoto.jpeg(imageData())
        await model.estimatePhoto(jpeg)
        XCTAssertEqual(ai.requests.count, 1); XCTAssertEqual(data.creates, 0)
        let request = try XCTUnwrap(ai.requests.first)
        XCTAssertEqual(request.fileURLs.first?.scheme, "data")
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
        guard case .array(let files) = json["file_urls"] else { return XCTFail("Missing image contract") }
        XCTAssertTrue(files.first?.stringValue?.hasPrefix("data:image/jpeg;base64,") == true)
        XCTAssertNil(request.inputFile); XCTAssertEqual(model.review?.draft.calories, 300)
    }

    func testPremiumAndAccountGatesPreventProviderAndWrites() async throws {
        let ai = CaptureAI(), data = CaptureData(), blocked = model(data, ai: ai, photo: { false })
        await blocked.estimatePhoto(try FoodPhoto.jpeg(imageData())); XCTAssertEqual(ai.requests.count, 0)
        let other = model(data, allowed: { _ in false })
        await other.findProduct("3017620422003"); XCTAssertNil(other.review)
        expect(false, await other.save(CaptureLookup.review, synchronize: { true }))
        XCTAssertEqual(data.creates, 0)
    }

    func testStoppedPhotoRequestCannotPublishToAnotherSession() async throws {
        let ai = CaptureAI(), data = CaptureData(), model = model(data, ai: ai)
        ai.beforeReturn = { model.stop() }
        await model.estimatePhoto(try FoodPhoto.jpeg(imageData()))
        XCTAssertNil(model.review); XCTAssertFalse(model.isWorking); XCTAssertEqual(data.creates, 0)
    }

    func testLostCreateAcknowledgmentResumesOneEntryAfterRecreation() async throws {
        let data = CaptureData(), defaults = UserDefaults(suiteName: "CaptureRestart.\(UUID())")!, first = model(data, defaults: defaults)
        await first.findProduct("3017620422003"); data.loseCreate = true
        expect(false, await first.save(try XCTUnwrap(first.review), synchronize: { true }))
        XCTAssertEqual(data.creates, 1); XCTAssertTrue(first.hasAttempt)
        let id = try XCTUnwrap(data.rows[.foodLogs]?.first?.id)
        first.stop()
        let second = model(data, defaults: defaults)
        XCTAssertTrue(second.hasAttempt)
        expect(true, await second.save(try XCTUnwrap(second.review), synchronize: { true }))
        XCTAssertEqual(data.creates, 1); XCTAssertEqual(second.savedID, id); XCTAssertFalse(second.hasAttempt)
        expect(false, await second.save(CaptureLookup.review, synchronize: { true }))
    }

    func testDailySyncFailureRetryDoesNotCreateAnotherFood() async throws {
        let data = CaptureData(), model = model(data)
        await model.findProduct("3017620422003")
        expect(false, await model.save(try XCTUnwrap(model.review), synchronize: { false }))
        XCTAssertEqual(data.creates, 1); XCTAssertTrue(model.hasAttempt)
        expect(true, await model.save(try XCTUnwrap(model.review), synchronize: { true }))
        XCTAssertEqual(data.creates, 1)
    }

    func testReadFailureAndDeletionGatePreventCreateAndLateRecreation() async throws {
        let data = CaptureData(), model = model(data)
        await model.findProduct("3017620422003"); data.failReads = true
        expect(false, await model.save(try XCTUnwrap(model.review), synchronize: { true })); XCTAssertEqual(data.creates, 0)
        data.failReads = false; data.beforeRead = { model.stop() }
        expect(false, await model.save(CaptureLookup.review, synchronize: { true })); XCTAssertEqual(data.creates, 0)
    }

    func testSavedFoodCorrectionIsPreservedDuringRetryAndPendingIsUserScoped() async throws {
        let data = CaptureData(), defaults = UserDefaults(suiteName: "CaptureScope.\(UUID())")!, model = model(data, defaults: defaults)
        await model.findProduct("3017620422003"); data.loseCreate = true
        expect(false, await model.save(try XCTUnwrap(model.review), synchronize: { true }))
        let original = try XCTUnwrap(data.rows[.foodLogs]?.first)
        var fields = original.data.objectValue!; fields["total_calories"] = .number(125); fields["future_field"] = .string("keep")
        data.rows[.foodLogs] = [CaptureData.row(fields, id: original.id)]
        expect(true, await model.save(try XCTUnwrap(model.review), synchronize: { true }))
        XCTAssertEqual(data.rows[.foodLogs]?.first?.data["total_calories"], .number(125))
        XCTAssertEqual(data.rows[.foodLogs]?.first?.data["future_field"], .string("keep")); XCTAssertEqual(data.creates, 1)
        model.start(user: ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other"), date: date)
        XCTAssertFalse(model.hasAttempt)
    }

    func testCaptureSynchronizesSameDailyRowPreservingUnrelatedVitalsAndLinks() async throws {
        let data = CaptureData(), dailyID = UUID(), master = UUID().uuidString
        data.rows[.dailyLogs] = [CaptureData.row(["date": .string(date), "steps": .number(1234), "source_plan_id": .string(master), "future_field": .string("keep")], id: dailyID)]
        let nutrition = NutritionViewModel(dataService: data, aiService: nil, cache: UserScopedCacheStore(suiteName: "CaptureNutrition.\(UUID())"), realtimeService: nil, router: AppRouter(), initialDate: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!)
        await nutrition.start(for: user)
        let capture = model(data); await capture.findProduct("3017620422003")
        let saved = await capture.save(try XCTUnwrap(capture.review), synchronize: { await nutrition.synchronizeCapturedFood(ownerID: self.user.id, date: self.date, canWrite: { true }) })
        XCTAssertTrue(saved); XCTAssertEqual(data.rows[.dailyLogs]?.count, 1)
        let daily = try XCTUnwrap(data.rows[.dailyLogs]?.first)
        XCTAssertEqual(daily.id, dailyID); XCTAssertEqual(daily.data["calories_consumed"], .number(100))
        XCTAssertEqual(daily.data["steps"], .number(1234)); XCTAssertEqual(daily.data["source_plan_id"], .string(master)); XCTAssertEqual(daily.data["future_field"], .string("keep"))
    }

    func testPendingAttemptIsIsolatedByAccountDateAndDeletionPurge() async throws {
        let suite = "CapturePurge.\(UUID())", defaults = UserDefaults(suiteName: suite)!, data = CaptureData()
        let capture = model(data, defaults: defaults)
        await capture.findProduct("3017620422003"); data.failReads = true
        expect(false, await capture.save(try XCTUnwrap(capture.review), synchronize: { true }))
        XCTAssertTrue(capture.hasAttempt)
        capture.start(user: ExecuteUser(id: UUID(), email: "other@example.invalid", displayName: "Other"), date: date)
        XCTAssertFalse(capture.hasAttempt)
        capture.start(user: user, date: "2026-11-14"); XCTAssertFalse(capture.hasAttempt)
        capture.start(user: user, date: date); XCTAssertTrue(capture.hasAttempt)
        await UserScopedCacheStore(suiteName: suite).purge(userID: user.id)
        capture.start(user: user, date: date); XCTAssertFalse(capture.hasAttempt)
        XCTAssertEqual(data.creates, 0)
    }

    func testPendingPhotoStoresOnlyReviewedValuesNotImageBytes() async throws {
        let suite = "CapturePhotoPrivacy.\(UUID())", defaults = UserDefaults(suiteName: suite)!, data = CaptureData(), ai = CaptureAI()
        let capture = model(data, defaults: defaults, ai: ai)
        await capture.estimatePhoto(try FoodPhoto.jpeg(imageData()))
        expect(false, await capture.save(try XCTUnwrap(capture.review), synchronize: { false }))
        let bytes = try XCTUnwrap(defaults.data(forKey: "execute.cache.\(user.id.uuidString).food-capture.\(date).pending"))
        XCTAssertLessThan(bytes.count, 10_000)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("data:image"))
        XCTAssertEqual(data.creates, 1)
    }

    func testCorrectingCapturePreservesBarcodeMethodPortionAndSource() async throws {
        let data = CaptureData()
        let payload = try CaptureLookup.review.payload(date: date, token: "fixture-token", time: "12:00")
        let row = CaptureData.row(payload.objectValue!)
        data.rows[.foodLogs] = [row]
        let day = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
        let nutrition = NutritionViewModel(dataService: data, aiService: nil, cache: UserScopedCacheStore(suiteName: "CaptureEdit.\(UUID())"), realtimeService: nil, router: AppRouter(), initialDate: day)
        await nutrition.start(for: user)
        let record = try XCTUnwrap(nutrition.snapshot.foodLogs.first)
        var draft = CaptureLookup.review.draft; draft.calories = 50; draft.portion = record.log.foods?.first?.portion
        expect(true, await nutrition.edit(record, draft: draft))
        let corrected = try XCTUnwrap(data.rows[.foodLogs]?.first)
        XCTAssertEqual(corrected.id, row.id); XCTAssertEqual(corrected.data["log_method"], .string("barcode"))
        XCTAssertEqual(corrected.data["barcode"], .string("3017620422003")); XCTAssertEqual(corrected.data["capture_source"], .string("Fixture product data"))
        XCTAssertEqual(try corrected.data.decoded(as: NutritionFoodLog.self).foods?.first?.portion, "1 serving (25 g)")
    }

    func testFutureDateAndDuplicatePendingRowsFailWithoutRepair() async throws {
        let data = CaptureData(), capture = model(data)
        capture.start(user: user, date: "9999-12-31"); await capture.findProduct("3017620422003")
        expect(false, await capture.save(try XCTUnwrap(capture.review), synchronize: { true })); XCTAssertEqual(data.creates, 0)
        capture.start(user: user, date: date); await capture.findProduct("3017620422003"); data.loseCreate = true
        expect(false, await capture.save(try XCTUnwrap(capture.review), synchronize: { true }))
        let saved = try XCTUnwrap(data.rows[.foodLogs]?.first)
        data.rows[.foodLogs, default: []].append(CaptureData.row(saved.data.objectValue!))
        expect(false, await capture.save(try XCTUnwrap(capture.review), synchronize: { true }))
        XCTAssertEqual(data.creates, 1); XCTAssertEqual(data.rows[.foodLogs]?.count, 2); XCTAssertNotNil(capture.error)
    }

    func testWrongAcknowledgmentCannotSyncAndRetryFindsOriginalRecord() async throws {
        let data = CaptureData(), capture = model(data)
        await capture.findProduct("3017620422003"); data.corruptAcknowledgment = true
        var synchronizations = 0
        expect(false, await capture.save(try XCTUnwrap(capture.review), synchronize: { synchronizations += 1; return true }))
        XCTAssertEqual(synchronizations, 0); XCTAssertEqual(data.creates, 1); XCTAssertTrue(capture.hasAttempt)
        data.corruptAcknowledgment = false
        expect(true, await capture.save(try XCTUnwrap(capture.review), synchronize: { synchronizations += 1; return true }))
        XCTAssertEqual(synchronizations, 1); XCTAssertEqual(data.creates, 1)
    }

    func testForeignOwnerReadCannotCreateCapturedFood() async throws {
        let data = CaptureData(), capture = model(data)
        let row = CaptureData.row(["date": .string(date)])
        data.rows[.foodLogs] = [BackendRow(id: row.id, ownerID: UUID(), ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: row.createdDate, updatedDate: row.updatedDate, data: row.data)]
        await capture.findProduct("3017620422003")
        expect(false, await capture.save(try XCTUnwrap(capture.review), synchronize: { true }))
        XCTAssertEqual(data.creates, 0); XCTAssertNotNil(capture.error)
    }

    func testCaptureSyncFindsOldRecordsBeyondRecentPagesWithoutDuplicateDaily() async throws {
        let data = CaptureData(), dailyID = UUID()
        data.rows[.dailyLogs] = (0..<600).map { _ in CaptureData.row(["date": .string("2000-01-01")]) }
        data.rows[.foodLogs] = (0..<600).map { _ in CaptureData.row(["date": .string("2000-01-01")]) }
        data.rows[.dailyLogs]!.append(CaptureData.row(["date": .string(date), "calories_consumed": .number(100), "steps": .number(77), "source_plan_id": .string("preserved-master")], id: dailyID))
        for name in ["Old snack", "Captured snack"] {
            data.rows[.foodLogs]!.append(CaptureData.row(["date": .string(date), "notes": .string(name), "total_calories": .number(100), "total_protein_g": .number(5), "total_carbs_g": .number(10), "total_fats_g": .number(2)]))
        }
        let day = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
        let nutrition = NutritionViewModel(dataService: data, aiService: nil, cache: UserScopedCacheStore(suiteName: "CaptureOld.\(UUID())"), realtimeService: nil, router: AppRouter(), initialDate: day)
        await nutrition.start(for: user)
        expect(true, await nutrition.synchronizeCapturedFood(ownerID: user.id, date: date, canWrite: { true }))
        let saved = try XCTUnwrap(data.rows[.dailyLogs]?.first { $0.id == dailyID })
        XCTAssertEqual(saved.data["calories_consumed"], .number(200)); XCTAssertEqual(saved.data["steps"], .number(77))
        XCTAssertEqual(saved.data["source_plan_id"], .string("preserved-master"))
        XCTAssertEqual(data.rows[.dailyLogs]?.count, 601); XCTAssertEqual(data.creates, 0)
    }

    func testUnknownLegacyDailyIntakeIsPreservedForReview() async throws {
        let data = CaptureData(), dailyID = UUID()
        data.rows[.dailyLogs] = [CaptureData.row(["date": .string(date), "calories_consumed": .number(500), "future_field": .string("keep")], id: dailyID)]
        data.rows[.foodLogs] = [CaptureData.row(["date": .string(date), "total_calories": .number(100)])]
        let day = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
        let nutrition = NutritionViewModel(dataService: data, aiService: nil, cache: UserScopedCacheStore(suiteName: "CaptureLegacy.\(UUID())"), realtimeService: nil, router: AppRouter(), initialDate: day)
        await nutrition.start(for: user)
        expect(false, await nutrition.synchronizeCapturedFood(ownerID: user.id, date: date, canWrite: { true }))
        XCTAssertEqual(data.rows[.dailyLogs]?.first?.data["calories_consumed"], .number(500)); XCTAssertEqual(data.updates, 0)
        XCTAssertNotNil(nutrition.error)
    }
    private func recipe(_ data: CaptureData) throws -> EntityRecord<JSONValue> {
        let row = CaptureData.row(["name": .string("Synthetic recipe"), "calories": .number(400), "protein": .number(20), "carbs": .number(60), "fats": .number(12),
            "source_meal_plan_id": .string(UUID().uuidString), "source_meal_key": .string("lunch"), "future_field": .string("retain snapshot")])
        data.rows[.savedRecipes] = [row]; return try EntityRecord(row: row)
    }
    func testRecipeFractionsScaleOneBasisAndRetainSnapshotWithoutPlannedCompletionLinks() throws {
        let data = CaptureData(), row = try recipe(data)
        let review = try RecipePortion.review(recipeID: row.id, payload: row.payload, fraction: 0.25, mealType: .dinner)
        XCTAssertEqual(review.draft.calories, 100); XCTAssertEqual(review.draft.protein, 5); XCTAssertEqual(review.draft.carbs, 15); XCTAssertEqual(review.draft.fats, 3)
        let payload = try review.payload(date: date, token: "recipe-fixture", time: "12:00")
        XCTAssertEqual(payload["source_recipe_id"], .string(row.id.uuidString)); XCTAssertEqual(payload["recipe_fraction"], .number(0.25)); XCTAssertEqual(payload["recipe_snapshot"], row.payload)
        XCTAssertNil(payload["source_meal_plan_id"]); XCTAssertNil(payload["planned_meal_key"])
        XCTAssertEqual(try payload.decoded(as: NutritionFoodLog.self).foods?.first?.portion, "0.25 × full recipe")
        XCTAssertEqual(payload["meal_type"], .string("dinner")); XCTAssertEqual(payload["log_method"], .string("manual"))
    }
    func testCorrectionFieldsRoundTripFractionalRecipeValuesWithoutChangingUntouchedMacros() {
        for original in [375.25, 27.5, 42.5, 11.125, 0.125, 9999.999] {
            XCTAssertEqual(NutritionFormat.number(NutritionFormat.editable(original)), original)
        }
        XCTAssertEqual(NutritionFormat.editable(.infinity), "")
        XCTAssertEqual(NutritionFormat.editable(.nan), "")
    }
    func testRecipeInvalidFractionsMissingNutritionAndScaledOverflowFailClosed() throws {
        let data = CaptureData(), row = try recipe(data)
        for fraction in [0.0, -1, .nan, .infinity, 10.1] { XCTAssertThrowsError(try RecipePortion.review(recipeID: row.id, payload: row.payload, fraction: fraction, mealType: .snack)) }
        var fields = row.payload.objectValue!; fields.removeValue(forKey: "protein")
        XCTAssertThrowsError(try RecipePortion.review(recipeID: row.id, payload: .object(fields), fraction: 0.5, mealType: .snack))
        fields = row.payload.objectValue!; fields["calories"] = .number(2000)
        XCTAssertThrowsError(try RecipePortion.review(recipeID: row.id, payload: .object(fields), fraction: 10, mealType: .snack))
        fields = row.payload.objectValue!; fields["fat"] = fields.removeValue(forKey: "fats")
        XCTAssertEqual(try RecipePortion.review(recipeID: row.id, payload: .object(fields), fraction: 0.5, mealType: .snack).draft.fats, 6)
    }
    func testRecipeLostCreateAndDailySyncRetrySurviveRecreationWithoutDuplicates() async throws {
        for loseCreate in [false, true] {
            let data = CaptureData(), row = try recipe(data), defaults = UserDefaults(suiteName: "RecipeFood.\(UUID())")!, first = model(data, defaults: defaults)
            first.prepareRecipe(row, fraction: 1, mealType: .snack); XCTAssertEqual(data.creates, 0)
            let reviewed = try RecipePortion.review(recipeID: row.id, payload: row.payload, fraction: 0.5, mealType: .snack)
            data.loseCreate = loseCreate
            expect(false, await first.save(reviewed, synchronize: { false }))
            XCTAssertEqual(first.review, reviewed) // Pending/retry UI must show the submitted portion, not the initial full recipe.
            let id = try XCTUnwrap(data.rows[.foodLogs]?.first?.id)
            data.rows[.savedRecipes] = [] // A saved food remains valid if its recipe is later deleted.
            let retry = model(data, defaults: defaults); XCTAssertTrue(retry.hasAttempt)
            expect(true, await retry.save(try XCTUnwrap(retry.review), synchronize: { true }))
            XCTAssertEqual(data.creates, 1); XCTAssertEqual(retry.savedID, id)
            expect(false, await retry.save(try XCTUnwrap(retry.review), synchronize: { true }))
        }
    }
    func testChangedDeletedForeignOrRepeatedRecipeRecordsPreventNewFoodAndDiscardDoesNotUndo() async throws {
        for kind in 0..<4 {
            let data = CaptureData(), row = try recipe(data), capture = model(data)
            capture.prepareRecipe(row, fraction: 0.5, mealType: .snack)
            if kind == 0 { data.rows[.savedRecipes] = [] }
            if kind == 1 { var fields = row.payload.objectValue!; fields["calories"] = .number(999); data.rows[.savedRecipes] = [CaptureData.row(fields, id: row.id)] }
            if kind == 2 { let old = data.rows[.savedRecipes]![0]; data.rows[.savedRecipes] = [BackendRow(id: old.id, ownerID: UUID(), ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: old.createdDate, updatedDate: old.updatedDate, data: old.data)] }
            if kind == 3 { let old = data.rows[.savedRecipes]![0]; data.rows[.savedRecipes]!.append(old) }
            expect(false, await capture.save(try XCTUnwrap(capture.review), synchronize: { true })); XCTAssertEqual(data.creates, 0)
            let saved = data.rows[.savedRecipes]; capture.discardLocalAttempt(); XCTAssertFalse(capture.hasAttempt); XCTAssertEqual(data.rows[.savedRecipes], saved)
        }
    }
    func testRecipeHistoryPaginationAndSessionGates() async throws {
        let data = CaptureData(), row = try recipe(data)
        data.rows[.savedRecipes] = (0..<510).map { _ in CaptureData.row(["name": .string("Older recipe")]) } + data.rows[.savedRecipes]!
        var allowed = true; let capture = model(data, allowed: { _ in allowed })
        capture.prepareRecipe(row, fraction: 0.5, mealType: .snack)
        allowed = false; expect(false, await capture.save(try XCTUnwrap(capture.review), synchronize: { true })); XCTAssertEqual(data.creates, 0)
        allowed = true; expect(true, await capture.save(try XCTUnwrap(capture.review), synchronize: { true })); XCTAssertEqual(data.creates, 1)
        let other = model(data); data.beforeRead = { other.stop() }; other.prepareRecipe(row, fraction: 0.5, mealType: .snack)
        expect(false, await other.save(try XCTUnwrap(other.review), synchronize: { true })); XCTAssertEqual(data.creates, 1)
    }
    func testRecipeLoggingCorrectionAndDeletionKeepSameDailyAndPreserveRecipeAndCompletion() async throws {
        let data = CaptureData(), row = try recipe(data), originalRecipe = data.rows[.savedRecipes], dailyID = UUID()
        data.rows[.dailyLogs] = [CaptureData.row(["date": .string(date), "steps": .number(1234), "meals_completed": .array([.string("breakfast"), .string("dinner")]), "future_field": .string("keep")], id: dailyID)]
        let day = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
        let nutrition = NutritionViewModel(dataService: data, aiService: nil, cache: UserScopedCacheStore(suiteName: "RecipeDaily.\(UUID())"), realtimeService: nil, router: AppRouter(), initialDate: day)
        await nutrition.start(for: user); let capture = model(data); capture.prepareRecipe(row, fraction: 0.5, mealType: .lunch)
        expect(true, await capture.save(try XCTUnwrap(capture.review), synchronize: { await nutrition.synchronizeCapturedFood(ownerID: self.user.id, date: self.date, canWrite: { true }) }))
        let food = try XCTUnwrap(nutrition.snapshot.foodLogs.first); var edit = try XCTUnwrap(capture.review).draft
        edit.calories = 240; edit.portion = food.log.foods?.first?.portion
        expect(true, await nutrition.edit(food, draft: edit))
        let saved = try XCTUnwrap(data.rows[.foodLogs]?.first)
        XCTAssertEqual(saved.id, food.id); XCTAssertEqual(saved.data["recipe_snapshot"], row.payload); XCTAssertEqual(saved.data["recipe_fraction"], .number(0.5))
        await nutrition.delete(try XCTUnwrap(nutrition.snapshot.foodLogs.first))
        let daily = try XCTUnwrap(data.rows[.dailyLogs]?.first)
        XCTAssertEqual(daily.id, dailyID); XCTAssertEqual(data.rows[.dailyLogs]?.count, 1); XCTAssertEqual(daily.data["calories_consumed"], .number(0))
        XCTAssertEqual(daily.data["steps"], .number(1234)); XCTAssertEqual(daily.data["future_field"], .string("keep"))
        XCTAssertEqual(daily.data["meals_completed"], .array([.string("breakfast"), .string("dinner")]))
        XCTAssertEqual(data.rows[.savedRecipes], originalRecipe); XCTAssertTrue(data.rows[.foodLogs]?.isEmpty == true)
    }
    func testUnreadablePendingFoodAttemptBlocksNewSaveUntilExplicitDiscard() async throws {
        let defaults = UserDefaults(suiteName: "RecipeCorrupt.\(UUID())")!, data = CaptureData(), row = try recipe(data)
        defaults.set(Data([0,1]), forKey: "execute.cache.\(user.id.uuidString).food-capture.\(date).pending")
        let capture = model(data, defaults: defaults); XCTAssertTrue(capture.hasAttempt)
        XCTAssertTrue(FoodCaptureModel.hasPending(userID: user.id, date: date, defaults: defaults))
        capture.prepareRecipe(row, fraction: 0.5, mealType: .snack); XCTAssertNil(capture.review)
        expect(false, await capture.save(CaptureLookup.review, synchronize: { true })); XCTAssertEqual(data.creates, 0)
        capture.discardLocalAttempt(); capture.prepareRecipe(row, fraction: 0.5, mealType: .snack); XCTAssertNotNil(capture.review)
        XCTAssertFalse(FoodCaptureModel.hasPending(userID: user.id, date: date, defaults: defaults))
    }
}

@MainActor private final class CaptureLookup: FoodProductLookingUp {
    static let review = FoodCaptureReview(draft: NutritionEntryDraft(name: "SYNTHETIC QA packaged food", mealType: .snack, calories: 100, protein: 5, carbs: 10, fats: 2, method: .barcode), portion: "1 serving (25 g)", source: "Fixture product data", barcode: "3017620422003")
    func product(code: String) async throws -> FoodCaptureReview { Self.review }
}

@MainActor private final class CaptureAI: AIResponding {
    var requests: [LLMRequest] = []
    var beforeReturn: (() -> Void)?
    static var estimate: NutritionAIEstimate { NutritionAIEstimate(foods: [NutritionFoodItem(name: "Synthetic oats", portion: "1 bowl", calories: 300, protein: 15, carbs: 40, fats: 8)], totalCalories: 999, totalProtein: 999, totalCarbs: 999, totalFats: 999) }
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        requests.append(request); beforeReturn?()
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(Self.estimate))
    }
    func textResponse(_ request: LLMRequest) async throws -> String { XCTFail("Unexpected text AI request"); return "" }
}

@MainActor private final class CaptureData: EntityDataServicing {
    var rows: [EntityTable: [BackendRow]] = [:]
    var creates = 0, updates = 0
    var failReads = false, loseCreate = false, corruptAcknowledgment = false
    var beforeRead: (() -> Void)?
    static func row(_ fields: [String: JSONValue], id: UUID = UUID()) -> BackendRow {
        BackendRow(id: id, ownerID: nil, ownerEmail: nil, createdBy: nil, userEmail: nil, createdDate: .now, updatedDate: .now, data: .object(fields))
    }
    func list<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int) async throws -> [EntityRecord<Payload>] { try await listPage(table, orderBy: orderBy, limit: limit, offset: 0) }
    func listPage<Payload: Codable & Sendable>(_ table: EntityTable, orderBy: String, limit: Int, offset: Int) async throws -> [EntityRecord<Payload>] {
        if failReads { throw URLError(.notConnectedToInternet) }; beforeRead?()
        return try (rows[table] ?? []).dropFirst(offset).prefix(limit).map { try EntityRecord(row: $0) }
    }
    func create<Payload: Codable & Sendable>(_ table: EntityTable, payload: Payload, user: ExecuteUser) async throws -> EntityRecord<Payload> {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload)), row = Self.row(value.objectValue ?? [:])
        rows[table, default: []].append(row); creates += 1
        if loseCreate { loseCreate = false; throw URLError(.networkConnectionLost) }
        if corruptAcknowledgment {
            var fields = row.data.objectValue!; fields["native_mutation_id"] = .string("incorrect acknowledgment")
            return try EntityRecord(row: Self.row(fields, id: row.id))
        }
        return try EntityRecord(row: row)
    }
    func update<Payload: Codable & Sendable>(_ table: EntityTable, id: UUID, patch: JSONValue) async throws -> EntityRecord<Payload> {
        let index = try XCTUnwrap(rows[table]?.firstIndex { $0.id == id }), old = rows[table]![index]
        let row = Self.row((old.data.objectValue ?? [:]).merging(patch.objectValue ?? [:]) { _, new in new }, id: id)
        rows[table]![index] = row; updates += 1; return try EntityRecord(row: row)
    }
    func delete(_ table: EntityTable, id: UUID) async throws { XCTAssertEqual(table, .foodLogs); rows[table]?.removeAll { $0.id == id } }
}
