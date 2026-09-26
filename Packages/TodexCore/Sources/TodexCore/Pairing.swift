import CryptoKit
import Foundation

/// Collects one QR batch, accepting repeated scans and out-of-order fragments.
/// A different batch or conflicting duplicate throws without losing progress.
/// Create a new importer to abandon a batch. Successful imports reset progress.
public struct PairingImporter: Sendable {
    public var receivedCount: Int { chunks.count }
    public private(set) var totalCount = 0
    private var checksum: String?
    private var chunks: [Int: String] = [:]
    private static let maximumBytes = 65_536

    public init() {}

    public mutating func ingest(_ raw: String, current: BackendConnection) throws -> BackendConnection? {
        guard raw.utf8.count <= Self.maximumBytes else { throw TodexError.invalid(String(localized: "配对内容过大", bundle: .module)) }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(raw.utf8))
        guard envelope.version == 1 else { throw TodexError.invalid(String(localized: "不支持的配对版本", bundle: .module)) }
        if envelope.kind == "todex-pairing-link" {
            let connection = try Self.importLink(Data(raw.utf8), current: current)
            self = Self()
            return connection
        }
        guard envelope.kind == "todex-pairing-chunk" else { throw TodexError.invalid(String(localized: "不是有效的 TodeX 配对二维码", bundle: .module)) }
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(raw.utf8))
        guard (1...128).contains(chunk.total), (1...chunk.total).contains(chunk.index),
            !chunk.data.isEmpty, chunk.data.utf8.count <= 4096, chunk.data.utf8.allSatisfy(CryptoEncoding.isBase64URL)
        else {
            throw TodexError.invalid(String(localized: "配对分片内容或序号无效", bundle: .module))
        }
        _ = try CryptoEncoding.decode(chunk.checksum, count: 32)
        guard checksum == nil || (checksum == chunk.checksum && totalCount == chunk.total) else {
            throw TodexError.invalid(String(localized: "配对分片不属于同一批次", bundle: .module))
        }
        if let previous = chunks[chunk.index], previous != chunk.data { throw TodexError.invalid(String(localized: "同一序号的配对分片内容冲突", bundle: .module)) }
        var candidate = chunks
        candidate[chunk.index] = chunk.data
        guard candidate.values.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumBytes else {
            throw TodexError.invalid(String(localized: "配对分片内容过大", bundle: .module))
        }
        if candidate.count == chunk.total {
            let encoded = (1...chunk.total).compactMap { candidate[$0] }.joined()
            let payload = try CryptoEncoding.decode(encoded)
            guard CryptoEncoding.encode(Data(SHA256.hash(data: payload))) == chunk.checksum else {
                throw TodexError.invalid(String(localized: "配对分片校验失败", bundle: .module))
            }
            let connection = try Self.importLink(payload, current: current)
            self = Self()
            return connection
        }
        chunks = candidate
        checksum = chunk.checksum
        totalCount = chunk.total
        return nil
    }

    private static func importLink(_ data: Data, current: BackendConnection) throws -> BackendConnection {
        guard String(data: data, encoding: .utf8) != nil else { throw TodexError.invalid(String(localized: "配对链接不是有效 UTF-8", bundle: .module)) }
        let link = try JSONDecoder().decode(Link.self, from: data)
        guard link.kind == "todex-pairing-link", link.version == 1 else { throw TodexError.invalid(String(localized: "无效的配对链接", bundle: .module)) }
        let server = try BackendConnection.normalize(link.serverUrl)
        let protocolID = try parseProtocol(link.protocol?.id)
        let selected = try parseProtocol(link.preferredEncryption) ?? protocolID ?? .none
        let key: String
        if selected == .none {
            key = ""
        } else {
            guard protocolID == selected, let importedKey = link.protocol?.publicKey else {
                throw TodexError.invalid(String(localized: "配对加密方式和公钥不匹配", bundle: .module))
            }
            let bytes = try CryptoEncoding.decode(importedKey, count: selected == .x25519 ? 32 : 1184)
            if selected == .x25519 {
                // Checking only length admits low-order points such as zero.
                _ = try CryptoEncoding.sharedSecret(privateKey: .init(), publicKey: bytes)
            } else {
                _ = try MLKEM768.PublicKey(rawRepresentation: bytes)
            }
            key = importedKey
        }
        var result = current
        result.serverURL = server.absoluteString
        result.encryption = selected
        result.publicKey = key
        let sameBackend = (try? current.normalizedURL()) == server
        // Pairing links carry transport keys only. The device key is enrolled
        // through device verification and never travels in a QR.
        result.deviceSecret = sameBackend ? current.deviceSecret : ""
        return result
    }

    private static func parseProtocol(_ value: String?) throws -> EncryptionProtocol? {
        guard let value else { return nil }
        guard let result = EncryptionProtocol(rawValue: value) else { throw TodexError.invalid(String(localized: "不支持的配对加密协议", bundle: .module)) }
        return result
    }

    private struct Envelope: Decodable {
        let kind: String
        let version: Int
    }
    private struct Chunk: Decodable {
        let checksum: String
        let index: Int
        let total: Int
        let data: String
    }
    private struct Link: Decodable {
        let kind: String
        let version: Int
        let serverUrl: String
        let preferredEncryption: String?
        let `protocol`: PublicKey?
        struct PublicKey: Decodable {
            let id: String
            let publicKey: String
        }
    }
}

public enum DevicePairingStatus: Sendable, Equatable {
    case pending, rejected, expired
    /// Approval delivers the enrolled device ID, which is already bound to the
    /// local device key — the payload is verified in `unwrap` before delivery.
    case approved
}

/// The verification code authenticates this enrollment's ephemeral transcript.
/// It does not verify or replace the separately imported transport public key.
public actor DevicePairingSession {
    public nonisolated let verificationCode: String
    /// Unix milliseconds, matching the backend and desktop contract.
    public nonisolated let expiresAt: Double
    public nonisolated let pollIntervalMilliseconds: Int
    private let requestID: String
    private let post: PairingPost
    private let now: @Sendable () -> Double
    private var material: PairingMaterial?
    private var polling = false

    public static func begin(connection: BackendConnection, deviceName: String, device: DeviceIdentity) async throws -> DevicePairingSession {
        _ = try connection.normalizedURL()
        let client = HTTPClient(connection: connection)
        return try await begin(
            deviceName: deviceName, device: device, privateKey: .init(),
            post: { action, body in
                try await PairingBootstrap.post(client: client, action: action, body: body)
            })
    }

    // Injectable endpoint and clock keep state/race tests independent of a live
    // backend; production always uses the unauthenticated HTTPClient above.
    static func begin(
        deviceName: String, device: DeviceIdentity, privateKey: Curve25519.KeyAgreement.PrivateKey, post: @escaping PairingPost,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }
    ) async throws -> DevicePairingSession {
        try Task.checkCancellation()
        let publicKey = privateKey.publicKey.rawRepresentation
        let response = try await post(
            "create",
            [
                "clientPublicKey": .string(CryptoEncoding.encode(publicKey)),
                "deviceName": .string(sanitizedDeviceName(deviceName)),
                "devicePublicKey": .string(device.publicKeyBase64URL),
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
        let material = try PairingMaterial(
            requestID: id, privateKey: privateKey, serverPublicKey: serverKey, device: device)
        return Self(
            requestID: id, expiresAt: expires, pollIntervalMilliseconds: Int(interval), material: material, post: post,
            now: now)
    }

    private init(
        requestID: String, expiresAt: Double, pollIntervalMilliseconds: Int, material: PairingMaterial,
        post: @escaping PairingPost, now: @escaping @Sendable () -> Double
    ) {
        self.requestID = requestID
        self.expiresAt = expiresAt
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
        self.verificationCode = material.verificationCode
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
            _ = try material.unwrap(result)
            return .approved
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
        guard ["create", "poll", "cancel"].contains(action) else { throw TodexError.invalid(String(localized: "设备验证操作无效", bundle: .module)) }
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

    init(requestID: String, privateKey: Curve25519.KeyAgreement.PrivateKey, serverPublicKey: Data, device: DeviceIdentity) throws {
        let shared = try CryptoEncoding.sharedSecret(privateKey: privateKey, publicKey: serverPublicKey)
        // v2 binds the enrolled device key into the verification code and the
        // wrap key, so a MITM cannot substitute its own device identity.
        let transcript =
            Data("todex.device-pairing.v2/transcript\0\(requestID)\0".utf8) + privateKey.publicKey.rawRepresentation
            + serverPublicKey + Data([0]) + device.publicKey
        let salt = Data(SHA256.hash(data: transcript))
        self.transcript = transcript
        deviceID = device.deviceID
        wrapKey = CryptoEncoding.derive(ikm: shared, salt: salt, info: "todex.device-pairing.v2/wrap-key")
        pollProof = CryptoEncoding.derive(ikm: shared, salt: salt, info: "todex.device-pairing.v2/poll-proof")
        cancelProof = CryptoEncoding.derive(ikm: shared, salt: salt, info: "todex.device-pairing.v2/cancel-proof")
        let hex = salt.prefix(5).map { String(format: "%02X", $0) }.joined()
        verificationCode = "\(hex.prefix(5))-\(hex.suffix(5))"
    }

    /// Decrypts the delivered credential and returns the enrolled device ID.
    /// The backend pins it to this key; the check defends the contract anyway.
    func unwrap(_ response: JSONValue) throws -> String {
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
        return payload.deviceID
    }

    private struct Credential: Decodable {
        let deviceId: String
        var deviceID: String { deviceId }
    }
}
