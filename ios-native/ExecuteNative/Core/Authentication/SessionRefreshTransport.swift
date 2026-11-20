import CryptoKit
import Foundation

/// Only the refresh grant uses this transport. Other Auth grants and all data
/// requests keep their normal URLSession handling.
class SessionRefreshProtocol: URLProtocol, @unchecked Sendable {
    private static let sharedBackoff = SessionRefreshBackoff()
    class var gate: SessionRefreshBackoff { sharedBackoff }
    class var upstream: URLSession { .shared }
    private var loading: Task<Void, Never>?

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [SessionRefreshProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard request.httpMethod == "POST", let url = request.url,
              url.path.hasSuffix("/auth/v1/token") else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ) == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        loading = Task {
            do {
                var outgoing = request
                // Foundation can present a POST body as a stream to a URLProtocol.
                let body: Data
                if let data = outgoing.httpBody {
                    body = data
                } else if let stream = outgoing.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    var data = Data()
                    while true {
                        let count = stream.read(&bytes, maxLength: bytes.count)
                        guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                        if count == 0 { break }
                        data.append(contentsOf: bytes.prefix(count))
                    }
                    body = data
                    outgoing.httpBody = data
                } else {
                    throw URLError(.badURL)
                }
                var hash = SHA256()
                hash.update(data: Data((outgoing.url?.absoluteString ?? "").utf8))
                hash.update(data: body)
                let key = Data(hash.finalize())
                let transport = Self.upstream
                let wireRequest = outgoing
                let (data, response) = try await Self.gate.perform(key: key) {
                    try await transport.data(for: wireRequest)
                }
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
    }

    override func stopLoading() { loading?.cancel() }
}

actor SessionRefreshBackoff {
    private struct Failure {
        let delay: TimeInterval
        let retryAt: TimeInterval
    }
    private var failures: [Data: Failure] = [:]
    private let now: @Sendable () -> TimeInterval
    private let jitter: @Sendable () -> Double

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.2) }) {
        self.now = now
        self.jitter = jitter
    }

    func perform(key: Data, send: @Sendable () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let tick = now()
        failures = failures.filter { $0.value.retryAt + 600 > tick }
        if let failure = failures[key], tick < failure.retryAt {
            throw URLError(.resourceUnavailable)
        }
        // The Auth SDK already coalesces simultaneous refreshes on its client.
        do {
            let result = try await send()
            if let http = result.1 as? HTTPURLResponse,
               http.statusCode == 429 || (500...599).contains(http.statusCode) {
                recordFailure(key, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            } else {
                failures.removeValue(forKey: key)
            }
            return result
        } catch {
            if let error = error as? URLError, error.code != .cancelled, !Task.isCancelled {
                recordFailure(key, retryAfter: nil)
            }
            throw error
        }
    }

    private func recordFailure(_ key: Data, retryAfter: String?) {
        let delay = min((failures[key]?.delay ?? 30) * 2, 300)
        var wait = min(delay * (1 + jitter()), 300)
        if let retryAfter, let seconds = TimeInterval(retryAfter), seconds.isFinite {
            wait = max(wait, seconds)
        } else if let retryAfter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: retryAfter) { wait = max(wait, date.timeIntervalSinceNow) }
        }
        failures[key] = Failure(delay: delay, retryAt: now() + wait)
    }
}
