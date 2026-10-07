import CryptoKit
import Foundation

/// Reads a backend pairing link (QR or text). Links carry the address only:
/// version 1 or 2, `serverUrl` used, every other field ignored. The transport
/// key is pinned only by the device verification that follows, never by a link.
public enum PairingImporter {
    private static let maximumBytes = 65_536

    /// `current` pointed at the link's address. Pointing at a different
    /// backend drops its device key and pinned transport.
    public static func ingest(_ raw: String, current: BackendConnection) throws -> BackendConnection {
        guard raw.utf8.count <= maximumBytes else { throw TodexError.invalid(String(localized: "配对内容过大", bundle: .module)) }
        let link: Link
        do { link = try JSONDecoder().decode(Link.self, from: Data(raw.utf8)) } catch {
            throw TodexError.invalid(String(localized: "不是有效的 TodeX 配对二维码", bundle: .module))
        }
        guard link.kind == "todex-pairing-link" else {
            throw TodexError.invalid(String(localized: "不是有效的 TodeX 配对二维码", bundle: .module))
        }
        guard link.version == 1 || link.version == 2 else {
            throw TodexError.invalid(String(localized: "不支持的配对版本", bundle: .module))
        }
        let server = try BackendConnection.normalize(link.serverUrl)
        var result = current
        result.setServerURL(server.absoluteString)
        return result
    }

    private struct Link: Decodable {
        let kind: String
        let version: Int
        let serverUrl: String
    }
}

/// The transport protocol and static key the backend bound into a device
/// verification transcript; what an approval lets the profile pin.
public struct PairingTransport: Sendable, Equatable {
    public let encryption: EncryptionProtocol
    /// base64url without padding; empty for `none`.
    public let publicKey: String

    /// Validates a create response's `transportProtocol`/`transportPublicKey`
    /// before anything is derived from them. `none` is accepted only for a
    /// loopback server.
    static func validated(protocol rawProtocol: String?, publicKey rawKey: String?, loopback: Bool) throws -> (Self, Data) {
        guard let rawProtocol, let encryption = EncryptionProtocol(rawValue: rawProtocol), let rawKey else {
            throw TodexError.invalid(String(localized: "后端返回的传输加密信息无效，请更新后端后重新配对", bundle: .module))
        }
        if encryption == .none {
            guard rawKey.isEmpty else {
                throw TodexError.invalid(String(localized: "后端返回的传输加密公钥无效，请重新配对", bundle: .module))
            }
            guard loopback else { throw SecureTransportError.encryptionRequired }
            return (Self(encryption: .none, publicKey: ""), Data())
        }
        let key: Data
        do {
            key = try CryptoEncoding.decode(
                rawKey,
                count: encryption == .x25519 ? TransportV2.x25519PublicKeyLength : TransportV2.mlkemPublicKeyLength)
            // A throwaway client handshake: rejects low-order X25519 points
            // (all-zero shared secret) and ML-KEM keys that fail the modulus check.
            _ = try TransportClientHandshake.make(encryption, serverPublicKey: key)
        } catch {
            throw TodexError.invalid(String(localized: "后端返回的传输加密公钥无效，请重新配对", bundle: .module))
        }
        return (Self(encryption: encryption, publicKey: rawKey), key)
    }

    /// `XXXX-XXXX-XXXX-XXXX`: the first 8 bytes of SHA-256 over the raw key,
    /// upper-case hex, as the backend TUI shows next to the code; `none` for
    /// the plaintext (loopback) transport.
    public var fingerprint: String { Self.fingerprint(encryption: encryption, publicKey: publicKey) ?? "none" }

    /// `nil` when the key is not canonical base64url.
    public static func fingerprint(encryption: EncryptionProtocol, publicKey: String) -> String? {
        if encryption == .none { return "none" }
        guard let raw = try? CryptoEncoding.decode(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return fingerprint(raw: raw)
    }

    static func fingerprint(raw: Data) -> String {
        let hex = SHA256.hash(data: raw).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 16, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }
}

public enum DevicePairingStatus: Sendable, Equatable {
    case pending, rejected, expired
    /// The enrolled device ID is already bound to the local device key, and
    /// the transport is the one the transcript bound — both are checked in
    /// `unwrap` before delivery. Pin it together with the device key.
    case approved(PairingTransport)
}

/// The verification code authenticates this enrollment's transcript (device
/// pairing v3), which also binds the backend's transport protocol and static
/// key; an approval delivers that transport for the profile to pin.
public actor DevicePairingSession {
    public nonisolated let verificationCode: String
    /// Unix milliseconds, matching the backend and desktop contract.
    public nonisolated let expiresAt: Double
    public nonisolated let pollIntervalMilliseconds: Int
    /// The transport the transcript binds; show its fingerprint next to the
    /// code so the operator can compare both with the backend.
    public nonisolated let transport: PairingTransport
    private let requestID: String
    private let post: PairingPost
    private let now: @Sendable () -> Double
    private var material: PairingMaterial?
    private var polling = false

    /// Device pairing v3: commit to an ephemeral key and nonce, learn the
    /// server's key, then reveal. The code is fixed only after the reveal, so
    /// a man in the middle cannot grind its key against the 40-bit code.
    public static func begin(connection: BackendConnection, deviceName: String, device: DeviceIdentity) async throws -> DevicePairingSession {
        _ = try connection.normalizedURL()
        // Pairing is reachable directly on every listener and never goes
        // through the transport tunnel: pairing is what pins the key, and it
        // protects itself.
        let client = HTTPClient.pairingBootstrap(connection: connection)
        return try await begin(
            deviceName: deviceName, device: device, loopback: connection.isLoopback, privateKey: .init(),
            clientNonce: TransportBytes.random(DevicePairingV3.nonceLength),
            post: { action, body in
                try await PairingBootstrap.post(client: client, action: action, body: body)
            })
    }

    // Injectable endpoint, key, nonce and clock keep state/race tests
    // independent of a live backend; production uses the bootstrap client above.
    static func begin(
        deviceName: String, device: DeviceIdentity, loopback: Bool, privateKey: Curve25519.KeyAgreement.PrivateKey,
        clientNonce: Data,
        post: @escaping PairingPost, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }
    ) async throws -> DevicePairingSession {
        try Task.checkCancellation()
        let publicKey = privateKey.publicKey.rawRepresentation
        let commitment = try DevicePairingV3.commitment(clientPublic: publicKey, clientNonce: clientNonce)
        let response = try await post(
            "create",
            [
                "clientCommitment": .string(CryptoEncoding.encode(commitment)),
                "deviceName": .string(sanitizedDeviceName(deviceName)),
                "devicePublicKey": .string(device.publicKeyBase64URL),
                // The server binds its transport protocol and key into the
                // transcript; an older server answers 426.
                "transportBinding": 1,
            ])
        try Task.checkCancellation()
        guard let id = response["requestId"].optionalString,
            id.range(
                of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression
            ) != nil,
            let expires = response["expiresAt"].doubleValue, expires.isFinite, expires.rounded() == expires,
            expires <= 9_007_199_254_740_991, expires > now(),
            let interval = response["pollIntervalMs"].doubleValue, interval.isFinite,
            interval.rounded() == interval, (1...60_000).contains(interval),
            let encodedServerKey = response["serverPublicKey"].optionalString
        else {
            throw TodexError.invalid(String(localized: "设备验证申请无效或已过期，请重新申请", bundle: .module))
        }
        let serverKey = try CryptoEncoding.decode(encodedServerKey, count: 32)
        let (transport, transportKey) = try PairingTransport.validated(
            protocol: response["transportProtocol"].optionalString,
            publicKey: response["transportPublicKey"].optionalString, loopback: loopback)
        let material = try PairingMaterial(
            v3RequestID: id, privateKey: privateKey, serverPublicKey: serverKey, device: device,
            clientNonce: clientNonce, transport: transport, transportKey: transportKey)
        let session = Self(
            requestID: id, expiresAt: expires, pollIntervalMilliseconds: Int(interval), material: material, post: post,
            now: now)
        do {
            let revealed = try await post(
                "reveal",
                [
                    "requestId": .string(id), "clientPublicKey": .string(CryptoEncoding.encode(publicKey)),
                    "clientNonce": .string(CryptoEncoding.encode(clientNonce)),
                ])
            try Task.checkCancellation()
            guard revealed["status"].optionalString == "pending" else {
                throw TodexError.invalid(String(localized: "设备验证响应状态无效", bundle: .module))
            }
        } catch {
            // The reveal may have reached the backend; withdraw it so no
            // orphaned code waits for approval. Unrevealed requests expire.
            Task {
                do { try await session.cancel() } catch {
                    // Best effort: the request still expires on the backend.
                    DebugLog.record("pairing.cancel.failed", ["error": String(describing: error)], level: .warn)
                }
            }
            throw error
        }
        return session
    }

    private init(
        requestID: String, expiresAt: Double, pollIntervalMilliseconds: Int, material: PairingMaterial,
        post: @escaping PairingPost, now: @escaping @Sendable () -> Double
    ) {
        self.requestID = requestID
        self.expiresAt = expiresAt
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
        self.verificationCode = material.verificationCode
        self.transport = material.transport
        self.material = material
        self.post = post
        self.now = now
    }

    public func poll() async throws -> DevicePairingStatus {
        try Task.checkCancellation()
        guard material != nil, now() < expiresAt else {
            material = nil
            return .expired
        }
        guard !polling else { throw TodexError.invalid(String(localized: "设备验证正在查询，请稍候", bundle: .module)) }
        polling = true
        defer { polling = false }
        let body = proofBody(cancel: false)
        let result = try await post("poll", body)
        try Task.checkCancellation()
        // cancel() can run while the HTTP request is suspended. Never deliver
        // credentials after cancellation or expiry, even if the server approved.
        guard let material, now() < expiresAt else {
            self.material = nil
            return .expired
        }
        switch result["status"].optionalString {
        case "pending": return .pending
        case "rejected":
            self.material = nil
            return .rejected
        case "expired":
            self.material = nil
            return .expired
        case "approved":
            defer { self.material = nil }
            return .approved(try material.unwrap(result))
        default:
            throw TodexError.invalid(String(localized: "设备验证响应状态无效", bundle: .module))
        }
    }

    public func cancel() async throws {
        guard material != nil else { return }
        let body = proofBody(cancel: true)
        material = nil
        _ = try await post("cancel", body)
    }

    private func proofBody(cancel: Bool) -> JSONValue {
        // Called synchronously only while material is present.
        let key = cancel ? material!.cancelProof : material!.pollProof
        return [
            "requestId": .string(requestID), "proof": .string(key.withUnsafeBytes { CryptoEncoding.encode(Data($0)) }),
        ]
    }

    static func sanitizedDeviceName(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value)
                && !(0x2066...0x2069).contains($0.value)
        }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(80)))
        return name.isEmpty ? "TodeX" : name
    }
}

typealias PairingPost = @Sendable (String, JSONValue) async throws -> JSONValue

enum PairingBootstrap {
    /// HTTPClient supplies ephemeral/no-cookie/no-cache/no-redirect requests.
    /// The deadline cancels the underlying URLSession task, including a server
    /// that trickles bytes to keep an inactivity timeout alive. No automatic retry.
    static func post(client: HTTPClient, action: String, body: JSONValue, timeout: Duration = .seconds(10)) async throws
        -> JSONValue
    {
        guard ["create", "reveal", "poll", "cancel"].contains(action) else { throw TodexError.invalid(String(localized: "设备验证操作无效", bundle: .module)) }
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                let result: JSONValue
                do {
                    result = try await client.request(
                        .post, path: "/v2/device-pairing/\(action)", body: body, authenticated: false)
                } catch { throw describe(error, action: action) }
                try Task.checkCancellation()
                guard case .object = result, try JSONEncoder().encode(result).count <= 16_384 else {
                    throw TodexError.invalid(String(localized: "设备验证响应无效或过大", bundle: .module))
                }
                return result
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TodexError.invalid(String(localized: "设备验证请求超时，请检查后端连接", bundle: .module))
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// Desktop devicePairing parity: HTTP failures become actionable text. A
    /// bare 404 (no JSON body) means the route is missing on an older backend;
    /// a NOT_FOUND on poll/cancel means this request is gone, not the feature.
    static func describe(_ error: any Error, action: String) -> any Error {
        guard case TodexError.server(let code, _) = error else { return error }
        switch code.uppercased() {
        case "404":
            return TodexError.invalid(String(localized: "当前后端不支持设备验证，请更新后端。", bundle: .module))
        case "NOT_FOUND":
            return TodexError.invalid(
                action == "create" ? String(localized: "当前后端不支持设备验证，请更新后端。", bundle: .module) : String(localized: "设备验证申请无效或已过期，请重新申请", bundle: .module))
        case "429", "RESOURCE_EXHAUSTED":
            return TodexError.invalid(String(localized: "设备申请过于频繁或队列已满，请稍后重试", bundle: .module))
        case "401", "403", "UNAUTHENTICATED", "UNAUTHORIZED":
            return TodexError.invalid(String(localized: "设备验证请求未被接受，请重新申请", bundle: .module))
        case let status where Int(status).map({ (300..<600).contains($0) }) == true:
            return TodexError.invalid(String(localized: "设备验证失败（HTTP \(status)），请检查后端状态", bundle: .module))
        default:
            return error
        }
    }
}

struct PairingMaterial: Sendable {
    let transcript: Data
    let wrapKey: SymmetricKey
    let pollProof: SymmetricKey
    let cancelProof: SymmetricKey
    let verificationCode: String
    let deviceID: String
    let transport: PairingTransport

    /// Device pairing v3 (commit, then reveal): the transcript also binds the
    /// client's 32-byte nonce, whose commitment the server saw before it chose
    /// its key, so a MITM can no longer grind a key against the 40-bit code,
    /// and the server's transport protocol and static key, so the code also
    /// confirms the key the profile pins. HKDF is as in v2 with the v3 labels
    /// (Clarification 6).
    init(
        v3RequestID requestID: String, privateKey: Curve25519.KeyAgreement.PrivateKey, serverPublicKey: Data,
        device: DeviceIdentity, clientNonce: Data, transport: PairingTransport, transportKey: Data
    ) throws {
        let shared = try CryptoEncoding.sharedSecret(privateKey: privateKey, publicKey: serverPublicKey)
        let transcript = try DevicePairingV3.transcript(
            requestID: requestID, clientPublic: privateKey.publicKey.rawRepresentation, serverPublic: serverPublicKey,
            devicePublic: device.publicKey, clientNonce: clientNonce, transportProtocol: transport.encryption.rawValue,
            transportPublicKey: transportKey)
        let salt = Data(SHA256.hash(data: transcript))
        self.transcript = transcript
        self.transport = transport
        deviceID = device.deviceID
        wrapKey = CryptoEncoding.derive(ikm: shared, salt: salt, info: DevicePairingV3.wrapInfo)
        pollProof = CryptoEncoding.derive(ikm: shared, salt: salt, info: DevicePairingV3.pollInfo)
        cancelProof = CryptoEncoding.derive(ikm: shared, salt: salt, info: DevicePairingV3.cancelInfo)
        let hex = salt.prefix(5).map { String(format: "%02X", $0) }.joined()
        verificationCode = "\(hex.prefix(5))-\(hex.suffix(5))"
    }

    /// Decrypts the delivered credential and returns the transport to pin.
    /// The device ID must be this key's and the transport the one the create
    /// response announced, byte for byte; anything else pins nothing.
    func unwrap(_ response: JSONValue) throws -> PairingTransport {
        guard let nonceText = response["nonce"].optionalString,
            let ciphertextText = response["ciphertext"].optionalString,
            nonceText.utf8.count <= 16_384, ciphertextText.utf8.count <= 16_384
        else { throw TodexError.invalid(String(localized: "设备验证密文无效", bundle: .module)) }
        let nonce = try CryptoEncoding.decode(nonceText, count: 24)
        var plaintext = try XChaChaAEAD.open(
            CryptoEncoding.decode(ciphertextText), key: wrapKey, nonce: nonce, aad: transcript)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        // JSONDecoder accepts alternate text encodings; the protocol requires UTF-8.
        guard String(data: plaintext, encoding: .utf8) != nil else { throw TodexError.invalid(String(localized: "设备验证密文不是 UTF-8", bundle: .module)) }
        let payload = try JSONDecoder().decode(Credential.self, from: plaintext)
        guard payload.deviceID.range(of: "^dev_[A-Za-z0-9_-]{16}$", options: .regularExpression) != nil,
            payload.deviceID == deviceID
        else { throw TodexError.invalid(String(localized: "设备验证结果与本机设备密钥不匹配", bundle: .module)) }
        guard payload.transportProtocol == transport.encryption.rawValue, payload.transportPublicKey == transport.publicKey
        else { throw TodexError.invalid(String(localized: "设备验证结果与后端的传输加密公钥不一致，请重新配对", bundle: .module)) }
        return transport
    }

    private struct Credential: Decodable {
        let deviceId: String
        let transportProtocol: String
        let transportPublicKey: String
        var deviceID: String { deviceId }
    }
}

/// Device pairing v3 client primitives (transport-v2.md, "Device pairing v3").
public enum DevicePairingV3 {
    public static let commitLabel = "todex.device-pairing.v3/commit"
    public static let transcriptDomain = "todex.device-pairing.v3/transcript\0"
    public static let wrapInfo = "todex.device-pairing.v3/wrap-key"
    public static let pollInfo = "todex.device-pairing.v3/poll-proof"
    public static let cancelInfo = "todex.device-pairing.v3/cancel-proof"
    public static let nonceLength = 32

    /// `SHA256(LP("todex.device-pairing.v3/commit") || client_public || client_nonce)`.
    public static func commitment(clientPublic: Data, clientNonce: Data) throws -> Data {
        try requireLengths(clientPublic: clientPublic, clientNonce: clientNonce)
        return Data(
            SHA256.hash(data: TransportBytes.lengthPrefixed(Data(commitLabel.utf8)) + clientPublic + clientNonce))
    }

    /// `domain || request_id || 0x00 || client_public || server_public || 0x00 || device_public || client_nonce
    /// || LP(transport_protocol) || LP(transport_public_key)`; `none` has a zero-length key.
    public static func transcript(
        requestID: String, clientPublic: Data, serverPublic: Data, devicePublic: Data, clientNonce: Data,
        transportProtocol: String, transportPublicKey: Data
    ) throws -> Data {
        try requireLengths(clientPublic: clientPublic, clientNonce: clientNonce)
        guard serverPublic.count == 32, devicePublic.count == 32 else {
            throw TodexError.invalid(String(localized: "设备验证密钥长度无效", bundle: .module))
        }
        return Data(transcriptDomain.utf8) + Data(requestID.utf8) + Data([0]) + clientPublic + serverPublic + Data([0])
            + devicePublic + clientNonce + TransportBytes.lengthPrefixed(Data(transportProtocol.utf8))
            + TransportBytes.lengthPrefixed(transportPublicKey)
    }

    private static func requireLengths(clientPublic: Data, clientNonce: Data) throws {
        guard clientPublic.count == 32, clientNonce.count == nonceLength else {
            throw TodexError.invalid(String(localized: "设备验证密钥长度无效", bundle: .module))
        }
    }
}
