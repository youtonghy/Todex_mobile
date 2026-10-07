import CryptoKit
import Foundation
import Synchronization

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

    /// Device pairing runs before the device is enrolled and before any
    /// transport key is pinned (pairing is what pins it): the backend serves
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

    /// Defaults for one request: the whole exchange, and the (inner) body read.
    public static let defaultTimeout: TimeInterval = 30
    public static let defaultMaximumBytes = 20 * 1024 * 1024

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
    ///
    /// Two authenticated answers are retried once, re-signed with a fresh
    /// nonce, whatever the method: an inner `503 TRANSPORT_BUSY` (the backend
    /// guarantees the request did not run and its nonce was not spent) after
    /// `Retry-After` (at most 5 s), and a `401 AUTH_TIMESTAMP_REJECTED` after
    /// recording the backend's clock offset from its `serverTime`. Unsealed
    /// answers on the tunnel are never trusted for either.
    func response(
        _ method: HTTPMethod = .get, path: String, query: [String: String] = [:], body: JSONValue? = nil,
        rawBody: Data? = nil, headers extraHeaders: [String: String] = [:], authenticated: Bool = true,
        timeout: TimeInterval = HTTPClient.defaultTimeout, maximumBytes: Int = HTTPClient.defaultMaximumBytes
    ) async throws -> HTTPResult {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 3600, maximumBytes > 0, body == nil || rawBody == nil else {
            throw TodexError.invalid(String(localized: "HTTP 请求限制无效", bundle: .module))
        }
        let mode = transportMode
        try mode.requireAllowed(connection)
        if bootstrap {
            guard path.hasPrefix("/v2/device-pairing/"), !authenticated else {
                throw TodexError.invalid(String(localized: "接口路径无效", bundle: .module))
            }
        }
        let requestURL = try url(path: path, query: query)
        let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        var headers = ["accept": "application/json"]
        let bodyData = try body.map { try JSONEncoder().encode($0) } ?? rawBody ?? Data()
        let hasBody = body != nil || rawBody != nil
        if hasBody { headers["content-type"] = "application/json" }
        for (name, value) in extraHeaders { headers[name.lowercased()] = value }
        let request = PreparedRequest(
            method: method, url: requestURL, path: components?.percentEncodedPath ?? "/",
            query: components?.percentEncodedQuery ?? "", headers: headers, body: hasBody ? bodyData : nil,
            device: authenticated ? DeviceIdentity(secretKeyBase64URL: connection.deviceSecret) : nil,
            maximumBytes: maximumBytes)
        let deadline = ContinuousClock.now + .seconds(timeout)
        var busyRetried = false
        var clockRetried = false
        while true {
            let remaining = deadline - ContinuousClock.now
            let result = try await attempt(request, mode: mode, timeout: remaining)
            // Only authenticated answers get here: the sealed inner response,
            // or plaintext (loopback or pairing bootstrap).
            let envelope = result.errorEnvelope
            if case .v2 = mode, !busyRetried, result.statusCode == 503, envelope.code == Self.transportBusyCode {
                busyRetried = true
                let delay = Self.busyRetryDelay(result.headers["retry-after"])
                // No time left for a second attempt: report the busy answer.
                guard ContinuousClock.now + delay + .seconds(1) < deadline else { return result }
                try await Task.sleep(for: delay)
                continue
            }
            if request.device != nil, !clockRetried, result.statusCode == 401,
                envelope.code == Self.timestampRejectedCode, let serverTime = envelope.serverTime,
                ContinuousClock.now + .seconds(1) < deadline
            {
                clockRetried = true
                BackendClock.record(serverTime: serverTime, for: connection)
                DebugLog.record("http.clock.offset", ["seconds": String(Int(BackendClock.offset(for: connection)))])
                continue
            }
            return result
        }
    }

    static let transportBusyCode = "TRANSPORT_BUSY"
    static let timestampRejectedCode = "AUTH_TIMESTAMP_REJECTED"
    /// Upper bound and default for honouring `Retry-After` on `TRANSPORT_BUSY`.
    static let busyRetryMaxDelay: Duration = .seconds(5)
    static let busyRetryDefaultDelay: Duration = .seconds(1)

    /// `Retry-After` in delta-seconds, capped; anything else waits the default second.
    static func busyRetryDelay(_ value: String?) -> Duration {
        let text = (value ?? "").trimmingCharacters(in: .whitespaces)
        guard (1...6).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Int(text)
        else { return busyRetryDefaultDelay }
        return min(.seconds(seconds), busyRetryMaxDelay)
    }

    /// Everything about one request that stays the same across retries; the
    /// device signature and the seal are fresh for every attempt.
    private struct PreparedRequest: Sendable {
        let method: HTTPMethod
        /// Plaintext URL (the tunnel posts to `/v2/sealed` instead).
        let url: URL
        /// Percent-encoded path and query exactly as signed.
        let path: String
        let query: String
        let headers: [String: String]
        /// `nil` sends no body.
        let body: Data?
        /// Signs every attempt when present.
        let device: DeviceIdentity?
        let maximumBytes: Int
    }

    private func attempt(_ prepared: PreparedRequest, mode: SecureTransportMode, timeout: Duration) async throws
        -> HTTPResult
    {
        let method = prepared.method
        let timeout = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let maximumBytes = prepared.maximumBytes
        let bodyData = prepared.body ?? Data()
        var headers = prepared.headers
        if let device = prepared.device {
            // Sign the percent-encoded request target exactly as it appears on
            // the wire (or in the inner request); the daemon verifies
            // uri.path() + canonicalized query. Signing time follows the
            // backend's clock (`BackendClock`).
            let target = prepared.path + (prepared.query.isEmpty ? "" : "?\(prepared.query)")
            for (key, value) in try device.authHeaders(
                method: method.rawValue, pathAndQuery: target, body: bodyData, now: BackendClock.now(for: connection))
            {
                headers[key] = value
            }
        }
        var request: URLRequest
        // The response key material of a sealed request, handed to the network task.
        var responseKey: ResponseKeySlot?
        if case .v2(let encryption) = mode {
            request = URLRequest(
                url: try url(path: TransportV2.sealedPath), cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: timeout)
            request.httpMethod = HTTPMethod.post.rawValue
            // Sealed before anything reaches URLSession: a failure here proves
            // the request was never sent, so it is a plain error, not an
            // unknown outcome.
            let sealed: TransportSealedRequest
            do {
                sealed = try TransportRestTunnel.seal(
                    TransportInnerRequest(
                        method: method.rawValue, path: prepared.path, query: prepared.query, headers: headers,
                        body: bodyData),
                    encryption: encryption, serverPublicKey: try pinnedServerKey(),
                    maxBodyBytes: TransportV2.maxRestBodyBytes)
            } catch let error as TransportPayloadTooLargeError {
                // The backend would answer TRANSPORT_CRYPTO_FAILED, which reads as
                // "re-pair"; the real problem is the size.
                throw TodexError.invalid(
                    String(localized: "请求内容过大（\(error.size) 字节，上限 \(error.limit) 字节），未发送", bundle: .module))
            }
            request.httpBody = sealed.body
            for (name, value) in sealed.headers { request.setValue(value, forHTTPHeaderField: name) }
            responseKey = ResponseKeySlot(sealed.responseKey)
        } else {
            request = URLRequest(url: prepared.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.httpMethod = method.rawValue
            if prepared.body != nil { request.httpBody = bodyData }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        }
        request.httpShouldHandleCookies = false
        let preparedRequest = request
        let sealedResponseKey = responseKey
        let outcome: Outcome
        do {
            outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask { [session] in
                    if let sealedResponseKey {
                        return try await Self.exchangeSealed(
                            session: session, request: preparedRequest, responseKey: sealedResponseKey,
                            maximumBytes: maximumBytes)
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
            throw SecureTransportError.outerRejection(result.apiError())
        case .outdatedSealed:
            // A sealed answer of an older revision: the request reached a
            // backend that predates sealed REST revision 2. It cannot have
            // run (that backend cannot open a revision 2 request).
            throw SecureTransportError.backendUpgradeRequired
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

    /// Moves the response key material of a sealed request into the network
    /// task (single use); a key never taken is wiped with the slot.
    private final class ResponseKeySlot: Sendable {
        private let key: Mutex<TransportRestResponseKey?>
        init(_ key: sending TransportRestResponseKey) { self.key = Mutex(key) }
        func take() -> TransportRestResponseKey? { key.withLock { $0.take() } }
        deinit { key.withLock { $0?.dispose() } }
    }

    private enum Outcome: Sendable {
        case result(HTTPResult)
        /// Outer response without the sealed content type or status 200.
        case unsealed(HTTPResult)
        /// The sealed content type without `r=2`: the backend must be updated.
        case outdatedSealed
    }

    /// `type/subtype; name=value` -> lowercase media type and parameters
    /// (names lowercased, first wins, surrounding quotes removed).
    static func parseContentType(_ value: String?) -> (media: String, parameters: [String: String]) {
        let parts = (value ?? "").split(separator: ";", omittingEmptySubsequences: false)
        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let name = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var parameter = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if parameter.count >= 2, parameter.hasPrefix("\""), parameter.hasSuffix("\"") {
                parameter = String(parameter.dropFirst().dropLast())
            }
            if !name.isEmpty, parameters[name] == nil { parameters[name] = parameter }
        }
        return ((parts.first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces).lowercased(), parameters)
    }

    /// Sends one already sealed request and stream-opens the answer. The
    /// response key dies inside this task; the inner body limit applies to
    /// the plaintext and is enforced while reading. Only `200` with
    /// `application/vnd.todex.sealed; r=2` is opened.
    private static func exchangeSealed(
        session: URLSession, request: URLRequest, responseKey: ResponseKeySlot, maximumBytes: Int
    ) async throws -> Outcome {
        guard let key = responseKey.take() else { throw TransportCryptoError("response key already used") }
        let decoder = TransportSealedResponseDecoder(responseKey: key)
        defer { decoder.dispose() }
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirectDelegate())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw TodexError.invalid(String(localized: "后端响应无效", bundle: .module)) }
        let contentType = parseContentType(http.value(forHTTPHeaderField: "Content-Type"))
        let sealedType = contentType.media == TransportV2.sealedContentType
        if sealedType, contentType.parameters["r"] != String(TransportV2.sealedRevision) { return .outdatedSealed }
        guard http.statusCode == 200, sealedType else {
            let data = try await read(bytes, response: http, limit: 64 * 1024)
            return .unsealed(HTTPResult(statusCode: http.statusCode, data: data, headers: headers(of: http)))
        }
        // Outer bytes = response nonce + inner body + head + per-record framing and tags.
        let records = (maximumBytes + 4 + TransportV2.maxHeadBytes) / TransportV2.recordPlaintextMax + 1
        let outerLimit =
            TransportV2.responseNonceLength + maximumBytes + 4 + TransportV2.maxHeadBytes + records
            * (4 + TransportV2.tagLength)
        var received = 0
        var chunk = Data()
        chunk.reserveCapacity(16 * 1024)
        var body = Data()
        func drain() throws {
            for part in try decoder.push(chunk) {
                guard body.count + part.count <= maximumBytes else { throw TodexError.invalid(CoreMessage.responseTooLarge) }
                body += part
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for try await byte in bytes {
            received += 1
            guard received <= outerLimit else { throw TodexError.invalid(CoreMessage.responseTooLarge) }
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
        guard response.expectedContentLength <= limit else { throw TodexError.invalid(CoreMessage.responseTooLarge) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw TodexError.invalid(CoreMessage.responseTooLarge) }
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
        guard (200..<300).contains(statusCode) else { throw apiError() }
        let value = data.isEmpty ? JSONValue.null : (try? JSONDecoder().decode(JSONValue.self, from: data))
        guard String(data: data, encoding: .utf8) != nil, let value else {
            if method != .get { throw TodexError.unknownOutcome(String(localized: "后端返回的确认不是有效 JSON", bundle: .module)) }
            throw TodexError.invalid(String(localized: "后端未返回有效 JSON", bundle: .module))
        }
        return value
    }

    /// `code` and `serverTime` of the backend's top-level error envelope
    /// (`{"code", "message"[, "serverTime"]}`); `serverTime` is unix seconds.
    var errorEnvelope: (code: String?, serverTime: Int64?) {
        guard !(200..<300).contains(statusCode), !data.isEmpty, data.count <= 64 * 1024,
            let value = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = value
        else { return (nil, nil) }
        var serverTime: Int64?
        if let time = value["serverTime"].doubleValue, time.isFinite, time.rounded() == time, time > 0,
            time <= 9_007_199_254_740_991
        {
            serverTime = Int64(time)
        }
        return (value["code"].optionalString, serverTime)
    }

    /// The API error for a non-2xx answer: the envelope's code and message
    /// (top-level or under `error`), else the bare status.
    func apiError() -> TodexError {
        let value = data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)
        let code = value?["code"].optionalString ?? value?["error"]["code"].optionalString ?? String(statusCode)
        let message =
            value?["message"].optionalString ?? value?["error"]["message"].optionalString ?? value?["error"]
            .optionalString ?? "HTTP \(statusCode)"
        return TodexError.server(code: code, message: message)
    }
}
