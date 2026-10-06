import CryptoKit
import Foundation

/// History crypto v1, byte-for-byte identical to the backend's
/// `src/history_crypto.rs` and TodeX_protocol's `historyCrypto.ts`, pinned by
/// `history-crypto-v1.json`. Devices hold X-Wing (ML-KEM-768 + X25519)
/// private keys; the backend wraps each segment's random DEK for every device
/// public key and seals history content under that DEK.
public enum HistoryCrypto {
    public static let label = Data("todex-history-v1".utf8)
    public static let publicKeyLength = 1216
    public static let kemCiphertextLength = 1120
    public static let recipientIDLength = 16
    public static let kidLength = 16
    public static let dekLength = 32
    public static let wrappedDEKLength = dekLength + 16

    /// Which record a content ciphertext belongs to; part of its nonce and AAD.
    public enum ContentStream: UInt32, Sendable, CaseIterable {
        case eventSummary = 1
        case eventFull = 2
        case frameSummary = 3
        case frameFull = 4
    }

    /// A per-segment content key. `SymmetricKey` zeroizes the DEK on release.
    public struct SegmentKey: Sendable {
        public let kid: Data
        let dek: SymmetricKey

        public init(kid: Data, dek: SymmetricKey) throws {
            guard kid.count == kidLength, dek.bitCount == dekLength * 8 else {
                throw TodexError.invalid(String(localized: "历史记录密钥长度无效", bundle: .module))
            }
            self.kid = joined(kid)
            self.dek = dek
        }

        public static func generate() -> SegmentKey {
            SegmentKey(
                uncheckedKid: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }, dek: SymmetricKey(size: .bits256))
        }

        private init(uncheckedKid kid: Data, dek: SymmetricKey) {
            self.kid = kid
            self.dek = dek
        }
    }

    /// A DEK wrapped for one recipient. Codable as `{"rid","kemCt","wrapped"}`,
    /// each base64url without padding.
    public struct WrappedKey: Codable, Sendable, Equatable {
        public let rid: Data
        public let kemCt: Data
        public let wrapped: Data

        public init(rid: Data, kemCt: Data, wrapped: Data) throws {
            guard rid.count == recipientIDLength, kemCt.count == kemCiphertextLength, wrapped.count == wrappedDEKLength
            else { throw TodexError.invalid(String(localized: "历史记录包装密钥格式无效", bundle: .module)) }
            self.rid = joined(rid)
            self.kemCt = joined(kemCt)
            self.wrapped = joined(wrapped)
        }

        private enum CodingKeys: String, CodingKey { case rid, kemCt, wrapped }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                rid: CryptoEncoding.decode(container.decode(String.self, forKey: .rid), count: recipientIDLength),
                kemCt: CryptoEncoding.decode(container.decode(String.self, forKey: .kemCt), count: kemCiphertextLength),
                wrapped: CryptoEncoding.decode(container.decode(String.self, forKey: .wrapped), count: wrappedDEKLength))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(CryptoEncoding.encode(rid), forKey: .rid)
            try container.encode(CryptoEncoding.encode(kemCt), forKey: .kemCt)
            try container.encode(CryptoEncoding.encode(wrapped), forKey: .wrapped)
        }
    }

    /// A new device key pair; persist `seedRepresentation` (32 bytes).
    public static func generateRecipientKey() throws -> XWingMLKEM768X25519.PrivateKey {
        try XWingMLKEM768X25519.PrivateKey.generate()
    }

    public static func recipientKey(seed: Data) throws -> XWingMLKEM768X25519.PrivateKey {
        guard seed.count == 32, let key = try? XWingMLKEM768X25519.PrivateKey(seedRepresentation: seed, publicKey: nil)
        else { throw TodexError.invalid(String(localized: "历史记录私钥无效", bundle: .module)) }
        return key
    }

    /// `SHA-256(pk)[0..16]`, how wrapped keys name their recipient.
    public static func recipientID(publicKey: Data) throws -> Data {
        guard publicKey.count == publicKeyLength else {
            throw TodexError.invalid(String(localized: "历史记录公钥长度无效", bundle: .module))
        }
        return Data(SHA256.hash(data: publicKey).prefix(recipientIDLength))
    }

    /// Wraps the segment DEK for one recipient under a fresh X-Wing encapsulation.
    public static func wrap(_ key: SegmentKey, for publicKey: Data) throws -> WrappedKey {
        let rid = try recipientID(publicKey: publicKey)
        let encapsulation: KEM.EncapsulationResult
        do {
            encapsulation = try XWingMLKEM768X25519.PublicKey(rawRepresentation: publicKey).encapsulate()
        } catch {
            throw TodexError.invalid(String(localized: "历史记录公钥无效", bundle: .module))
        }
        let info = wrapInfo(kid: key.kid, rid: rid)
        let kek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: encapsulation.sharedSecret, salt: encapsulation.encapsulated, info: info,
            outputByteCount: 32)
        // A zero nonce is safe: every encapsulation yields a fresh KEK.
        let box = try key.dek.withUnsafeBytes { dek in
            try ChaChaPoly.seal(Data(dek), using: kek, nonce: zeroNonce(), authenticating: info)
        }
        return try WrappedKey(rid: rid, kemCt: encapsulation.encapsulated, wrapped: joined(box.ciphertext, box.tag))
    }

    /// Device-side unwrap of a DEK wrapped for `privateKey`.
    public static func unwrap(
        _ wrapped: WrappedKey, kid: Data, with privateKey: XWingMLKEM768X25519.PrivateKey
    ) throws -> SegmentKey {
        let rid = try recipientID(publicKey: privateKey.publicKey.rawRepresentation)
        guard rid == wrapped.rid else {
            throw TodexError.invalid(String(localized: "历史记录密钥不属于当前设备", bundle: .module))
        }
        guard kid.count == kidLength else {
            throw TodexError.invalid(String(localized: "历史记录密钥长度无效", bundle: .module))
        }
        let info = wrapInfo(kid: kid, rid: rid)
        do {
            let shared = try privateKey.decapsulate(wrapped.kemCt)
            let kek = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: shared, salt: wrapped.kemCt, info: info, outputByteCount: 32)
            let box = try ChaChaPoly.SealedBox(
                nonce: zeroNonce(), ciphertext: wrapped.wrapped.prefix(dekLength), tag: wrapped.wrapped.suffix(16))
            return try SegmentKey(kid: kid, dek: SymmetricKey(data: ChaChaPoly.open(box, using: kek, authenticating: info)))
        } catch {
            throw TodexError.invalid(String(localized: "历史记录密钥认证失败", bundle: .module))
        }
    }

    /// Seals one record. `counter` is the event sequence or frame index.
    public static func seal(
        _ plaintext: Data, key: SegmentKey, conversationID: String, stream: ContentStream, counter: UInt64
    ) throws -> Data {
        let (nonce, aad) = try contentParams(key: key, conversationID: conversationID, stream: stream, counter: counter)
        let box = try ChaChaPoly.seal(plaintext, using: key.dek, nonce: nonce, authenticating: aad)
        return joined(box.ciphertext, box.tag)
    }

    public static func open(
        _ ciphertext: Data, key: SegmentKey, conversationID: String, stream: ContentStream, counter: UInt64
    ) throws -> Data {
        let (nonce, aad) = try contentParams(key: key, conversationID: conversationID, stream: stream, counter: counter)
        do {
            guard ciphertext.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce, ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            return try ChaChaPoly.open(box, using: key.dek, authenticating: aad)
        } catch {
            throw TodexError.invalid(String(localized: "历史记录密文认证失败", bundle: .module))
        }
    }

    /// Fresh zero-based `Data`: CryptoKit returns slices of a combined buffer,
    /// and `slice + other` keeps the slice's non-zero `startIndex`.
    private static func joined(_ parts: Data...) -> Data {
        var output = Data(capacity: parts.reduce(0) { $0 + $1.count })
        for part in parts { output.append(part) }
        return output
    }

    private static func zeroNonce() throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data(count: 12))
    }

    /// `LABEL || "/wrap" || kid || rid`: the HKDF info and the AEAD AAD.
    static func wrapInfo(kid: Data, rid: Data) -> Data {
        label + Data("/wrap".utf8) + kid + rid
    }

    /// Nonce `u32_be(stream) || u64_be(counter)`; AAD
    /// `LABEL || "/content" || 0 || conversation id || 0 || kid || nonce`.
    static func contentParams(
        key: SegmentKey, conversationID: String, stream: ContentStream, counter: UInt64
    ) throws -> (ChaChaPoly.Nonce, Data) {
        let position = withUnsafeBytes(of: stream.rawValue.bigEndian) { Data($0) }
            + withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let aad = label + Data("/content".utf8) + [0] + Data(conversationID.utf8) + [0] + key.kid + position
        return (try ChaChaPoly.Nonce(data: position), aad)
    }
}
