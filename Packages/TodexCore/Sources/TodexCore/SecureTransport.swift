import Foundation
import Synchronization

// The one place business code talks to a backend under transport v2. It
// applies the spec's "Client rules", like TodeX_protocol's `secureTransport.ts`:
// - a protocol + key pinned by device verification (`transportVerified`) ->
//   v2 everywhere (REST through POST /v2/sealed, WebSocket with tv=2),
//   loopback included;
// - a pinned key that no verification bound -> refused everywhere, loopback
//   included, until the user re-pairs; a verified pin missing its protocol or
//   key -> refused as an invalid key, never plaintext;
// - no pinned key, remote -> refused, never a plaintext fallback;
// - no pinned key, loopback -> plaintext.
// Callers see plain requests, responses and JSON text messages.
//
// Sealed REST is revision 2 (`X-Todex-Sealed-Revision: 2`, responses typed
// `application/vnd.todex.sealed; r=2` and prefixed with a response nonce). A
// sealed answer without `r=2`, or a transport policy without
// `"sealedRevision": 2`, comes from an outdated backend
// (`SecureTransportError.backendUpgradeRequired`); there is no fallback.

public enum SecureTransportMode: Sendable, Equatable {
    case v2(EncryptionProtocol)
    case plaintext
    case refused

    public static func resolve(_ connection: BackendConnection) -> Self {
        if connection.hasPinnedTransport {
            guard connection.transportVerified, connection.encryption != .none,
                !connection.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .refused }
            return .v2(connection.encryption)
        }
        return connection.isLoopback ? .plaintext : .refused
    }

    /// Throws the user-facing re-pair error for `.refused`.
    func requireAllowed(_ connection: BackendConnection) throws {
        if self == .refused { throw SecureTransportError.refusal(connection) }
    }
}

public enum SecureTransportError {
    /// Remote host without a pinned key: the user must pair with encryption.
    public static var encryptionRequired: TodexError {
        .configuration(String(localized: "远程后端必须使用加密连接，请重新配对", bundle: .module))
    }

    /// A pinned key that no device verification confirmed (saved by an older
    /// build, or tampered with): never used, never downgraded to plaintext.
    public static var unverifiedKey: TodexError {
        .configuration(String(localized: "此后端的加密公钥未经设备验证确认，请重新配对", bundle: .module))
    }

    /// A verified pin missing its protocol or its key: unusable, and never
    /// read as plaintext.
    public static var invalidPinnedKey: TodexError {
        .configuration(String(localized: "已保存的加密公钥不完整或无法使用，请重新配对", bundle: .module))
    }

    /// The error for a profile `SecureTransportMode.resolve` refuses.
    public static func refusal(_ connection: BackendConnection) -> TodexError {
        guard connection.hasPinnedTransport else { return encryptionRequired }
        return connection.transportVerified ? invalidPinnedKey : unverifiedKey
    }

    /// The server now requires a different protocol than the pinned one.
    public static var repairRequired: TodexError {
        .configuration(String(localized: "后端的加密方式已变更，请重新配对", bundle: .module))
    }

    /// The backend refused the transport itself: it could not open a request
    /// sealed to the pinned key (`TRANSPORT_CRYPTO_FAILED`), or it wants a
    /// newer transport (`426 PROTOCOL_UPGRADE_REQUIRED`). Retrying with the
    /// same profile cannot succeed.
    public static var transportRejected: TodexError {
        .configuration(String(localized: "后端拒绝了加密连接，请重新配对", bundle: .module))
    }

    /// Maps an unauthenticated outer rejection (Clarification 10) to the
    /// re-pair error; any other API error passes through unchanged.
    static func outerRejection(_ error: any Error) -> any Error {
        guard case TodexError.server(let code, _) = error,
            ["426", "PROTOCOL_UPGRADE_REQUIRED", "TRANSPORT_CRYPTO_FAILED"].contains(code.uppercased())
        else { return error }
        return transportRejected
    }

    /// The backend predates sealed REST revision 2: its `/v2/transport-policy`
    /// lacks `"sealedRevision": 2`, or it answered a sealed request without
    /// `r=2`. Never falls back; the backend must be updated.
    public static var backendUpgradeRequired: TodexError {
        .configuration(String(localized: "后端版本过旧，与当前客户端的加密请求格式不兼容。请升级后端后重新连接。", bundle: .module))
    }

    /// Checks a `/v2/transport-policy` answer against the profile. The answer
    /// never downgrades a pinned profile to plaintext; a different required
    /// protocol asks for re-pairing, an unpinned profile facing a backend
    /// that requires encryption asks for encrypted pairing, and a pinned
    /// profile needs `sealedRevision` 2 (else the backend must be updated).
    public static func checkPolicy(
        _ connection: BackendConnection, requiredProtocol: String?, sealedRevision: Int?
    ) throws {
        let mode = SecureTransportMode.resolve(connection)
        try mode.requireAllowed(connection)
        let required = requiredProtocol.flatMap(EncryptionProtocol.init(rawValue:)).flatMap { $0 == .none ? nil : $0 }
        switch mode {
        case .v2(let pinned):
            if let required, required != pinned { throw repairRequired }
            if sealedRevision != TransportV2.sealedRevision { throw backendUpgradeRequired }
        // The backend refuses a plaintext WebSocket whenever it requires
        // encryption, loopback included; say so instead of a bare 403.
        case .plaintext: if required != nil { throw pairingRequired }
        case .refused: return
        }
    }

    /// An unpinned (loopback) profile whose backend requires encryption.
    public static var pairingRequired: TodexError {
        .configuration(String(localized: "后端要求加密连接，请重新配对", bundle: .module))
    }
}

extension BackendConnection {
    /// `localhost`, 127.0.0.0/8, `::1` and IPv4-mapped loopback, matching
    /// TodeX_protocol's `isLoopbackHostname`.
    public var isLoopback: Bool {
        guard let host = (try? normalizedURL())?.host(percentEncoded: false) else { return false }
        return Self.isLoopbackHost(host)
    }

    static func isLoopbackHost(_ raw: String) -> Bool {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if ["localhost", "::1", "0:0:0:0:0:0:0:1"].contains(host) { return true }
        // Canonical dotted-quad decimal only. A leading zero is not loopback
        // here: the system resolver reads `127.0.0.010` as octal and sends
        // `127.0.0.08` to DNS as a host name (Darwin's inet_pton accepts both).
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts[0] == "127" {
            return parts.allSatisfy { part in
                (1...3).contains(part.utf8.count) && part.utf8.allSatisfy { (48...57).contains($0) }
                    && (part == "0" || part.first != "0") && (Int(part) ?? 256) <= 255
            }
        }
        if host.hasPrefix("::ffff:") {
            let mapped = String(host.dropFirst(7))
            if mapped.contains(".") { return isLoopbackHost(mapped) }
            let words = mapped.split(separator: ":")
            guard words.count == 2, let high = UInt16(words[0], radix: 16), let low = UInt16(words[1], radix: 16),
                words.allSatisfy({ $0.count <= 4 })
            else { return false }
            return isLoopbackHost("\(high >> 8).\(high & 0xff).\(low >> 8).\(low & 0xff)")
        }
        return false
    }
}

public struct SecureTransportResponse: Sendable, Equatable {
    public let status: Int
    /// Lowercase names.
    public let headers: [String: String]
    public let body: Data
}

/// One WebSocket with JSON text messages; v2 framing is invisible here.
public protocol SecureWebSocket: Sendable {
    var isEncrypted: Bool { get }
    /// Ordered: frames hit the wire in call order. A seal failure reports
    /// through `completion` without touching the socket.
    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void)
    /// Next text message. A `TransportCryptoError` has already closed the
    /// socket with 4400.
    func receive() async throws -> String
    func cancel()
}

public protocol SecureTransport: Sendable {
    var mode: SecureTransportMode { get }
    /// `path` is the API path (`/v2/...`, already segment-escaped where
    /// needed), `query` raw key/values. Device-auth signs the inner request.
    /// `timeout` bounds the whole exchange; reading stops as soon as the
    /// (inner) body exceeds `maximumBytes`.
    func request(
        method: HTTPMethod, path: String, query: [String: String], headers: [String: String], body: Data?,
        timeout: TimeInterval, maximumBytes: Int
    ) async throws -> SecureTransportResponse
    /// Opens a WebSocket; under v2 returns after the server hello.
    func openWebSocket(path: String, query: [String: String]) async throws -> any SecureWebSocket
}

extension SecureTransport {
    /// A request with `HTTPClient`'s default timeout and body limit.
    public func request(
        method: HTTPMethod, path: String, query: [String: String] = [:], headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> SecureTransportResponse {
        try await request(
            method: method, path: path, query: query, headers: headers, body: body,
            timeout: HTTPClient.defaultTimeout, maximumBytes: HTTPClient.defaultMaximumBytes)
    }
}

/// Default transport for a backend profile, over URLSession.
public final class BackendSecureTransport: SecureTransport {
    public let connection: BackendConnection
    public let mode: SecureTransportMode
    let http: HTTPClient
    private let makeSocket: @Sendable (URLRequest) -> any RawWebSocket
    private let helloTimeout: Duration

    public convenience init(connection: BackendConnection) {
        self.init(connection: connection, session: nil, makeSocket: { FoundationWebSocket(request: $0) })
    }

    init(
        connection: BackendConnection, session: URLSession?,
        makeSocket: @escaping @Sendable (URLRequest) -> any RawWebSocket, helloTimeout: Duration = .seconds(15)
    ) {
        self.connection = connection
        mode = .resolve(connection)
        http = HTTPClient(connection: connection, session: session)
        self.makeSocket = makeSocket
        self.helloTimeout = helloTimeout
    }

    public func request(
        method: HTTPMethod, path: String, query: [String: String], headers: [String: String], body: Data?,
        timeout: TimeInterval, maximumBytes: Int
    ) async throws -> SecureTransportResponse {
        let result = try await http.response(
            method, path: path, query: query, rawBody: body, headers: headers, timeout: timeout,
            maximumBytes: maximumBytes)
        return SecureTransportResponse(status: result.statusCode, headers: result.headers, body: result.data)
    }

    public func openWebSocket(path: String = "/v2/ws", query: [String: String] = [:]) async throws
        -> any SecureWebSocket
    {
        try mode.requireAllowed(connection)
        let device = DeviceIdentity(secretKeyBase64URL: connection.deviceSecret)
        var parameters = query
        var handshake: TransportWebSocketHandshake?
        if case .v2(let encryption) = mode {
            let created = try TransportWebSocketHandshake(
                encryption: encryption, serverPublicKey: http.pinnedServerKey(), deviceID: device?.deviceID ?? "")
            parameters.merge(created.queryParameters) { _, transport in transport }
            handshake = created
        }
        var components = URLComponents(url: try http.url(path: path), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var encoded = parameters.sorted { $0.key < $1.key }
            .map { "\(HTTPClient.segment($0.key))=\(HTTPClient.segment($0.value))" }.joined(separator: "&")
        if let device {
            // The signature covers the transport parameters (tv, enc, nonce,
            // key), binding the handshake to this enrolled device. The same
            // `device.deviceID` is bound into the key schedule above.
            // Signing time follows the backend's clock (`BackendClock`).
            let auth = try device.authQuery(
                pathAndQuery: components.percentEncodedPath + (encoded.isEmpty ? "" : "?\(encoded)"),
                now: BackendClock.now(for: connection))
            encoded = encoded.isEmpty ? auth : "\(encoded)&\(auth)"
        }
        components.percentEncodedQuery = encoded.isEmpty ? nil : encoded
        guard let url = components.url else { throw TodexError.invalid(String(localized: "WebSocket 地址无效", bundle: .module)) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        let raw = makeSocket(request)
        guard let handshake else { return TransportWebSocketConnection(raw: raw, channel: nil) }
        // The client must not send before the hello arrives.
        let first = try await receiveHello(raw)
        guard case .text(let hello) = first else {
            raw.close(code: TransportV2.wsCloseCode, reason: TransportV2.wsCloseReason)
            throw TransportCryptoError("expected hello")
        }
        do {
            return TransportWebSocketConnection(raw: raw, channel: try handshake.acceptHello(hello))
        } catch {
            raw.close(code: TransportV2.wsCloseCode, reason: TransportV2.wsCloseReason)
            throw error
        }
    }

    private func receiveHello(_ raw: any RawWebSocket) async throws -> WebSocketMessage {
        let timeout = helloTimeout
        return try await withThrowingTaskGroup(of: WebSocketMessage.self) { group in
            group.addTask { try await raw.receive() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TodexError.invalid(String(localized: "等待后端响应超时", bundle: .module))
            }
            defer { group.cancelAll() }
            do {
                guard let message = try await group.next() else { throw CancellationError() }
                return message
            } catch {
                // Unblocks the pending receive so the group can finish.
                raw.cancel()
                throw error
            }
        }
    }
}

// MARK: - Sockets

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// Text and binary WebSocket frames; the seam for in-memory test servers.
protocol RawWebSocket: Sendable {
    func send(_ message: WebSocketMessage, completion: @escaping @Sendable ((any Error)?) -> Void)
    func receive() async throws -> WebSocketMessage
    func close(code: Int, reason: String)
    func cancel()
}

/// A v2 channel (or plaintext) over a raw socket. Sealing and enqueueing
/// happen under one lock so counters reach the wire in order.
final class TransportWebSocketConnection: SecureWebSocket {
    let isEncrypted: Bool
    private let raw: any RawWebSocket
    private let channel: Mutex<TransportWebSocketChannel?>

    init(raw: any RawWebSocket, channel: sending TransportWebSocketChannel?) {
        self.raw = raw
        isEncrypted = channel != nil
        self.channel = Mutex(channel)
    }

    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        guard isEncrypted else {
            raw.send(.text(text), completion: completion)
            return
        }
        do {
            try channel.withLock { channel in
                guard let channel else { throw TodexError.disconnected }
                raw.send(.data(try channel.seal(text)), completion: completion)
            }
        } catch { completion(error) }
    }

    func receive() async throws -> String {
        let message = try await raw.receive()
        guard isEncrypted else {
            switch message {
            case .text(let text): return text
            case .data(let data):
                guard let text = TransportBytes.strictUTF8(data) else {
                    throw TodexError.invalid(String(localized: "收到非 UTF-8 消息", bundle: .module))
                }
                return text
            }
        }
        do {
            // A text message after the hello is a protocol violation.
            guard case .data(let frame) = message else { throw TransportCryptoError("expected binary frame") }
            return try channel.withLock { channel in
                guard let channel else { throw TodexError.disconnected }
                return try channel.open(frame)
            }
        } catch let error as TransportCryptoError {
            fail()
            throw error
        }
    }

    func cancel() {
        channel.withLock { $0?.dispose(); $0 = nil }
        raw.cancel()
    }

    private func fail() {
        channel.withLock { $0?.dispose(); $0 = nil }
        raw.close(code: TransportV2.wsCloseCode, reason: TransportV2.wsCloseReason)
    }
}

private final class SocketNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

final class FoundationWebSocket: RawWebSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: SocketNoRedirectDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = TransportV2.maxWebSocketFrameBytes
        task.resume()
    }

    func send(_ message: WebSocketMessage, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let wire: URLSessionWebSocketTask.Message =
            switch message {
            case .text(let text): .string(text)
            case .data(let data): .data(data)
            }
        task.send(wire) { [task] error in
            completion(error.map { RealtimeClient.socketError($0, response: task.response) })
        }
    }

    func receive() async throws -> WebSocketMessage {
        do {
            switch try await task.receive() {
            case .string(let value): return .text(value)
            case .data(let value): return .data(value)
            @unknown default: throw TodexError.invalid(String(localized: "收到未知消息格式", bundle: .module))
            }
        } catch { throw RealtimeClient.socketError(error, response: task.response) }
    }

    func close(code: Int, reason: String) {
        // Imported NS_ENUM: any raw value (4400 is application-defined) round-trips.
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .policyViolation
        task.cancel(with: closeCode, reason: Data(reason.utf8))
        session.invalidateAndCancel()
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
