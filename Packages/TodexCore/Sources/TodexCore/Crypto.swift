import Clibsodium
import CryptoKit
import Foundation

/// A single WebSocket's crypto state. The owning realtime actor must use this
/// class serially. Create a new instance for every connection attempt: the
/// backend rejects reused handshake material, and nonces must never restart
/// under the same key. This type deliberately does not conform to Sendable.
public final class TransportCryptoSession {
    public let handshakeHeaders: [String: String]
    /// Same material as URL query parameters (`enc`, `client_key`/`ciphertext`).
    /// The device signature covers the query, binding this handshake to the
    /// enrolled device identity; the daemon treats query values as authoritative.
    public let handshakeQuery: String
    private let encryption: EncryptionProtocol
    private let key: SymmetricKey
    private var sendCounter: UInt64
    private var receiveCounter: UInt64

    public convenience init(connection: BackendConnection) throws {
        let publicKey = try CryptoEncoding.decode(connection.publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let material: TransportKeyMaterial
        switch connection.encryption {
        case .none:
            throw TodexError.invalid(String(localized: "未启用加密时不应创建加密会话", bundle: .module))
        case .x25519:
            material = try .x25519(serverPublicKey: publicKey, privateKey: .init())
        case .mlkem768:
            guard publicKey.count == 1184 else { throw TodexError.invalid(String(localized: "ML-KEM-768 公钥长度无效", bundle: .module)) }
            let encapsulation = try MLKEM768.PublicKey(rawRepresentation: publicKey).encapsulate()
            material = TransportKeyMaterial(
                key: CryptoEncoding.derive(
                    ikm: encapsulation.sharedSecret, salt: publicKey + encapsulation.encapsulated, info: "ml-kem-768"),
                headers: [
                    "x-todex-encryption": "ml-kem-768",
                    "x-todex-kem-ciphertext": CryptoEncoding.encode(encapsulation.encapsulated),
                ]
            )
        }
        self.init(encryption: connection.encryption, key: material.key, handshakeHeaders: material.headers)
    }

    // Internal injection permits independent protocol vectors and boundary tests
    // without exposing deterministic handshake material to application callers.
    init(
        encryption: EncryptionProtocol, key: SymmetricKey, handshakeHeaders: [String: String] = [:],
        sendCounter: UInt64 = 0, receiveCounter: UInt64 = 0
    ) {
        self.encryption = encryption
        self.key = key
        self.handshakeHeaders = handshakeHeaders
        self.handshakeQuery = handshakeHeaders
            .compactMap { name, value -> String? in
                switch name {
                case "x-todex-encryption": return "enc=\(HTTPClient.segment(value))"
                case "x-todex-client-key": return "client_key=\(HTTPClient.segment(value))"
                case "x-todex-kem-ciphertext": return "ciphertext=\(HTTPClient.segment(value))"
                default: return nil
                }
            }
            .sorted().joined(separator: "&")
        self.sendCounter = sendCounter
        self.receiveCounter = receiveCounter
    }

    public func encrypt(_ plaintext: String) throws -> String {
        guard sendCounter < UInt64.max else { throw TodexError.invalid(String(localized: "加密帧计数已耗尽，请重新连接", bundle: .module)) }
        let nonce = Self.nonce(direction: 2, counter: sendCounter)
        // Reserve before encryption so an error can never reuse a nonce.
        sendCounter += 1
        let ciphertext = try XChaChaAEAD.seal(Data(plaintext.utf8), key: key, nonce: nonce, aad: Self.aad)
        let frame = Frame(
            type: "todex.crypto.v1", protocol: encryption.rawValue, nonce: CryptoEncoding.encode(nonce),
            ciphertext: CryptoEncoding.encode(ciphertext))
        return String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
    }

    public func decrypt(_ frame: String) throws -> String {
        let wrapped = try JSONDecoder().decode(Frame.self, from: Data(frame.utf8))
        guard wrapped.type == "todex.crypto.v1", wrapped.protocol == encryption.rawValue else {
            throw TodexError.invalid(String(localized: "加密帧类型或协议不匹配", bundle: .module))
        }
        let nonce = try CryptoEncoding.decode(wrapped.nonce, count: 24)
        guard nonce[0] == 1, nonce[1..<8].allSatisfy({ $0 == 0 }), nonce[16..<24].allSatisfy({ $0 == 0 }) else {
            throw TodexError.invalid(String(localized: "加密帧 nonce 方向或格式无效", bundle: .module))
        }
        guard receiveCounter < UInt64.max else { throw TodexError.invalid(String(localized: "加密帧计数已耗尽，请重新连接", bundle: .module)) }
        let counter = nonce[8..<16].enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
        guard counter == receiveCounter else { throw TodexError.invalid(String(localized: "加密帧重复或乱序", bundle: .module)) }
        let plaintext = try XChaChaAEAD.open(
            CryptoEncoding.decode(wrapped.ciphertext), key: key, nonce: nonce, aad: Self.aad)
        // Authentication consumes the counter even if the payload is not UTF-8,
        // matching the backend; failed authentication never advances it.
        receiveCounter += 1
        guard let text = String(data: plaintext, encoding: .utf8) else { throw TodexError.invalid(String(localized: "加密帧不是有效 UTF-8", bundle: .module)) }
        return text
    }

    static let aad = Data("todex-ws-transport-crypto-v1".utf8)

    static func nonce(direction: UInt8, counter: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0] = direction
        for index in 0..<8 { bytes[8 + index] = UInt8(truncatingIfNeeded: counter >> (index * 8)) }
        return Data(bytes)
    }

    private struct Frame: Codable {
        let type: String
        let `protocol`: String
        let nonce: String
        let ciphertext: String
    }
}

struct TransportKeyMaterial {
    let key: SymmetricKey
    let headers: [String: String]

    static func x25519(serverPublicKey: Data, privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Self {
        let shared = try CryptoEncoding.sharedSecret(privateKey: privateKey, publicKey: serverPublicKey)
        let clientPublic = privateKey.publicKey.rawRepresentation
        return Self(
            key: CryptoEncoding.derive(ikm: shared, salt: serverPublicKey + clientPublic, info: "x25519"),
            headers: ["x-todex-encryption": "x25519", "x-todex-client-key": CryptoEncoding.encode(clientPublic)]
        )
    }
}

enum CryptoEncoding {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String, count: Int? = nil) throws -> Data {
        guard !value.isEmpty, value.utf8.allSatisfy(isBase64URL), value.utf8.count % 4 != 1 else {
            throw TodexError.invalid(String(localized: "无效的 base64url 数据", bundle: .module))
        }
        let padded =
            value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), count == nil || data.count == count, encode(data) == value else {
            throw TodexError.invalid(String(localized: "无效的 base64url 数据或长度", bundle: .module))
        }
        return data
    }

    static func isBase64URL(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
    }

    static func derive(ikm: SymmetricKey, salt: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data(info.utf8), outputByteCount: 32)
    }

    static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Data) throws -> SymmetricKey {
        guard publicKey.count == 32 else { throw TodexError.invalid(String(localized: "X25519 公钥长度无效", bundle: .module)) }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: publicKey))
        return try shared.withUnsafeBytes { bytes in
            guard bytes.contains(where: { $0 != 0 }) else { throw TodexError.invalid(String(localized: "X25519 公钥无效", bundle: .module)) }
            return SymmetricKey(data: bytes)
        }
    }
}

/// Sodium 0.11's Swift encrypt wrapper always generates a random nonce.
/// The wire protocol requires a counter nonce, so use its bundled C AEAD API
/// with validated sizes. Ciphertext includes the 16-byte authentication tag.
enum XChaChaAEAD {
    private static let initialized = sodium_init() >= 0

    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: Data, aad: Data) throws -> Data {
        guard initialized, key.bitCount == 256, nonce.count == 24, plaintext.count <= Int.max - 16 else {
            throw TodexError.invalid(String(localized: "XChaCha20 加密参数无效", bundle: .module))
        }
        var output = [UInt8](repeating: 0, count: plaintext.count + 16)
        var length: UInt64 = 0
        let result = key.withUnsafeBytes { keyBytes in
            crypto_aead_xchacha20poly1305_ietf_encrypt(
                &output, &length, Array(plaintext), UInt64(plaintext.count), Array(aad), UInt64(aad.count), nil,
                Array(nonce), keyBytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard result == 0, length == output.count else { throw TodexError.invalid(String(localized: "加密失败", bundle: .module)) }
        return Data(output)
    }

    static func open(_ ciphertext: Data, key: SymmetricKey, nonce: Data, aad: Data) throws -> Data {
        guard initialized, key.bitCount == 256, nonce.count == 24, ciphertext.count >= 16 else {
            throw TodexError.invalid(String(localized: "XChaCha20 密文或参数无效", bundle: .module))
        }
        var output = [UInt8](repeating: 0, count: max(1, ciphertext.count - 16))
        defer { output.withUnsafeMutableBytes { bytes in sodium_memzero(bytes.baseAddress!, bytes.count) } }
        var length: UInt64 = 0
        let result = key.withUnsafeBytes { keyBytes in
            crypto_aead_xchacha20poly1305_ietf_decrypt(
                &output, &length, nil, Array(ciphertext), UInt64(ciphertext.count), Array(aad), UInt64(aad.count),
                Array(nonce), keyBytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard result == 0, length == ciphertext.count - 16 else { throw TodexError.invalid(String(localized: "密文认证失败", bundle: .module)) }
        return Data(output.prefix(Int(length)))
    }
}
