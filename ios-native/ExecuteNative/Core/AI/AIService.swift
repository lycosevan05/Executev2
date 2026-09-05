import Foundation

struct LLMRequest: Encodable, Sendable {
    let prompt: String
    let fileURLs: [URL]
    let maxOutputTokens: Int?
    let responseJSONSchema: JSONValue?
    let schemaName: String?

    enum CodingKeys: String, CodingKey {
        case prompt
        case fileURLs = "file_urls"
        case maxOutputTokens = "max_output_tokens"
        case responseJSONSchema = "response_json_schema"
        case schemaName = "schema_name"
    }
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

final class SupabaseAIService: AIResponding {
    private let functions: EdgeFunctionInvoking

    init(functions: EdgeFunctionInvoking) { self.functions = functions }

    func structuredResponse<Response: Decodable & Sendable>(_ request: LLMRequest, as type: Response.Type) async throws -> Response {
        do {
            return try await functions.invoke("invoke-llm", request: request, response: Response.self)
        } catch {
            // Some older records and model responses are wrapped in markdown or an alternate JSON shape.
            let wrapped: LLMTextResponse = try await functions.invoke("invoke-llm", request: request, response: LLMTextResponse.self)
            guard let text = wrapped.resolvedText else { throw error }
            return try AIResponseNormalizer.decode(Response.self, from: text)
        }
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
