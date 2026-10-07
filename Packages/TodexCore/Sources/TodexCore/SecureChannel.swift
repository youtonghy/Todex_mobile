import CryptoKit
import Foundation

// Transport v2 primitives ("TodeX transport v2"), byte-for-byte shared with
// the backend (Rust) and TodeX_protocol's `secureChannel.ts` through
// `Tests/TodexCoreTests/Fixtures/transport-v2.json`. Everything here is pure:
// SecureTransport.swift and HTTPClient own the sockets and HTTP.
//
// Record ciphers and channels are single-owner state (strict counters) and are
// deliberately not Sendable; the owner serializes access.

public enum TransportV2 {
    public static let version = 2
    public static let wsLabel = "todex.transport.v2/ws"
    public static let restLabel = "todex.transport.v2/rest"
    public static let directionUp: UInt8 = 0x02
    public static let directionDown: UInt8 = 0x01
    public static let nonceLength = 32
    public static let keyLength = 32
    public static let tagLength = 16
    /// Maximum plaintext of one REST record.
    public static let recordPlaintextMax = 65_536
    /// WebSocket binary frames carry `u64_be(i)` before the ciphertext.
    public static let wsFrameOverhead = 8 + tagLength
    /// Upper bound for the JSON head of an inner request/response (Clarification 3).
    public static let maxHeadBytes = 65_536
    /// The backend's WebSocket frame limit; the plaintext limit is this minus
    /// `wsFrameOverhead` (Clarification 8).
    public static let maxWebSocketFrameBytes = 8 * 1024 * 1024
    public static let sealedContentType = "application/vnd.todex.sealed"
    public static let sealedPath = "/v2/sealed"
    public static let wsCloseCode = 4400
    public static let wsCloseReason = "transport crypto failure"
    public static let failureCode = "TRANSPORT_CRYPTO_FAILED"

    public enum Header {
        public static let transport = "x-todex-transport"
        public static let encryption = "x-todex-encryption"
        public static let clientKey = "x-todex-client-key"
        public static let kemCiphertext = "x-todex-kem-ciphertext"
        public static let requestNonce = "x-todex-request-nonce"
    }

    static let recordCiphertextMax = recordPlaintextMax + tagLength
    static let x25519PublicKeyLength = 32
    static let mlkemPublicKeyLength = 1184
    static let mlkemCiphertextLength = 1088
}

/// Any failure to open, decode or authenticate v2 data. `reason` is for logs
/// and tests only; WebSocket callers close with `4400 transport crypto
/// failure`, REST callers fail the request. Nothing else reaches the peer.
public struct TransportCryptoError: Error, LocalizedError, Sendable, Equatable {
    public let reason: String
    public var code: String { TransportV2.failureCode }
    public var closeCode: Int { TransportV2.wsCloseCode }
    public var closeReason: String { TransportV2.wsCloseReason }
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { String(localized: "传输加密校验失败，请重新连接", bundle: .module) }
}

/// A plaintext rejected by the size pre-check; no counter was consumed.
public struct TransportPayloadTooLargeError: Error, LocalizedError, Sendable, Equatable {
    public let size: Int
    public let limit: Int
    public var errorDescription: String? {
        String(localized: "消息过大（\(size) 字节，上限 \(limit) 字节），未发送", bundle: .module)
    }
}

// MARK: - Encoding helpers

enum TransportBytes {
    static func u32(_ value: Int) -> Data {
        let v = UInt32(value)
        return Data([UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    static func u64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - $0 * 8)) })
    }

    static func readU32<C: Collection>(_ bytes: C) -> Int where C.Element == UInt8 {
        bytes.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    }

    static func readU64<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// `LP(x) = u32_be(len(x)) || x`.
    static func lengthPrefixed(_ value: Data) -> Data { u32(value.count) + value }

    static func wipe(_ data: inout Data) { data.resetBytes(in: 0..<data.count) }

    static func wipe(_ bytes: inout [UInt8]) {
        for index in bytes.indices { bytes[index] = 0 }
    }

    static func random(_ count: Int) -> Data { SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) } }

    /// Strict UTF-8: invalid bytes are a protocol failure, not replaced characters.
    static func strictUTF8(_ data: Data) -> String? { String(data: data, encoding: .utf8) }
}

// MARK: - Key agreement and key schedule

/// The client half of the key agreement against the pinned server key:
/// `client_material` is the ephemeral X25519 public key or the ML-KEM-768
/// ciphertext. The shared secret is a `SymmetricKey`, zeroized on release.
public struct TransportClientHandshake: Sendable {
    public let encryption: EncryptionProtocol
    public let clientMaterial: Data
    let shared: SymmetricKey

    /// Fresh randomness per call; never reuse a handshake.
    public static func make(_ encryption: EncryptionProtocol, serverPublicKey: Data) throws -> Self {
        switch encryption {
        case .none: throw TransportCryptoError("no transport protocol")
        case .x25519: return try x25519(serverPublicKey: serverPublicKey, privateKey: .init())
        case .mlkem768:
            guard serverPublicKey.count == TransportV2.mlkemPublicKeyLength,
                let key = try? MLKEM768.PublicKey(rawRepresentation: serverPublicKey),
                let encapsulation = try? key.encapsulate()
            else { throw TransportCryptoError("ml-kem-768 encapsulation") }
            return Self(encryption: .mlkem768, clientMaterial: encapsulation.encapsulated, shared: encapsulation.sharedSecret)
        }
    }

    /// Deterministic X25519 for vectors; also rejects low-order (all-zero) results.
    static func x25519(serverPublicKey: Data, privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Self {
        guard serverPublicKey.count == TransportV2.x25519PublicKeyLength,
            let shared = try? CryptoEncoding.sharedSecret(privateKey: privateKey, publicKey: serverPublicKey)
        else { throw TransportCryptoError("x25519 shared secret") }
        return Self(encryption: .x25519, clientMaterial: privateKey.publicKey.rawRepresentation, shared: shared)
    }

    /// Vector injection for ML-KEM (CryptoKit has no deterministic encapsulation).
    init(encryption: EncryptionProtocol, clientMaterial: Data, shared: SymmetricKey) {
        self.encryption = encryption
        self.clientMaterial = clientMaterial
        self.shared = shared
    }
}

public struct TransportKeys: Sendable {
    public let th: Data
    let kUp: SymmetricKey
    let kDown: SymmetricKey
}

public enum TransportKeySchedule {
    /// `th = SHA256(LP(label) || LP(protocol) || LP(device_id) || LP(server_static_public) ||
    /// LP(client_material) || LP(client_nonce) || LP(server_nonce))`.
    public static func transcriptHash(
        label: String, encryption: EncryptionProtocol, deviceID: String, serverStaticPublic: Data,
        clientMaterial: Data, clientNonce: Data, serverNonce: Data
    ) -> Data {
        var transcript = Data()
        for part in [
            Data(label.utf8), Data(encryption.rawValue.utf8), Data(deviceID.utf8), serverStaticPublic, clientMaterial,
            clientNonce, serverNonce,
        ] {
            transcript += TransportBytes.lengthPrefixed(part)
        }
        defer { TransportBytes.wipe(&transcript) }
        return Data(SHA256.hash(data: transcript))
    }

    /// HKDF-SHA256 with `salt = th`, `ikm = shared`, info `label/up` and `label/down`.
    static func derive(
        label: String, deviceID: String, serverStaticPublic: Data, handshake: TransportClientHandshake,
        clientNonce: Data, serverNonce: Data
    ) -> TransportKeys {
        let th = transcriptHash(
            label: label, encryption: handshake.encryption, deviceID: deviceID, serverStaticPublic: serverStaticPublic,
            clientMaterial: handshake.clientMaterial, clientNonce: clientNonce, serverNonce: serverNonce)
        return TransportKeys(
            th: th,
            kUp: CryptoEncoding.derive(ikm: handshake.shared, salt: th, info: "\(label)/up"),
            kDown: CryptoEncoding.derive(ikm: handshake.shared, salt: th, info: "\(label)/down"))
    }
}

// MARK: - Records

/// One direction of a keyed record stream with a strictly increasing counter.
/// The counter advances only after a record is sealed/opened successfully;
/// `UInt64.max` is never used (Clarification 1).
public final class TransportRecordCipher {
    public let direction: UInt8
    public private(set) var nextCounter: UInt64
    private var key: SymmetricKey?
    private var th: Data

    init(key: SymmetricKey, th: Data, direction: UInt8, counter: UInt64 = 0) {
        self.key = key
        self.th = th
        self.direction = direction
        nextCounter = counter
    }

    deinit { dispose() }

    /// `nonce_i = 16 zero bytes || u64_be(i)`.
    static func nonce(_ counter: UInt64) -> Data { Data(count: 16) + TransportBytes.u64(counter) }

    /// `aad_i = th || direction || final`.
    static func aad(th: Data, direction: UInt8, final: Bool) -> Data { th + Data([direction, final ? 1 : 0]) }

    public func seal(_ plaintext: Data, final: Bool) throws -> (counter: UInt64, ciphertext: Data) {
        guard let key else { throw TransportCryptoError("cipher disposed") }
        let counter = nextCounter
        guard counter < UInt64.max else { throw TransportCryptoError("record counter exhausted") }
        let ciphertext: Data
        do {
            ciphertext = try XChaChaAEAD.seal(
                plaintext, key: key, nonce: Self.nonce(counter), aad: Self.aad(th: th, direction: direction, final: final))
        } catch { throw TransportCryptoError("record seal") }
        nextCounter = counter + 1
        return (counter, ciphertext)
    }

    /// Opens record `counter`; anything but the next expected counter is fatal.
    public func open(counter: UInt64, ciphertext: Data, final: Bool) throws -> Data {
        guard let key else { throw TransportCryptoError("cipher disposed") }
        guard counter == nextCounter else { throw TransportCryptoError("unexpected record counter") }
        guard counter < UInt64.max else { throw TransportCryptoError("record counter exhausted") }
        guard ciphertext.count >= TransportV2.tagLength else { throw TransportCryptoError("record too short") }
        let plaintext: Data
        do {
            plaintext = try XChaChaAEAD.open(
                ciphertext, key: key, nonce: Self.nonce(counter), aad: Self.aad(th: th, direction: direction, final: final))
        } catch { throw TransportCryptoError("record authentication") }
        nextCounter = counter + 1
        return plaintext
    }

    /// Drops the key (CryptoKit zeroizes it on release) and wipes the transcript hash.
    public func dispose() {
        key = nil
        TransportBytes.wipe(&th)
    }
}

// MARK: - REST record streams

public enum TransportRecordStream {
    /// 64 KiB records, each `u32_be(len(ciphertext)) || ciphertext`, exactly
    /// the last one final. An empty plaintext yields one empty final record.
    public static func seal(_ plaintext: Data, cipher: TransportRecordCipher) throws -> Data {
        var output = Data()
        output.reserveCapacity(
            plaintext.count + (plaintext.count / TransportV2.recordPlaintextMax + 1) * (4 + TransportV2.tagLength))
        var offset = plaintext.startIndex
        repeat {
            let end = min(offset + TransportV2.recordPlaintextMax, plaintext.endIndex)
            let sealed = try cipher.seal(Data(plaintext[offset..<end]), final: end == plaintext.endIndex)
            output += TransportBytes.u32(sealed.ciphertext.count) + sealed.ciphertext
            offset = end
        } while offset < plaintext.endIndex
        return output
    }

    /// One-shot open of a complete stream.
    public static func open(_ stream: Data, cipher: TransportRecordCipher) throws -> Data {
        let decoder = TransportRecordStreamDecoder(cipher: cipher)
        let parts = try decoder.push(stream)
        try decoder.finish()
        return parts.reduce(into: Data()) { $0 += $1 }
    }
}

/// Incremental decoder for a sealed record stream. `push` returns the
/// plaintext of every record completed by the chunk; `finish` asserts the
/// final record arrived and nothing followed it (Clarification 2).
public final class TransportRecordStreamDecoder {
    private let cipher: TransportRecordCipher
    private var buffer: [UInt8] = []
    public private(set) var isComplete = false

    public init(cipher: TransportRecordCipher) { self.cipher = cipher }

    deinit { dispose() }

    public func push(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        guard !isComplete else { throw TransportCryptoError("bytes after final record") }
        buffer.append(contentsOf: chunk)
        var output: [Data] = []
        var offset = 0
        while buffer.count - offset >= 4 {
            let length = TransportBytes.readU32(buffer[offset..<offset + 4])
            guard (TransportV2.tagLength...TransportV2.recordCiphertextMax).contains(length) else {
                throw TransportCryptoError("record length")
            }
            guard buffer.count - offset - 4 >= length else { break }
            let ciphertext = Data(buffer[offset + 4..<offset + 4 + length])
            offset += 4 + length
            let (plaintext, final) = try openEither(ciphertext)
            output.append(plaintext)
            if final {
                isComplete = true
                guard offset == buffer.count else { throw TransportCryptoError("bytes after final record") }
            }
        }
        buffer.removeFirst(offset)
        return output
    }

    public func finish() throws {
        guard isComplete, buffer.isEmpty else { throw TransportCryptoError("truncated record stream") }
    }

    public func dispose() {
        cipher.dispose()
        TransportBytes.wipe(&buffer)
    }

    /// The final flag is authenticated and a streaming reader cannot know
    /// whether more bytes follow, so try `final = 0` then `final = 1` with the
    /// same counter. The counter advances only on success; a forgery fails both.
    private func openEither(_ ciphertext: Data) throws -> (Data, Bool) {
        let counter = cipher.nextCounter
        if let plaintext = try? cipher.open(counter: counter, ciphertext: ciphertext, final: false) {
            return (plaintext, false)
        }
        return (try cipher.open(counter: counter, ciphertext: ciphertext, final: true), true)
    }
}

// MARK: - Inner request / response

public struct TransportInnerRequest: Sendable, Equatable {
    public var method: String
    /// Percent-encoded path; must start with `/` and must not be `/v2/sealed`.
    public var path: String
    /// Raw (already encoded) query without `?`; empty for none.
    public var query: String
    /// Lowercased on encoding.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: String = "", headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    static func validate(path: String) throws {
        guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#") else {
            throw TodexError.invalid(String(localized: "接口路径无效", bundle: .module))
        }
        guard path != TransportV2.sealedPath, !path.hasPrefix(TransportV2.sealedPath + "/") else {
            throw TodexError.invalid(String(localized: "接口路径无效", bundle: .module))
        }
    }

    /// `u32_be(len(head)) || head || body`.
    public func encoded() throws -> Data {
        try Self.validate(path: path)
        let query = query.hasPrefix("?") ? String(query.dropFirst()) : query
        let head = RequestHead(
            method: method.uppercased(), path: path, query: query.isEmpty ? nil : query,
            headers: TransportInnerHead.lowercased(headers))
        return try TransportInnerHead.frame(head, body: body)
    }

    /// Server-side parser, used by tests and in-memory fakes.
    public static func decode(_ plaintext: Data) throws -> Self {
        let (headBytes, body) = try TransportInnerHead.split(plaintext)
        guard let head = try? JSONDecoder().decode(RequestHead.self, from: headBytes),
            (try? validate(path: head.path)) != nil
        else { throw TransportCryptoError("malformed inner request head") }
        return Self(method: head.method, path: head.path, query: head.query ?? "", headers: head.headers, body: body)
    }

    private struct RequestHead: Codable {
        let method: String
        let path: String
        let query: String?
        let headers: [String: String]
    }
}

public struct TransportInnerResponseHead: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]

    static func decode(_ bytes: Data) throws -> Self {
        guard let head = try? JSONDecoder().decode(Wire.self, from: bytes), (100...599).contains(head.status) else {
            throw TransportCryptoError("malformed inner response head")
        }
        return Self(status: head.status, headers: head.headers)
    }

    struct Wire: Codable {
        let status: Int
        let headers: [String: String]
    }
}

public struct TransportInnerResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Server-side encoder, used by tests and in-memory fakes.
    public func encoded() throws -> Data {
        try TransportInnerHead.frame(
            TransportInnerResponseHead.Wire(status: status, headers: TransportInnerHead.lowercased(headers)), body: body)
    }

    public static func decode(_ plaintext: Data) throws -> Self {
        let (headBytes, body) = try TransportInnerHead.split(plaintext)
        let head = try TransportInnerResponseHead.decode(headBytes)
        return Self(status: head.status, headers: head.headers, body: body)
    }
}

enum TransportInnerHead {
    static func lowercased(_ headers: [String: String]) -> [String: String] {
        Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }

    static func frame(_ head: some Encodable, body: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(head)
        guard bytes.count <= TransportV2.maxHeadBytes else {
            throw TransportPayloadTooLargeError(size: bytes.count, limit: TransportV2.maxHeadBytes)
        }
        return TransportBytes.u32(bytes.count) + bytes + body
    }

    /// Head length from the first 4 bytes, bounded before any buffering.
    static func length<C: Collection>(_ prefix: C) throws -> Int where C.Element == UInt8 {
        let length = TransportBytes.readU32(prefix)
        guard length <= TransportV2.maxHeadBytes else { throw TransportCryptoError("inner head too large") }
        return length
    }

    /// Strict UTF-8 first: JSONDecoder would also accept UTF-16/32.
    static func json(_ bytes: Data) throws -> Data {
        guard TransportBytes.strictUTF8(bytes) != nil else { throw TransportCryptoError("inner head is not UTF-8") }
        return bytes
    }

    static func split(_ plaintext: Data) throws -> (Data, Data) {
        let bytes = Data(plaintext)
        guard bytes.count >= 4 else { throw TransportCryptoError("inner message too short") }
        let length = try length(bytes.prefix(4))
        guard bytes.count >= 4 + length else { throw TransportCryptoError("inner head truncated") }
        return (try json(bytes.subdata(in: 4..<4 + length)), bytes.subdata(in: 4 + length..<bytes.count))
    }
}

/// Streaming decoder for a sealed REST response: authenticates the inner head
/// as soon as its records arrive, then yields body chunks record by record.
public final class TransportSealedResponseDecoder {
    private let records: TransportRecordStreamDecoder
    private var pending = Data()
    private var headLength: Int?
    public private(set) var head: TransportInnerResponseHead?

    public init(cipher: TransportRecordCipher) { records = TransportRecordStreamDecoder(cipher: cipher) }

    /// Body chunks completed by `chunk` (empty until the head is known).
    public func push(_ chunk: Data) throws -> [Data] {
        let plaintexts = try records.push(chunk)
        if head != nil { return plaintexts.filter { !$0.isEmpty } }
        for plaintext in plaintexts { pending += plaintext }
        if headLength == nil, pending.count >= 4 { headLength = try TransportInnerHead.length(pending.prefix(4)) }
        guard let headLength, pending.count >= 4 + headLength else { return [] }
        let start = pending.startIndex
        head = try TransportInnerResponseHead.decode(
            TransportInnerHead.json(pending.subdata(in: start + 4..<start + 4 + headLength)))
        let rest = pending.subdata(in: start + 4 + headLength..<pending.endIndex)
        TransportBytes.wipe(&pending)
        pending = Data()
        return rest.isEmpty ? [] : [rest]
    }

    public func finish() throws {
        try records.finish()
        guard head != nil else { throw TransportCryptoError("truncated before inner head") }
    }

    public func dispose() {
        records.dispose()
        TransportBytes.wipe(&pending)
    }
}

// MARK: - REST tunnel (client side)

/// The outer `POST /v2/sealed` request for one inner request. Keep
/// `responseCipher` to open the response; it holds `k_down` only.
public struct TransportSealedRequest {
    /// Outer request headers (lowercase names).
    public let headers: [String: String]
    /// Record stream sealed with `k_up`.
    public let body: Data
    public let responseCipher: TransportRecordCipher
}

public enum TransportRestTunnel {
    public static func seal(
        _ request: TransportInnerRequest, encryption: EncryptionProtocol, serverPublicKey: Data, maxBodyBytes: Int? = nil
    ) throws -> TransportSealedRequest {
        if let maxBodyBytes { try TransportSizeCheck.require(request.body.count, limit: maxBodyBytes) }
        return try seal(
            request, serverPublicKey: serverPublicKey,
            handshake: TransportClientHandshake.make(encryption, serverPublicKey: serverPublicKey),
            clientNonce: TransportBytes.random(TransportV2.nonceLength))
    }

    static func seal(
        _ request: TransportInnerRequest, serverPublicKey: Data, handshake: TransportClientHandshake, clientNonce: Data
    ) throws -> TransportSealedRequest {
        guard clientNonce.count == TransportV2.nonceLength else { throw TransportCryptoError("client nonce length") }
        var plaintext = try request.encoded()
        defer { TransportBytes.wipe(&plaintext) }
        let keys = TransportKeySchedule.derive(
            label: TransportV2.restLabel, deviceID: "", serverStaticPublic: serverPublicKey, handshake: handshake,
            clientNonce: clientNonce, serverNonce: Data())
        let up = TransportRecordCipher(key: keys.kUp, th: keys.th, direction: TransportV2.directionUp)
        defer { up.dispose() }
        let body = try TransportRecordStream.seal(plaintext, cipher: up)
        let material = CryptoEncoding.encode(handshake.clientMaterial)
        return TransportSealedRequest(
            headers: [
                "content-type": TransportV2.sealedContentType,
                TransportV2.Header.transport: String(TransportV2.version),
                TransportV2.Header.encryption: handshake.encryption.rawValue,
                handshake.encryption == .x25519 ? TransportV2.Header.clientKey : TransportV2.Header.kemCiphertext: material,
                TransportV2.Header.requestNonce: CryptoEncoding.encode(clientNonce),
            ],
            body: body,
            responseCipher: TransportRecordCipher(key: keys.kDown, th: keys.th, direction: TransportV2.directionDown))
    }

    /// One-shot open of a complete sealed response body.
    public static func openResponse(_ body: Data, cipher: TransportRecordCipher) throws -> TransportInnerResponse {
        defer { cipher.dispose() }
        var plaintext = try TransportRecordStream.open(body, cipher: cipher)
        defer { TransportBytes.wipe(&plaintext) }
        return try TransportInnerResponse.decode(plaintext)
    }
}

public enum TransportSizeCheck {
    /// "Client rules": reject before sealing, so no counter is consumed.
    public static func require(_ size: Int, limit: Int) throws {
        guard size <= limit else { throw TransportPayloadTooLargeError(size: size, limit: limit) }
    }

    /// WebSocket plaintext limit = frame limit − 24 (Clarification 8).
    public static func webSocketPlaintextLimit(maxFrameBytes: Int = TransportV2.maxWebSocketFrameBytes) -> Int {
        maxFrameBytes - TransportV2.wsFrameOverhead
    }
}

// MARK: - WebSocket

/// Client side of the `/v2/ws` handshake. Send `queryParameters` with the
/// signed upgrade, then hand the server's first (text) message to
/// `acceptHello`. Single use.
public final class TransportWebSocketHandshake {
    public let encryption: EncryptionProtocol
    /// `tv`, `enc`, `client_nonce` and `client_key` | `ciphertext`.
    public let queryParameters: [String: String]
    private var handshake: TransportClientHandshake?
    private let serverPublicKey: Data
    private let deviceID: String
    private var clientNonce: Data
    private let maxFrameBytes: Int

    /// `deviceID` must be the id in the signed upgrade credential ("" when
    /// auth is disabled); it is bound into the key schedule (Clarification 9).
    public convenience init(
        encryption: EncryptionProtocol, serverPublicKey: Data, deviceID: String,
        maxFrameBytes: Int = TransportV2.maxWebSocketFrameBytes
    ) throws {
        try self.init(
            serverPublicKey: serverPublicKey, deviceID: deviceID,
            handshake: TransportClientHandshake.make(encryption, serverPublicKey: serverPublicKey),
            clientNonce: TransportBytes.random(TransportV2.nonceLength), maxFrameBytes: maxFrameBytes)
    }

    init(
        serverPublicKey: Data, deviceID: String, handshake: TransportClientHandshake, clientNonce: Data,
        maxFrameBytes: Int = TransportV2.maxWebSocketFrameBytes
    ) throws {
        guard clientNonce.count == TransportV2.nonceLength else { throw TransportCryptoError("client nonce length") }
        encryption = handshake.encryption
        self.handshake = handshake
        self.serverPublicKey = serverPublicKey
        self.deviceID = deviceID
        self.clientNonce = clientNonce
        self.maxFrameBytes = maxFrameBytes
        queryParameters = [
            "tv": String(TransportV2.version),
            "enc": handshake.encryption.rawValue,
            "client_nonce": CryptoEncoding.encode(clientNonce),
            handshake.encryption == .x25519 ? "client_key" : "ciphertext": CryptoEncoding.encode(handshake.clientMaterial),
        ]
    }

    deinit { dispose() }

    public func acceptHello(_ text: String) throws -> TransportWebSocketChannel {
        guard let current = handshake else { throw TransportCryptoError("hello already consumed") }
        handshake = nil
        defer { TransportBytes.wipe(&clientNonce) }
        let keys = TransportKeySchedule.derive(
            label: TransportV2.wsLabel, deviceID: deviceID, serverStaticPublic: serverPublicKey, handshake: current,
            clientNonce: clientNonce, serverNonce: try Self.parseHello(text))
        return TransportWebSocketChannel(
            up: TransportRecordCipher(key: keys.kUp, th: keys.th, direction: TransportV2.directionUp),
            down: TransportRecordCipher(key: keys.kDown, th: keys.th, direction: TransportV2.directionDown),
            maxFrameBytes: maxFrameBytes)
    }

    public func dispose() {
        handshake = nil
        TransportBytes.wipe(&clientNonce)
    }

    /// `{"type":"todex.transport.hello","version":2,"serverNonce":"<b64url 32B>"}`;
    /// unknown fields are ignored (Clarification 7).
    public static func parseHello(_ text: String) throws -> Data {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
            value["type"] == .string("todex.transport.hello"),
            value["version"] == .number(Double(TransportV2.version)),
            case .string(let encoded) = value["serverNonce"],
            let nonce = try? CryptoEncoding.decode(encoded, count: TransportV2.nonceLength)
        else { throw TransportCryptoError("malformed hello") }
        return nonce
    }
}

/// An established v2 WebSocket: JSON text in, binary frames out, and back.
public final class TransportWebSocketChannel {
    private let up: TransportRecordCipher
    private let down: TransportRecordCipher
    private let maxFrameBytes: Int

    init(up: TransportRecordCipher, down: TransportRecordCipher, maxFrameBytes: Int) {
        self.up = up
        self.down = down
        self.maxFrameBytes = maxFrameBytes
    }

    deinit { dispose() }

    /// `u64_be(i) || AEAD(k_up, nonce_i, aad_i, utf8(text))`. Throws
    /// `TransportPayloadTooLargeError` before sealing when too large.
    public func seal(_ text: String) throws -> Data {
        let plaintext = Data(text.utf8)
        try TransportSizeCheck.require(
            plaintext.count, limit: TransportSizeCheck.webSocketPlaintextLimit(maxFrameBytes: maxFrameBytes))
        let sealed = try up.seal(plaintext, final: false)
        return TransportBytes.u64(sealed.counter) + sealed.ciphertext
    }

    /// Opens one binary frame from the server. Any `TransportCryptoError` is
    /// fatal: close the socket with 4400 `transport crypto failure`.
    public func open(_ frame: Data) throws -> String {
        guard frame.count >= TransportV2.wsFrameOverhead else { throw TransportCryptoError("frame too short") }
        let bytes = Data(frame)
        var plaintext = try down.open(
            counter: TransportBytes.readU64(bytes.prefix(8)), ciphertext: bytes.subdata(in: 8..<bytes.count), final: false)
        defer { TransportBytes.wipe(&plaintext) }
        guard let text = TransportBytes.strictUTF8(plaintext) else { throw TransportCryptoError("frame is not UTF-8") }
        return text
    }

    public func dispose() {
        up.dispose()
        down.dispose()
    }
}
