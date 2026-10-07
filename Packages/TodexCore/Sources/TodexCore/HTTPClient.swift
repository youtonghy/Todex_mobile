import CryptoKit
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
    private let bootstrap: Bool
    /// Transport v2 "Client rules": with a pinned key every request goes
    /// through `POST /v2/sealed` (loopback included); a remote profile
    /// without one is refused before touching the network; only an unpinned
    /// loopback profile talks plaintext.
    public var transportMode: SecureTransportMode {
        bootstrap ? .plaintext : .resolve(connection)
    }

    public convenience init(connection: BackendConnection, session: URLSession? = nil) {
        self.init(connection: connection, session: session, bootstrap: false)
    }

    /// Device pairing runs before the device is enrolled and, for a remote
    /// backend, straight after importing the key: the backend serves
    /// `/v2/device-pairing/*` directly to every peer, and pairing v3 protects
    /// itself (commit/reveal, verification code, transcript-bound wrap). This
    /// client reaches only those routes, unsigned and never through the tunnel.
    static func pairingBootstrap(connection: BackendConnection, session: URLSession? = nil) -> HTTPClient {
        HTTPClient(connection: connection, session: session, bootstrap: true)
    }

    private init(connection: BackendConnection, session: URLSession?, bootstrap: Bool) {
        self.connection = connection
        self.bootstrap = bootstrap
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
        else { throw TodexError.invalid(String(localized: "接口路径无效", bundle: .module)) }
        let bytes = Array(path.utf8)
        var escaped = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 37 {
                guard index + 2 < bytes.count, Self.isHex(bytes[index + 1]), Self.isHex(bytes[index + 2]) else {
                    throw TodexError.invalid(String(localized: "接口路径转义无效", bundle: .module))
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
        else { throw TodexError.invalid(String(localized: "接口路径无效", bundle: .module)) }
        components.percentEncodedPath = escaped
        // URLQueryItem leaves '+' literal, which form decoding turns into a space.
        components.percentEncodedQuery =
            query.isEmpty
            ? nil
            : query.sorted { $0.key < $1.key }.map { "\(Self.segment($0.key))=\(Self.segment($0.value))" }.joined(
                separator: "&")
        guard let url = components.url else { throw TodexError.invalid(String(localized: "接口地址无效", bundle: .module)) }
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

    /// Sends caller-owned JSON bytes verbatim. JSONValue stores numbers as
    /// Double and reorders keys, so opaque documents such as provider export
    /// files use this to reach the backend exactly as read.
    public func request(
        _ method: HTTPMethod, path: String, jsonData: Data, authenticated: Bool = true
    ) async throws -> JSONValue {
        let result = try await response(method, path: path, rawBody: jsonData, authenticated: authenticated)
        return try result.json(method: method)
    }

    /// Keeps the actual HTTP status, headers and bytes for callers that need
    /// more than JSON. Under transport v2 the status, headers and body are the authenticated
    /// inner response; the outer `/v2/sealed` exchange stays invisible.
    func response(
        _ method: HTTPMethod = .get, path: String, query: [String: String] = [:], body: JSONValue? = nil,
        rawBody: Data? = nil, headers extraHeaders: [String: String] = [:], authenticated: Bool = true,
        timeout: TimeInterval = 30, maximumBytes: Int = 20 * 1024 * 1024
    ) async throws -> HTTPResult {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 3600, maximumBytes > 0, body == nil || rawBody == nil else {
            throw TodexError.invalid(String(localized: "HTTP 请求限制无效", bundle: .module))
        }
        let mode = transportMode
        try mode.requireAllowed()
        if bootstrap {
            guard path.hasPrefix("/v2/device-pairing/"), !authenticated else {
                throw TodexError.invalid(String(localized: "接口路径无效", bundle: .module))
            }
        }
        let requestURL = try url(path: path, query: query)
        let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        let encodedPath = components?.percentEncodedPath ?? "/"
        let encodedQuery = components?.percentEncodedQuery ?? ""
        var headers = ["accept": "application/json"]
        let bodyData = try body.map { try JSONEncoder().encode($0) } ?? rawBody ?? Data()
        if body != nil || rawBody != nil { headers["content-type"] = "application/json" }
        for (name, value) in extraHeaders { headers[name.lowercased()] = value }
        if authenticated, let device = DeviceIdentity(secretKeyBase64URL: connection.deviceSecret) {
            // Sign the percent-encoded request target exactly as it appears on
            // the wire (or in the inner request); the daemon verifies
            // uri.path() + canonicalized query.
            let target = encodedPath + (encodedQuery.isEmpty ? "" : "?\(encodedQuery)")
            for (key, value) in try device.authHeaders(method: method.rawValue, pathAndQuery: target, body: bodyData) {
                headers[key] = value
            }
        }
        var request: URLRequest
        var sealing: SealingInput?
        if case .v2(let encryption) = mode {
            request = URLRequest(
                url: try url(path: TransportV2.sealedPath), cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: timeout)
            request.httpMethod = HTTPMethod.post.rawValue
            sealing = SealingInput(
                inner: TransportInnerRequest(
                    method: method.rawValue, path: encodedPath, query: encodedQuery, headers: headers, body: bodyData),
                encryption: encryption, serverPublicKey: try pinnedServerKey())
        } else {
            request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.httpMethod = method.rawValue
            if body != nil || rawBody != nil { request.httpBody = bodyData }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        }
        request.httpShouldHandleCookies = false
        let preparedRequest = request
        let sealingInput = sealing
        let outcome: Outcome
        do {
            outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask { [session] in
                    if let sealingInput {
                        return try await Self.exchangeSealed(
                            session: session, request: preparedRequest, input: sealingInput, maximumBytes: maximumBytes)
                    }
                    // Read incrementally so oversized/chunked responses do not
                    // need to be buffered in full before enforcing the limit.
                    let (bytes, response) = try await session.bytes(
                        for: preparedRequest, delegate: NoRedirectDelegate())
                    defer { bytes.task.cancel() }
                    guard let http = response as? HTTPURLResponse else { throw TodexError.invalid(String(localized: "后端响应无效", bundle: .module)) }
                    let data = try await Self.read(bytes, response: http, limit: maximumBytes)
                    try Task.checkCancellation()
                    return .result(HTTPResult(statusCode: http.statusCode, data: data, headers: Self.headers(of: http)))
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
            if method != .get { throw TodexError.unknownOutcome(String(localized: "未收到后端完整确认", bundle: .module)) }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        switch outcome {
        case .result(let result): return result
        case .unsealed(let result):
            // Clarification 10: an unsealed answer to a sealed request is not
            // authenticated. Errors (400 TRANSPORT_CRYPTO_FAILED, 426, ...)
            // surface as plain API errors; a "success" is a crypto failure.
            guard !(200..<300).contains(result.statusCode) else { throw TransportCryptoError("unsealed success response") }
            do { _ = try result.json(method: method) } catch { throw SecureTransportError.outerRejection(error) }
            throw TodexError.server(code: String(result.statusCode), message: "HTTP \(result.statusCode)")
        }
    }

    /// The pinned server static public key, validated for its protocol up
    /// front so a sealed request can only fail after it was sent for reasons
    /// outside the profile. Unusable keys are a profile problem a reconnect
    /// cannot fix.
    func pinnedServerKey() throws -> Data {
        do {
            let encryption = connection.encryption
            let key = try CryptoEncoding.decode(
                connection.publicKey.trimmingCharacters(in: .whitespacesAndNewlines),
                count: encryption == .mlkem768 ? TransportV2.mlkemPublicKeyLength : TransportV2.x25519PublicKeyLength)
            switch encryption {
            case .none: throw TransportCryptoError("no transport protocol")
            // Checking only length admits low-order points such as zero.
            case .x25519: _ = try CryptoEncoding.sharedSecret(privateKey: .init(), publicKey: key)
            case .mlkem768: _ = try MLKEM768.PublicKey(rawRepresentation: key)
            }
            return key
        } catch {
            throw TodexError.configuration(String(localized: "加密公钥无法使用：\(error.localizedDescription)", bundle: .module))
        }
    }

    private struct SealingInput: Sendable {
        let inner: TransportInnerRequest
        let encryption: EncryptionProtocol
        let serverPublicKey: Data
    }

    private enum Outcome: Sendable {
        case result(HTTPResult)
        /// Outer response without the sealed content type or status 200.
        case unsealed(HTTPResult)
    }

    /// Seals, sends and stream-opens one tunnelled request. Ciphers live and
    /// die inside this task; the inner body limit applies to the plaintext.
    private static func exchangeSealed(
        session: URLSession, request: URLRequest, input: SealingInput, maximumBytes: Int
    ) async throws -> Outcome {
        // The key was validated by `pinnedServerKey()`.
        let sealed = try TransportRestTunnel.seal(
            input.inner, encryption: input.encryption, serverPublicKey: input.serverPublicKey)
        let decoder = TransportSealedResponseDecoder(cipher: sealed.responseCipher)
        defer { decoder.dispose() }
        var outer = request
        outer.httpBody = sealed.body
        for (name, value) in sealed.headers { outer.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: outer, delegate: NoRedirectDelegate())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw TodexError.invalid(String(localized: "后端响应无效", bundle: .module)) }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard http.statusCode == 200, contentType == TransportV2.sealedContentType else {
            let data = try await read(bytes, response: http, limit: 64 * 1024)
            return .unsealed(HTTPResult(statusCode: http.statusCode, data: data, headers: headers(of: http)))
        }
        // Outer bytes = inner body + head + per-record framing and tags.
        let records = (maximumBytes + 4 + TransportV2.maxHeadBytes) / TransportV2.recordPlaintextMax + 1
        let outerLimit = maximumBytes + 4 + TransportV2.maxHeadBytes + records * (4 + TransportV2.tagLength)
        var received = 0
        var chunk = Data()
        chunk.reserveCapacity(16 * 1024)
        var body = Data()
        func drain() throws {
            for part in try decoder.push(chunk) {
                guard body.count + part.count <= maximumBytes else { throw TodexError.invalid(String(localized: "后端响应过大", bundle: .module)) }
                body += part
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for try await byte in bytes {
            received += 1
            guard received <= outerLimit else { throw TodexError.invalid(String(localized: "后端响应过大", bundle: .module)) }
            chunk.append(byte)
            if chunk.count >= 16 * 1024 { try drain() }
        }
        try drain()
        try decoder.finish()
        try Task.checkCancellation()
        guard let head = decoder.head else { throw TransportCryptoError("truncated before inner head") }
        return .result(HTTPResult(statusCode: head.status, data: body, headers: head.headers))
    }

    private static func read(_ bytes: URLSession.AsyncBytes, response: HTTPURLResponse, limit: Int) async throws -> Data {
        guard response.expectedContentLength <= limit else { throw TodexError.invalid(String(localized: "后端响应过大", bundle: .module)) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw TodexError.invalid(String(localized: "后端响应过大", bundle: .module)) }
            data.append(byte)
        }
        return data
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        Dictionary(
            response.allHeaderFields.compactMap { key, value in
                (key as? String).map { ($0.lowercased(), String(describing: value)) }
            }, uniquingKeysWith: { _, last in last })
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
    /// Lowercase names (the inner response's under transport v2).
    var headers: [String: String] = [:]

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
            if method != .get { throw TodexError.unknownOutcome(String(localized: "后端返回的确认不是有效 JSON", bundle: .module)) }
            throw TodexError.invalid(String(localized: "后端未返回有效 JSON", bundle: .module))
        }
        return value
    }
}
