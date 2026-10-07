import Clibsodium
import CryptoKit
import Foundation

/// Shared encoding and key helpers for transport v2 (`SecureChannel.swift`),
/// pairing and history encryption.
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
/// Transport v2 and pairing require caller-chosen nonces, so use its bundled C AEAD API
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
