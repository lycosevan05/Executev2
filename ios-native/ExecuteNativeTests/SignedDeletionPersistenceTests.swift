import Security
import Supabase
import XCTest
@testable import ExecuteNative

@MainActor
final class SignedDeletionPersistenceTests: XCTestCase {
    private static let origin = "https://127.0.0.1:55474"
    private static let sessionKey = "sb-127-auth-token"
    private static let fixtureDate = "2026-11-18"
    private enum Failure: Error { case invalidFixture, wrongActiveSession }

    func testCacheAndKeychainArePresentBeforeDeletion() throws {
        let (target, witness) = try fixture()
        let rawSession = try XCTUnwrap(AuthClient.Configuration.defaultLocalStorage.retrieve(key: Self.sessionKey))
        let session = try JSONDecoder().decode(Session.self, from: rawSession)
        guard session.user.id == target else { throw Failure.wrongActiveSession }
        for owner in [target, witness] {
            XCTAssertNotNil(UserDefaults.standard.data(forKey: "execute.cache.\(owner.uuidString).home.dashboard"))
            let intent = NutritionWeekWaterIntent(token: owner, owner: owner, date: Self.fixtureDate,
                                                  rowID: nil, original: .null, liters: 0.25)
            let data = try JSONEncoder().encode(intent)
            UserDefaults.standard.set(data, forKey: waterKey(owner))
            XCTAssertEqual(UserDefaults.standard.data(forKey: waterKey(owner)), data)
        }
    }

    func testCacheAndKeychainArePurgedAfterDeletion() throws {
        let (target, witness) = try fixture()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "supabase.gotrue.swift",
            kSecAttrAccount as String: Self.sessionKey,
        ]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "execute.auth.storage.removalFailed.\(Self.sessionKey)"))
        let keys = UserDefaults.standard.dictionaryRepresentation().keys
        XCTAssertFalse(keys.contains { $0.hasPrefix("execute.cache.\(target.uuidString).") })
        XCTAssertNil(UserDefaults.standard.data(forKey: waterKey(target)))
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "execute.cache.\(witness.uuidString).home.dashboard"))
        let raw = try XCTUnwrap(UserDefaults.standard.data(forKey: waterKey(witness)))
        let intent = try JSONDecoder().decode(NutritionWeekWaterIntent.self, from: raw)
        XCTAssertEqual(intent.owner, witness)
        XCTAssertEqual(intent.liters, 0.25)
    }

    private func fixture() throws -> (target: UUID, witness: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard env["EXECUTE_E68_SIGNED_DELETION"] == "1" else {
            throw XCTSkip("Requires the isolated signed E68 deletion fixture")
        }
        guard try AppConfiguration.load().supabaseURL.absoluteString == Self.origin else { throw Failure.invalidFixture }
        let target = try XCTUnwrap(env["EXECUTE_STAGED_DELETION_OWNER_UUID"].flatMap(UUID.init(uuidString:)))
        let witness = try XCTUnwrap(env["EXECUTE_E68_WITNESS_UUID"].flatMap(UUID.init(uuidString:)))
        guard target != witness else { throw Failure.invalidFixture }
        return (target, witness)
    }

    private func waterKey(_ owner: UUID) -> String {
        "Execute.NutritionWater.\(owner.uuidString).\(Self.fixtureDate)"
    }
}
