import Foundation
import Synchronization
import Testing

@testable import TodexCore

struct HTTPClientTests {
    @Test func queryKeysAndValuesRoundTripThroughAxumFormDecoding() throws {
        let client = HTTPClient(connection: .init(serverURL: "HTTPS://EXAMPLE.COM:7345/v2/"))
        let query = ["a+b": "目录/a+b &?#=%2B /🦦", "empty": "", "x&y": "line\r\nnext"]
        let url = try client.url(path: "/v2/workspaces/\(HTTPClient.segment("项目/50%+?#"))/trust", query: query)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "example.com")
        #expect(components.percentEncodedPath == "/v2/workspaces/%E9%A1%B9%E7%9B%AE%2F50%25%2B%3F%23/trust")
        #expect(components.percentEncodedQuery?.contains("+") == false)
        #expect(components.fragment == nil)
        let decoded = try #require(components.percentEncodedQuery).split(separator: "&").reduce(
            into: [String: String]()
        ) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!
            let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!
            result[key] = value
        }
        #expect(decoded == query)
        #expect(
            try client.url(path: "/v2/a%2Fb/中文 file").absoluteString
                == "https://example.com:7345/v2/a%2Fb/%E4%B8%AD%E6%96%87%20file")
        #expect(try client.url(path: "/v2/version").query == nil)
    }

    @Test(arguments: [
        "", "relative", "//evil.example/x", "/path?token=x", "/path#fragment", "/bad%", "/bad%2", "/bad%GG", "/v2/../x",
        "/v2/%2e%2E/x", "/back\\slash", "/line\nfeed",
    ])
    func invalidPathsThrowInsteadOfTrapping(_ path: String) {
        let client = HTTPClient(connection: .init())
        #expect(throws: (any Error).self) { try client.url(path: path) }
    }

    @Test func requestUsesSharedEncodingAndExplicitAuthenticationOnly() async throws {
        let fixture = NetworkHTTPFixture { _ in .json(["ok": true]) }
        defer { fixture.close() }
        let client = fixture.client(token: "secret")
        _ = try await client.request(.post, path: "/v2/example", query: ["q": "a+b"], body: ["value": "text"])
        _ = try await client.request(path: "/v2/transport-policy", authenticated: false)
        let calls = fixture.requests
        #expect(calls.count == 2)
        #expect(calls[0].url?.query == "q=a%2Bb")
        #expect(calls[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(calls[1].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(calls.allSatisfy { !$0.httpShouldHandleCookies && $0.cachePolicy == .reloadIgnoringLocalCacheData })
        #expect(calls[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        let bad = fixture.client(token: "bad\r\nheader")
        await #expect(throws: (any Error).self) { try await bad.request(path: "/v2/version") }
        #expect(fixture.requests.count == 2)
    }

    @Test func policyUsesActualStatusAndCannotSilentlyDowngrade() throws {
        let none = BackendConnection()
        try RealtimeClient.validatePolicy(result(404, "not JSON"), connection: none)
        try RealtimeClient.validatePolicy(result(200, #"{"requiredProtocol":"none"}"#), connection: none)
        let encrypted = BackendConnection(encryption: .x25519, publicKey: "configured")
        try RealtimeClient.validatePolicy(result(200, #"{"requiredProtocol":"none"}"#), connection: encrypted)
        try RealtimeClient.validatePolicy(result(200, #"{"requiredProtocol":"x25519"}"#), connection: encrypted)
        for response in [
            result(401, #"{"code":"NOT_FOUND","message":"no"}"#), result(500, #"{"code":"404"}"#),
            result(200, #"{"requiredProtocol":"ml-kem-768"}"#), result(200, #"{"requiredProtocol":"future"}"#),
            result(200, #"{"requiredProtocol":true}"#), result(200, "[]"), result(200, ""),
        ] {
            #expect(throws: (any Error).self) { try RealtimeClient.validatePolicy(response, connection: encrypted) }
        }
        #expect(throws: (any Error).self) {
            try RealtimeClient.validatePolicy(result(404, ""), connection: .init(encryption: .x25519))
        }
        #expect(throws: (any Error).self) {
            try RealtimeClient.validatePolicy(result(200, #"{"requiredProtocol":"x25519"}"#), connection: none)
        }
    }

    @Test func rawResponseLimitsCoverDeclaredAndChunkedBodies() async throws {
        for headers in [["Content-Length": "10000"], [:]] {
            let fixture = NetworkHTTPFixture { _ in
                NetworkHTTPReply(status: 200, data: Data(repeating: 32, count: 4096), headers: headers)
            }
            defer { fixture.close() }
            await #expect(throws: (any Error).self) {
                try await fixture.client().response(path: "/v2/transport-policy", maximumBytes: 2048)
            }
            #expect(fixture.requests.count == 1)
        }
        let exact = NetworkHTTPFixture { _ in NetworkHTTPReply(status: 200, data: Data("{}".utf8)) }
        defer { exact.close() }
        #expect(try await exact.client().response(path: "/test", maximumBytes: 2).json() == [:])
    }

    @Test func deadlinesCancelAndMutationsNeverRetry() async throws {
        let stalled = NetworkHTTPFixture { _ in nil }
        defer { stalled.close() }
        do {
            _ = try await stalled.client().response(path: "/read", timeout: 0.02)
            Issue.record("Expected timeout")
        } catch let error as URLError { #expect(error.code == .timedOut) }
        do {
            _ = try await stalled.client().response(.post, path: "/write", timeout: 0.02)
            Issue.record("Expected unknown outcome")
        } catch TodexError.unknownOutcome {}
        #expect(stalled.requests.count == 2)
        let broken = NetworkHTTPFixture { _ in throw URLError(.networkConnectionLost) }
        defer { broken.close() }
        do {
            _ = try await broken.client().request(.delete, path: "/write")
            Issue.record("Expected unknown outcome")
        } catch TodexError.unknownOutcome {}
        #expect(broken.requests.count == 1)
    }

    @Test func malformedMutationConfirmationAndStructuredHTTPErrorRemainDistinct() async throws {
        let invalid = NetworkHTTPFixture { _ in NetworkHTTPReply(status: 200, data: Data("bad JSON".utf8)) }
        defer { invalid.close() }
        do {
            _ = try await invalid.client().request(.put, path: "/write")
            Issue.record("Expected unknown outcome")
        } catch TodexError.unknownOutcome {}
        let rejected = NetworkHTTPFixture { _ in
            .json(["error": ["code": "CONFLICT", "message": "changed"]], status: 409)
        }
        defer { rejected.close() }
        do {
            _ = try await rejected.client().request(.post, path: "/write")
            Issue.record("Expected server rejection")
        } catch TodexError.server(let code, let message) { #expect(code == "CONFLICT" && message == "changed") }
        #expect(rejected.requests.count == 1)
    }

    private func result(_ status: Int, _ body: String) -> HTTPResult {
        HTTPResult(statusCode: status, data: Data(body.utf8))
    }
}

// Shared only by the two transport test files. Each fixture has a distinct host,
// its own session and mutex-protected handler; parallel tests cannot cross-talk.
struct NetworkHTTPReply: Sendable {
    let status: Int
    let data: Data
    var headers: [String: String] = [:]
    static func json(_ value: JSONValue, status: Int = 200) -> Self {
        .init(status: status, data: Data(value.prettyPrinted.utf8))
    }
}
final class NetworkHTTPFixture: Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> NetworkHTTPReply?
    private let host = UUID().uuidString.lowercased() + ".invalid"
    let session: URLSession
    private let calls = Mutex<[URLRequest]>([])
    init(_ handler: @escaping Handler) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetworkURLProtocol.self]
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
        NetworkURLProtocol.handlers.withLock {
            $0[host] = { [weak self] request in
                self?.calls.withLock { $0.append(request) }
                return try handler(request)
            }
        }
    }
    var requests: [URLRequest] { calls.withLock { $0 } }
    func client(token: String = "") -> HTTPClient {
        HTTPClient(connection: .init(serverURL: "https://\(host)", token: token), session: session)
    }
    func close() {
        session.invalidateAndCancel()
        _ = NetworkURLProtocol.handlers.withLock { $0.removeValue(forKey: host) }
    }
}
private final class NetworkURLProtocol: URLProtocol, @unchecked Sendable {
    static let handlers = Mutex<[String: NetworkHTTPFixture.Handler]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let host = request.url?.host, let handler = Self.handlers.withLock({ $0[host] }) else {
                throw URLError(.badURL)
            }
            guard let reply = try handler(request) else { return }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
