import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FoodCaptureKind: String, Codable { case photo, barcode }

struct FoodCaptureReview: Codable, Equatable, Sendable {
    var draft: NutritionEntryDraft
    var portion: String
    var source: String
    var barcode: String?

    func payload(date: String, token: String, time: String) throws -> JSONValue {
        guard draft.name.count <= 500, !portion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, portion.count <= 1000,
              let food = NutritionEntryFactory.payload(from: draft, date: date, time: time) else {
            throw AppError(title: "Check the food details", message: "Enter a name and valid, nonnegative nutrition values before saving.")
        }
        var fields = try JSONValue.decode(food).objectValue ?? [:]
        fields["native_mutation_id"] = .string(token)
        fields["capture_source"] = .string(source)
        if let barcode { fields["barcode"] = .string(barcode) }
        if case .array(var foods) = fields["foods"], var first = foods.first?.objectValue {
            first["portion"] = .string(portion)
            foods[0] = .object(first); fields["foods"] = .array(foods)
        }
        return .object(fields)
    }
}

enum FoodBarcode {
    static func normalized(_ raw: String) -> String? {
        let code = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard [8, 12, 13, 14].contains(code.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let digits = code.utf8.map { Int($0 - 48) }
        let sum = digits.dropLast().reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 3 : 1) }
        return (10 - sum % 10) % 10 == digits.last ? code : nil
    }

    /// UPC-E camera observations must be expanded before the UPC-A check digit is validated.
    static func expandedUPCE(_ raw: String) -> String? {
        guard raw.count == 8, raw.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let d = Array(raw).map(String.init)
        guard d[0] == "0" || d[0] == "1" else { return nil }
        let middle: String
        switch d[6] {
        case "0", "1", "2": middle = d[1] + d[2] + d[6] + "0000" + d[3] + d[4] + d[5]
        case "3": middle = d[1] + d[2] + d[3] + "00000" + d[4] + d[5]
        case "4": middle = d[1] + d[2] + d[3] + d[4] + "00000" + d[5]
        default: middle = d[1] + d[2] + d[3] + d[4] + d[5] + "0000" + d[6]
        }
        return normalized(d[0] + middle + d[7])
    }

    static func review(product: JSONValue, code: String) throws -> FoodCaptureReview {
        guard normalized(code) != nil, let name = product["product_name"]?.stringValue?.captureNonempty,
              let nutrients = product["nutriments"]?.objectValue else { throw unavailable() }
        func number(_ key: String) -> Double? {
            let value = nutrients[key]?.doubleValue ?? nutrients[key]?.stringValue.flatMap(Double.init)
            return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        func bundle(_ suffix: String) -> [Double]? {
            let values = ["energy-kcal", "proteins", "carbohydrates", "fat"].map { number("\($0)_\(suffix)") }
            return values.allSatisfy { $0 != nil } ? values.compactMap { $0 } : nil
        }
        let values: [Double]
        let portion: String
        // Every macro must share a complete basis. Missing values are never guessed as zero.
        if let serving = bundle("serving"), let label = product["serving_size"]?.stringValue?.captureNonempty {
            values = serving; portion = "1 serving (\(label))"
        } else if let per100 = bundle("100g") {
            values = per100; portion = "100 g or ml (database basis)"
        } else { throw unavailable() }
        let draft = NutritionEntryDraft(name: name, mealType: .snack, calories: values[0], protein: values[1], carbs: values[2], fats: values[3], method: .barcode)
        guard NutritionEntryFactory.payload(from: draft, date: "2000-01-01") != nil else { throw unavailable() }
        return FoodCaptureReview(draft: draft, portion: portion, source: "Open Food Facts — community product data", barcode: code)
    }

    static func unavailable() -> AppError {
        AppError(title: "Product details unavailable", message: "No complete nutrition record was found. Check the package and use manual entry, or try another barcode.")
    }
}

@MainActor protocol FoodProductLookingUp {
    func product(code: String) async throws -> FoodCaptureReview
}

@MainActor final class OpenFoodFactsLookup: FoodProductLookingUp {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func product(code: String) async throws -> FoodCaptureReview {
        guard let code = FoodBarcode.normalized(code) else {
            throw AppError(title: "Check the barcode", message: "Enter a valid 8, 12, 13 or 14 digit product barcode, including its check digit.")
        }
        let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json?fields=product_name,nutriments,serving_size")!
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("ExecuteNative/1.0 (iOS; com.executelabs.execute.native-dev)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1_000_000 else { throw FoodBarcode.unavailable() }
        let result = try JSONDecoder().decode(JSONValue.self, from: data)
        guard result["status"]?.doubleValue == 1, let product = result["product"] else { throw FoodBarcode.unavailable() }
        return try FoodBarcode.review(product: product, code: code)
    }
}

enum FoodPhoto {
    static func jpeg(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue * height.doubleValue <= 120_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280
              ] as CFDictionary) else {
            throw AppError(title: "Choose another photo", message: "Use a readable image under 20 MB.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw invalid() }
        // Encode only pixels: EXIF location, camera metadata and the original file name are omitted.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 2_000_000 else { throw invalid() }
        return output as Data
    }
    private static func invalid() -> AppError { AppError(title: "Photo could not be prepared", message: "Try a smaller photo or enter the food manually.") }

    static func review(_ estimate: NutritionAIEstimate) throws -> FoodCaptureReview {
        guard !estimate.foods.isEmpty, estimate.foods.count <= 20,
              estimate.foods.allSatisfy({ food in
                  guard food.name?.captureNonempty != nil else { return false }
                  return [food.calories, food.protein, food.carbs, food.fats].allSatisfy { $0.map { $0.isFinite && $0 >= 0 } == true }
              }) else { throw AppError(title: "Photo estimate incomplete", message: "Try another photo or enter the nutrition from the package manually.") }
        let totals = estimate.totals
        let draft = NutritionEntryDraft(name: estimate.foods.compactMap(\.name).joined(separator: ", "), mealType: .snack,
            calories: totals.calories, protein: totals.protein, carbs: totals.carbs, fats: totals.fats, method: .photo)
        guard NutritionEntryFactory.payload(from: draft, date: "2000-01-01") != nil else { throw invalid() }
        let portion = estimate.foods.compactMap { food in food.portion.map { "\(food.name ?? "Food"): \($0)" } }.joined(separator: "; ")
        return FoodCaptureReview(draft: draft, portion: portion.isEmpty ? "Estimated visible portion — please check" : portion,
            source: "AI photo estimate — portions and macros need your review", barcode: nil)
    }
}

@MainActor final class FoodCaptureModel: ObservableObject {
    @Published private(set) var review: FoodCaptureReview?
    @Published private(set) var isWorking = false
    @Published private(set) var error: AppError?
    @Published private(set) var hasAttempt = false
    @Published private(set) var savedID: UUID?
    private let data: EntityDataServicing?
    private let ai: AIResponding?
    private let lookup: FoodProductLookingUp
    private let defaults: UserDefaults
    private let canAct: (UUID) -> Bool
    private let canUsePhoto: () -> Bool
    private var user: ExecuteUser?
    private var date = ""
    private var generation = UUID()
    private var attempt: Attempt?
    private struct Attempt: Codable { let review: FoodCaptureReview; let token: String; let time: String }

    init(data: EntityDataServicing?, ai: AIResponding?, lookup: FoodProductLookingUp = OpenFoodFactsLookup(),
         defaults: UserDefaults = .standard, canUsePhoto: @escaping () -> Bool = { false }, canAct: @escaping (UUID) -> Bool) {
        self.data = data; self.ai = ai; self.lookup = lookup; self.defaults = defaults; self.canAct = canAct; self.canUsePhoto = canUsePhoto
    }
    func start(user: ExecuteUser, date: String) {
        stop(); self.user = user; self.date = date
        if let bytes = defaults.data(forKey: key(user.id, date)), let value = try? JSONDecoder().decode(Attempt.self, from: bytes) {
            attempt = value; review = value.review; hasAttempt = true
            error = AppError(title: "Finish the previous save", message: "Retry checks the same saved food before synchronizing daily totals.")
        }
    }
    func stop() { generation = UUID(); user = nil; review = nil; attempt = nil; hasAttempt = false; savedID = nil; isWorking = false; error = nil }
    private func key(_ id: UUID, _ date: String) -> String { "execute.cache.\(id.uuidString).food-capture.\(date).pending" }
    private func current(_ request: UUID, _ id: UUID) -> Bool { request == generation && user?.id == id && canAct(id) && !Task.isCancelled }

    func findProduct(_ code: String) async {
        guard !isWorking, !hasAttempt, let user, canAct(user.id) else { return }
        let request = generation; isWorking = true; error = nil; review = nil; savedID = nil
        defer { if request == generation { isWorking = false } }
        do {
            let result = try await lookup.product(code: code)
            guard current(request, user.id) else { return }; review = result
        } catch { if current(request, user.id) { self.error = AppError.from(error, title: "Could not look up product") } }
    }
    func estimatePhoto(_ jpeg: Data) async {
        guard !isWorking, !hasAttempt, let user, canAct(user.id), canUsePhoto(), let ai else { return }
        let request = generation; isWorking = true; error = nil; review = nil; savedID = nil
        defer { if request == generation { isWorking = false } }
        do {
            guard !jpeg.isEmpty, jpeg.count <= 2_000_000,
                  let url = URL(string: "data:image/jpeg;base64," + jpeg.base64EncodedString()) else { throw FoodBarcode.unavailable() }
            let result = try await ai.structuredResponse(LLMRequest(
                prompt: "Analyze the selected food photo. Identify only visible foods and estimate portions and macros. Return separate foods, numeric calories/protein/carbs/fats, and totals. Return foods=[] when no food is visible. Do not identify people or infer hidden ingredients. The user will review and correct the estimates before saving.",
                fileURLs: [url], maxOutputTokens: 1600, responseJSONSchema: NutritionAISchema.response, schemaName: "nutrition_photo_estimate"), as: NutritionAIEstimate.self)
            let value = try FoodPhoto.review(result)
            guard current(request, user.id), canUsePhoto() else { return }; review = value
        } catch { if current(request, user.id) { self.error = AppError.from(error, title: "Could not estimate photo") } }
    }
    func clearReview() { guard !hasAttempt, !isWorking else { return }; review = nil; error = nil; savedID = nil }

    func save(_ edited: FoodCaptureReview, synchronize: () async -> Bool) async -> Bool {
        guard !isWorking, review != nil, savedID == nil || hasAttempt, let user, canAct(user.id), let data,
              DayPlanLogic.date(date) != nil, date <= HomeDate.todayString else { return false }
        let request = generation
        isWorking = true; error = nil
        defer { if request == generation { isWorking = false } }
        do {
            let value = attempt ?? Attempt(review: edited, token: UUID().uuidString.lowercased(), time: NutritionDate.timeString(from: .now))
            let payload = try value.review.payload(date: date, token: value.token, time: value.time)
            // Persist the reviewed values/token, never image bytes. A lost response can resume after relaunch.
            defaults.set(try JSONEncoder().encode(value), forKey: key(user.id, date)); attempt = value; hasAttempt = true
            let rows: [EntityRecord<JSONValue>] = try await data.listAll(.foodLogs, isCurrent: { self.current(request, user.id) })
            guard current(request, user.id) else { return false }
            guard rows.allSatisfy({ $0.ownerID == nil || $0.ownerID == user.id }) else {
                throw AppError(title: "Food save stopped", message: "The loaded food records do not belong to the current account.")
            }
            let matches = rows.filter { $0.payload["native_mutation_id"] == .string(value.token) }
            guard matches.count <= 1 else { throw AppError(title: "Food needs review", message: "Multiple matching entries exist. Refresh your food log before making another attempt.") }
            let saved: EntityRecord<JSONValue>
            if let existing = matches.first {
                guard existing.payload["date"] == .string(date) else { throw AppError(title: "Saved food date changed", message: "Review the existing food log before retrying.") }
                saved = existing
            } else {
                guard value.review.draft.method != .photo || canUsePhoto() else { throw AppError(title: "Premium required", message: "Photo estimates require an active Premium entitlement.") }
                saved = try await data.create(.foodLogs, payload: payload, user: user)
            }
            guard current(request, user.id) else { return false }
            guard saved.ownerID == nil || saved.ownerID == user.id,
                  saved.payload["date"] == .string(date), saved.payload["native_mutation_id"] == .string(value.token) else {
                throw AppError(title: "Food acknowledgment needs verification", message: "Retry checks the saved entry before updating daily totals.")
            }
            savedID = saved.id
            guard await synchronize(), current(request, user.id) else {
                if current(request, user.id) { error = AppError(title: "Food saved; daily totals need refresh", message: "Retry synchronizes this same entry without adding another food.") }; return false
            }
            defaults.removeObject(forKey: key(user.id, date)); attempt = nil; hasAttempt = false
            return true
        } catch {
            if current(request, user.id) { self.error = AppError.from(error, title: "Save needs verification. Retry this same attempt.") }
            return false
        }
    }
}

private extension JSONValue {
    static func decode<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
}

private extension String {
    var captureNonempty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
}
