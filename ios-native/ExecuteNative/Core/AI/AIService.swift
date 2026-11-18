import Combine
import Foundation
import Supabase

struct LLMRequest: Encodable, Sendable {
    let prompt: String
    let fileURLs: [URL]
    let maxOutputTokens: Int?
    let responseJSONSchema: JSONValue?
    let schemaName: String?
    let inputFile: LLMInputFile?
    private(set) var ownerID: UUID? = nil
    init(prompt: String, fileURLs: [URL], maxOutputTokens: Int?, responseJSONSchema: JSONValue?, schemaName: String?, inputFile: LLMInputFile? = nil) {
        self.prompt = prompt; self.fileURLs = fileURLs; self.maxOutputTokens = maxOutputTokens
        self.responseJSONSchema = responseJSONSchema; self.schemaName = schemaName; self.inputFile = inputFile
    }

    // The originating account is checked by the native transport and stays out of the request body.
    func owned(by ownerID: UUID?) -> Self {
        var bound = self
        bound.ownerID = ownerID
        return bound
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case fileURLs = "file_urls"
        case maxOutputTokens = "max_output_tokens"
        case responseJSONSchema = "response_json_schema"
        case schemaName = "schema_name"
        case inputFile = "input_file"
    }
}

struct LLMInputFile: Encodable, Sendable {
    let filename: String
    let fileData: String
    enum CodingKeys: String, CodingKey { case filename; case fileData = "file_data" }
}

struct LLMTextResponse: Decodable, Sendable {
    let text: String?
    let outputText: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case text
        case outputText = "output_text"
        case error
    }

    var resolvedText: String? { outputText ?? text }
}

@MainActor
protocol AIResponding {
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response
    func textResponse(_ request: LLMRequest) async throws -> String
}

@MainActor
final class AISharingConsent: ObservableObject {
    static let disclosure = """
        Execute sends information needed for AI features to OpenAI to generate plans, answer questions, estimate nutrition, and provide coaching. This can include your profile, goals, workout, nutrition and recovery history, injury information, prompts, and photos or PDFs you select for AI processing.

        AI sharing is optional. You can change this permission in Profile & Settings. If you opened this from an AI feature, retry the action after allowing sharing.
        """
    static let required = AppError(
        title: "AI sharing permission required",
        message: "Review AI Data Sharing in Profile & Settings, then retry if you choose to allow it."
    )
    private static let version = 1
    private static let denied = -1

    @Published private(set) var promptOwner: UUID?
    private let defaults: UserDefaults
    private let canShare: (UUID) -> Bool

    init(defaults: UserDefaults = .standard, canShare: @escaping (UUID) -> Bool) {
        self.defaults = defaults
        self.canShare = canShare
    }

    func isAllowed(for ownerID: UUID) -> Bool {
        canShare(ownerID) && defaults.integer(forKey: key(ownerID)) == Self.version
    }

    func showPrompt(for ownerID: UUID) {
        guard canShare(ownerID), promptOwner != ownerID else { return }
        promptOwner = ownerID
    }

    func resolvePrompt(for ownerID: UUID, allow: Bool) {
        guard promptOwner == ownerID else { return }
        if canShare(ownerID) {
            defaults.set(allow ? Self.version : Self.denied, forKey: key(ownerID))
        }
        promptOwner = nil
    }

    func dismissPrompt() {
        promptOwner = nil
    }

    func revoke(for ownerID: UUID) {
        guard canShare(ownerID) else { return }
        objectWillChange.send()
        defaults.set(Self.denied, forKey: key(ownerID))
        if promptOwner == ownerID { dismissPrompt() }
    }

    func requirePermission(for ownerID: UUID?) throws -> UUID {
        try Task.checkCancellation()
        guard let ownerID, canShare(ownerID) else { throw CancellationError() }
        guard isAllowed(for: ownerID) else {
            if defaults.integer(forKey: key(ownerID)) != Self.denied { showPrompt(for: ownerID) }
            throw Self.required
        }
        return ownerID
    }

    private func key(_ ownerID: UUID) -> String {
        "execute.cache.\(ownerID.uuidString).privacy.ai-sharing-consent"
    }
}

struct ConsentedAIRequestInvoker: EdgeFunctionInvoking {
    let functions: FunctionsClient
    let consent: AISharingConsent
    let getSession: () async throws -> Session

    func invoke<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ name: String, request: Request, response: Response.Type
    ) async throws -> Response {
        guard name == "invoke-llm", let request = request as? LLMRequest else { throw CancellationError() }
        let ownerID = try consent.requirePermission(for: request.ownerID)
        let session = try await getSession()
        try Task.checkCancellation()
        guard session.user.id == ownerID, consent.isAllowed(for: ownerID) else { throw CancellationError() }
        // Keep the checked bearer attached to this request even if the shared Auth client switches.
        return try await functions.invoke(name, options: .init(
            headers: ["Authorization": "Bearer \(session.accessToken)"], body: request
        ), decoder: .execute)
    }
}

final class SupabaseAIService: AIResponding {
    private let functions: EdgeFunctionInvoking

    init(functions: EdgeFunctionInvoking) { self.functions = functions }

    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        let response: StructuredAIResponse<Response> = try await functions.invoke(
            "invoke-llm", request: request, response: StructuredAIResponse<Response>.self)
        return response.value
    }

    func textResponse(_ request: LLMRequest) async throws -> String {
        let response: LLMTextResponse = try await functions.invoke("invoke-llm", request: request, response: LLMTextResponse.self)
        if let error = response.error { throw AppError(title: "AI request failed", message: error) }
        guard let text = response.resolvedText, !text.isEmpty else {
            throw AppError(title: "AI returned no response", message: "The secure AI service returned an empty result.")
        }
        return text
    }
}

/// Decode both supported shapes from the same response. Retrying a decode must never
/// repeat the provider request, including when transport or cancellation already failed.
private struct StructuredAIResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value
    init(from decoder: Decoder) throws {
        do {
            value = try Value(from: decoder)
        } catch {
            let originalError = error
            guard let wrapped = try? LLMTextResponse(from: decoder), let text = wrapped.resolvedText else {
                throw originalError
            }
            value = try AIResponseNormalizer.decode(Value.self, from: text)
        }
    }
}

enum AIResponseNormalizer {
    static func decode<Response: Decodable>(_ type: Response.Type, from text: String) throws -> Response {
        let candidates = [text, removeMarkdownFence(from: text), firstJSONObject(in: text)].compactMap { $0 }
        for candidate in candidates {
            if let decoded = try? JSONDecoder.execute.decode(Response.self, from: Data(candidate.utf8)) {
                return decoded
            }
        }
        throw AppError(title: "AI response could not be read", message: "The response was not valid for the requested result.")
    }

    private static func removeMarkdownFence(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), let firstNewline = trimmed.firstIndex(of: "\n"), trimmed.hasSuffix("```") else { return nil }
        return String(trimmed[trimmed.index(after: firstNewline)..<trimmed.index(trimmed.endIndex, offsetBy: -3)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var insideString = false
        var escaped = false
        for index in text[start...].indices {
            let character = text[index]
            if insideString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { insideString = false }
                continue
            }
            if character == "\"" { insideString = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
        }
        return nil
    }
}

final class MockAIService: AIResponding {
    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        throw AppError(title: "Preview AI", message: "A preview has no configured AI response.")
    }
    func textResponse(_ request: LLMRequest) async throws -> String { "Preview response" }
}
