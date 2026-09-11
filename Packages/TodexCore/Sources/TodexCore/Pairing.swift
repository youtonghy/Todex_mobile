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
        guard raw.utf8.count <= Self.maximumBytes else { throw TodexError.invalid("配对内容过大") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(raw.utf8))
        guard envelope.version == 1 else { throw TodexError.invalid("不支持的配对版本") }
        if envelope.kind == "todex-pairing-link" {
            let connection = try Self.importLink(Data(raw.utf8), current: current)
            self = Self()
            return connection
        }
        guard envelope.kind == "todex-pairing-chunk" else { throw TodexError.invalid("不是有效的 TodeX 配对二维码") }
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(raw.utf8))
        guard (1...128).contains(chunk.total), (1...chunk.total).contains(chunk.index),
            !chunk.data.isEmpty, chunk.data.utf8.count <= 4096, chunk.data.utf8.allSatisfy(CryptoEncoding.isBase64URL)
        else {
            throw TodexError.invalid("配对分片内容或序号无效")
        }
        _ = try CryptoEncoding.decode(chunk.checksum, count: 32)
        guard checksum == nil || (checksum == chunk.checksum && totalCount == chunk.total) else {
            throw TodexError.invalid("配对分片不属于同一批次")
        }
        if let previous = chunks[chunk.index], previous != chunk.data { throw TodexError.invalid("同一序号的配对分片内容冲突") }
        var candidate = chunks
        candidate[chunk.index] = chunk.data
        guard candidate.values.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumBytes else {
            throw TodexError.invalid("配对分片内容过大")
        }
        if candidate.count == chunk.total {
            let encoded = (1...chunk.total).compactMap { candidate[$0] }.joined()
            let payload = try CryptoEncoding.decode(encoded)
            guard CryptoEncoding.encode(Data(SHA256.hash(data: payload))) == chunk.checksum else {
                throw TodexError.invalid("配对分片校验失败")
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
        guard String(data: data, encoding: .utf8) != nil else { throw TodexError.invalid("配对链接不是有效 UTF-8") }
        let link = try JSONDecoder().decode(Link.self, from: data)
        guard link.kind == "todex-pairing-link", link.version == 1 else { throw TodexError.invalid("无效的配对链接") }
        let server = try BackendConnection.normalize(link.serverUrl)
        let protocolID = try parseProtocol(link.protocol?.id)
        let selected = try parseProtocol(link.preferredEncryption) ?? protocolID ?? .none
        let key: String
        if selected == .none {
            key = ""
        } else {
            guard protocolID == selected, let importedKey = link.protocol?.publicKey else {
                throw TodexError.invalid("配对加密方式和公钥不匹配")
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
        if let token = link.authToken, !token.isEmpty { try PairingMaterial.validateToken(token) }
        var result = current
        result.serverURL = server.absoluteString
        result.encryption = selected
        result.publicKey = key
        let sameBackend = (try? current.normalizedURL()) == server
        result.token = link.authToken.flatMap { $0.isEmpty ? nil : $0 } ?? (sameBackend ? current.token : "")
        return result
    }

    private static func parseProtocol(_ value: String?) throws -> EncryptionProtocol? {
        guard let value else { return nil }
        guard let result = EncryptionProtocol(rawValue: value) else { throw TodexError.invalid("不支持的配对加密协议") }
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
        let authToken: String?
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
    case approved(String)
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

    public static func begin(connection: BackendConnection, deviceName: String) async throws -> DevicePairingSession {
        _ = try connection.normalizedURL()
        let client = HTTPClient(connection: connection)
        return try await begin(
            deviceName: deviceName, privateKey: .init(),
            post: { action, body in
                try await PairingBootstrap.post(client: client, action: action, body: body)
            })
    }

    // Injectable endpoint and clock keep state/race tests independent of a live
    // backend; production always uses the unauthenticated HTTPClient above.
    static func begin(
        deviceName: String, privateKey: Curve25519.KeyAgreement.PrivateKey, post: @escaping PairingPost,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }
    ) async throws -> DevicePairingSession {
        try Task.checkCancellation()
        let publicKey = privateKey.publicKey.rawRepresentation
        let response = try await post(
            "create",
            [
                "clientPublicKey": .string(CryptoEncoding.encode(publicKey)),
                "deviceName": .string(sanitizedDeviceName(deviceName)),
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
            throw TodexError.invalid("设备验证申请无效或已过期，请重新申请")
        }
        let serverKey = try CryptoEncoding.decode(encodedServerKey, count: 32)
        let material = try PairingMaterial(requestID: id, privateKey: privateKey, serverPublicKey: serverKey)
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
        guard !polling else { throw TodexError.invalid("设备验证正在查询，请稍候") }
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
            throw TodexError.invalid("设备验证响应状态无效")
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
        guard ["create", "poll", "cancel"].contains(action) else { throw TodexError.invalid("设备验证操作无效") }
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                let result = try await client.request(
                    .post, path: "/v2/device-pairing/\(action)", body: body, authenticated: false)
                try Task.checkCancellation()
                guard case .object = result, try JSONEncoder().encode(result).count <= 16_384 else {
                    throw TodexError.invalid("设备验证响应无效或过大")
                }
                return result
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TodexError.invalid("设备验证请求超时，请检查后端连接")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}

struct PairingMaterial: Sendable {
    let transcript: Data
    let wrapKey: SymmetricKey
    let pollProof: SymmetricKey
    let cancelProof: SymmetricKey
    let verificationCode: String

    init(requestID: String, privateKey: Curve25519.KeyAgreement.PrivateKey, serverPublicKey: Data) throws {
        let shared = try CryptoEncoding.sharedSecret(privateKey: privateKey, publicKey: serverPublicKey)
        let transcript =
            Data("todex.device-pairing.v1/transcript\0\(requestID)\0".utf8) + privateKey.publicKey.rawRepresentation
            + serverPublicKey
        let salt = Data(SHA256.hash(data: transcript))
        self.transcript = transcript
        wrapKey = CryptoEncoding.derive(ikm: shared, salt: salt, info: "todex.device-pairing.v1/wrap-key")
        pollProof = CryptoEncoding.derive(ikm: shared, salt: salt, info: "todex.device-pairing.v1/poll-proof")
        cancelProof = CryptoEncoding.derive(ikm: shared, salt: salt, info: "todex.device-pairing.v1/cancel-proof")
        let hex = salt.prefix(5).map { String(format: "%02X", $0) }.joined()
        verificationCode = "\(hex.prefix(5))-\(hex.suffix(5))"
    }

    func unwrap(_ response: JSONValue) throws -> String {
        guard let nonceText = response["nonce"].optionalString,
            let ciphertextText = response["ciphertext"].optionalString,
            nonceText.utf8.count <= 16_384, ciphertextText.utf8.count <= 16_384
        else { throw TodexError.invalid("设备验证密文无效") }
        let nonce = try CryptoEncoding.decode(nonceText, count: 24)
        var plaintext = try XChaChaAEAD.open(
            CryptoEncoding.decode(ciphertextText), key: wrapKey, nonce: nonce, aad: transcript)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        // JSONDecoder accepts alternate text encodings; the protocol requires UTF-8.
        guard String(data: plaintext, encoding: .utf8) != nil else { throw TodexError.invalid("设备验证密文不是 UTF-8") }
        let payload = try JSONDecoder().decode(Credential.self, from: plaintext)
        try Self.validateToken(payload.authToken)
        return payload.authToken
    }

    static func validateToken(_ token: String) throws {
        // Swift treats CRLF as one grapheme, so Character-based contains("\r")
        // or contains("\n") misses that pair. Inspect the scalar values instead.
        guard !token.isEmpty, token.utf16.count <= 4096,
            !token.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 })
        else { throw TodexError.invalid("设备验证令牌无效") }
    }

    private struct Credential: Decodable { let authToken: String }
}
