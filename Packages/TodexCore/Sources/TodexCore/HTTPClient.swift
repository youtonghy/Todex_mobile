import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public final class HTTPClient: Sendable {
    public let connection: BackendConnection
    private let session: URLSession

    public init(connection: BackendConnection, session: URLSession? = nil) {
        self.connection = connection
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 45
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    /// Paths may contain already escaped segments produced by segment(_:).
    /// Query keys/values are always raw strings, encoded once for Axum's form decoder.
    public func url(path: String, query: [String: String] = [:]) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("?"), !path.contains("#"),
            !path.contains("\\"),
            !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { throw TodexError.invalid("接口路径无效") }
        let bytes = Array(path.utf8)
        var escaped = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 37 {
                guard index + 2 < bytes.count, Self.isHex(bytes[index + 1]), Self.isHex(bytes[index + 2]) else {
                    throw TodexError.invalid("接口路径转义无效")
                }
                escaped += String(decoding: bytes[index...index + 2], as: UTF8.self)
                index += 3
            } else {
                escaped += byte == 47 || Self.isUnreserved(byte) ? String(UnicodeScalar(byte)) : Self.escape(byte)
                index += 1
            }
        }
        guard
            !escaped.split(separator: "/").contains(where: {
                let decoded = String($0).removingPercentEncoding
                return decoded == "." || decoded == ".."
            }),
            var components = URLComponents(url: try connection.normalizedURL(), resolvingAgainstBaseURL: false)
        else { throw TodexError.invalid("接口路径无效") }
        components.percentEncodedPath = escaped
        // URLQueryItem leaves '+' literal, which form decoding turns into a space.
        components.percentEncodedQuery =
            query.isEmpty
            ? nil
            : query.sorted { $0.key < $1.key }.map { "\(Self.segment($0.key))=\(Self.segment($0.value))" }.joined(
                separator: "&")
        guard let url = components.url else { throw TodexError.invalid("接口地址无效") }
        return url
    }

    public static func segment(_ value: String) -> String {
        value.utf8.map { isUnreserved($0) ? String(UnicodeScalar($0)) : escape($0) }.joined()
    }

    public func request(
        _ method: HTTPMethod = .get, path: String, query: [String: String] = [:], body: JSONValue? = nil,
        authenticated: Bool = true
    ) async throws -> JSONValue {
        let result = try await response(method, path: path, query: query, body: body, authenticated: authenticated)
        return try result.json(method: method)
    }

    /// Keeps the actual HTTP status for transport policy discovery: only HTTP
    /// 404 permits the older-backend fallback, never a body claiming NOT_FOUND.
    func response(
        _ method: HTTPMethod = .get, path: String, query: [String: String] = [:], body: JSONValue? = nil,
        authenticated: Bool = true, timeout: TimeInterval = 30, maximumBytes: Int = 20 * 1024 * 1024
    ) async throws -> HTTPResult {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 3600, maximumBytes > 0 else {
            throw TodexError.invalid("HTTP 请求限制无效")
        }
        var request = URLRequest(
            url: try url(path: path, query: query), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout
        )
        request.httpMethod = method.rawValue
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated && !connection.token.isEmpty {
            guard !connection.token.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }) else {
                throw TodexError.invalid("认证令牌包含换行")
            }
            request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let preparedRequest = request
        do {
            return try await withThrowingTaskGroup(of: HTTPResult.self) { group in
                group.addTask { [session] in
                    // Read incrementally so oversized/chunked responses do not
                    // need to be buffered in full before enforcing the limit.
                    let (bytes, response) = try await session.bytes(
                        for: preparedRequest, delegate: NoRedirectDelegate())
                    defer { bytes.task.cancel() }
                    guard let http = response as? HTTPURLResponse else { throw TodexError.invalid("后端响应无效") }
                    guard http.expectedContentLength <= maximumBytes else { throw TodexError.invalid("后端响应过大") }
                    var data = Data()
                    for try await byte in bytes {
                        guard data.count < maximumBytes else { throw TodexError.invalid("后端响应过大") }
                        data.append(byte)
                    }
                    try Task.checkCancellation()
                    return HTTPResult(statusCode: http.statusCode, data: data)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                try Task.checkCancellation()
                return result
            }
        } catch {
            // Once handed to URLSession, cancellation/timeout/invalid responses
            // cannot prove a mutation was not applied. Never retry here.
            if method != .get { throw TodexError.unknownOutcome("未收到后端完整确认") }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || [45, 46, 95, 126].contains(byte)
    }
    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
    private static func escape(_ byte: UInt8) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        return String(decoding: [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]], as: UTF8.self)
    }
}

struct HTTPResult: Sendable {
    let statusCode: Int
    let data: Data

    func json(method: HTTPMethod = .get) throws -> JSONValue {
        let value = data.isEmpty ? JSONValue.null : (try? JSONDecoder().decode(JSONValue.self, from: data))
        guard (200..<300).contains(statusCode) else {
            let code = value?["code"].optionalString ?? value?["error"]["code"].optionalString ?? String(statusCode)
            let message =
                value?["message"].optionalString ?? value?["error"]["message"].optionalString ?? value?["error"]
                .optionalString ?? "HTTP \(statusCode)"
            throw TodexError.server(code: code, message: message)
        }
        guard String(data: data, encoding: .utf8) != nil, let value else {
            if method != .get { throw TodexError.unknownOutcome("后端返回的确认不是有效 JSON") }
            throw TodexError.invalid("后端未返回有效 JSON")
        }
        return value
    }
}
