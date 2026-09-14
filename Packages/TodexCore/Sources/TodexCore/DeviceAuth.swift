import CryptoKit
import Foundation
import Security

/// Per-device Ed25519 identity. The 32-byte seed is the only secret material;
/// it is stored in Keychain and never leaves the device. `deviceID` is
/// `dev_` + base64url of the first 12 bytes of SHA-256(public key), matching
/// the daemon's registry derivation.
public struct DeviceIdentity: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey
    /// Raw 32-byte Ed25519 public key.
    public let publicKey: Data
    public let publicKeyBase64URL: String
    public let deviceID: String

    public init() {
        self.init(privateKey: Curve25519.Signing.PrivateKey())
    }

    /// Restores the identity from a stored base64url seed. Returns nil for
    /// malformed input so callers can trigger a fresh device pairing.
    public init?(secretKeyBase64URL: String) {
        guard let seed = try? CryptoEncoding.decode(secretKeyBase64URL, count: 32),
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else { return nil }
        self.init(privateKey: key)
    }

    private init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        publicKey = privateKey.publicKey.rawRepresentation
        publicKeyBase64URL = CryptoEncoding.encode(publicKey)
        deviceID = "dev_" + CryptoEncoding.encode(
            Data(SHA256.hash(data: privateKey.publicKey.rawRepresentation)).prefix(12))
    }

    public var secretKeyBase64URL: String {
        CryptoEncoding.encode(privateKey.rawRepresentation)
    }

    static let signDomain = "todex.device-auth.v1"
    static let authQueryKeys: Set<String> = ["device_id", "auth_ts", "auth_nonce", "auth_sig"]

    /// The signed payload: domain + deviceID, method, path, canonical query,
    /// timestamp, nonce and base64url(SHA-256(body)), NUL-joined.
    public static func payload(
        deviceID: String, method: String, path: String, canonicalQuery: String,
        timestamp: String, nonce: String, body: Data
    ) -> Data {
        Data(
            "\(signDomain)\0\(deviceID)\0\(method)\0\(path)\0\(canonicalQuery)\0\(timestamp)\0\(nonce)\0\(CryptoEncoding.encode(Data(SHA256.hash(data: body))))"
                .utf8)
    }

    /// application/x-www-form-urlencoded decoding: '+' is a space, %XX a byte.
    static func formDecode(_ value: String) -> String {
        var bytes: [UInt8] = []
        var index = 0
        let utf8 = Array(value.utf8)
        while index < utf8.count {
            let byte = utf8[index]
            if byte == 0x2B {
                bytes.append(0x20)
            } else if byte == 0x25, index + 2 < utf8.count,
                let high = hexValue(utf8[index + 1]), let low = hexValue(utf8[index + 2])
            {
                bytes.append(high << 4 | low)
                index += 2
            } else {
                bytes.append(byte)
            }
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// RFC 3986 unreserved characters pass through; everything else is %XX.
    static func strictEncode(_ value: String) -> String {
        value.utf8.map { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 46, 95, 126].contains(byte)
                ? String(UnicodeScalar(byte)) : escapeByte(byte)
        }.joined()
    }

    /// Canonical signed-query form: decode form pairs, drop the credential
    /// keys, re-encode each side and sort. Must byte-match the daemon.
    public static func canonicalQuery(_ query: String) -> String {
        guard !query.isEmpty else { return "" }
        return query.split(separator: "&", omittingEmptySubsequences: true)
            .map { pair -> (String, String) in
                let text = String(pair)
                guard let separator = text.firstIndex(of: "=") else {
                    return (strictEncode(formDecode(text)), "")
                }
                return (
                    strictEncode(formDecode(String(text[..<separator]))),
                    strictEncode(formDecode(String(text[text.index(after: separator)...])))
                )
            }
            .filter { !authQueryKeys.contains($0.0) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// Signed headers for an HTTP request (or a WebSocket handshake that can
    /// set headers). `pathAndQuery` is the request target as sent on the wire.
    public func authHeaders(method: String, pathAndQuery: String, body: Data = Data()) throws -> [String: String] {
        let (path, query) = Self.split(pathAndQuery)
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var nonceBytes = Data(count: 16)
        _ = nonceBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let nonce = CryptoEncoding.encode(nonceBytes)
        let signature = try privateKey.signature(
            for: Self.payload(
                deviceID: deviceID, method: method, path: path,
                canonicalQuery: Self.canonicalQuery(query), timestamp: timestamp, nonce: nonce, body: body))
        return [
            "x-todex-device-id": deviceID,
            "x-todex-auth-ts": timestamp,
            "x-todex-auth-nonce": nonce,
            "x-todex-auth-sig": CryptoEncoding.encode(signature),
        ]
    }

    /// Credential as URL query parameters for clients that cannot set headers.
    /// The signature covers the existing query — including transport-encryption
    /// handshake parameters.
    public func authQuery(pathAndQuery: String) throws -> String {
        let headers = try authHeaders(method: "GET", pathAndQuery: pathAndQuery)
        return [
            "device_id": deviceID,
            "auth_ts": headers["x-todex-auth-ts"]!,
            "auth_nonce": headers["x-todex-auth-nonce"]!,
            "auth_sig": headers["x-todex-auth-sig"]!,
        ].map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    private static func split(_ pathAndQuery: String) -> (String, String) {
        guard let separator = pathAndQuery.firstIndex(of: "?") else { return (pathAndQuery, "") }
        return (String(pathAndQuery[..<separator]), String(pathAndQuery[pathAndQuery.index(after: separator)...]))
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 65 + 10
        case 97...102: return byte - 97 + 10
        default: return nil
        }
    }

    private static func escapeByte(_ byte: UInt8) -> String {
        String(format: "%%%02X", byte)
    }
}
