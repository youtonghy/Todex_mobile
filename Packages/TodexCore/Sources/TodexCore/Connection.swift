import Foundation

public enum EncryptionProtocol: String, Codable, CaseIterable, Sendable {
    case none, x25519
    case mlkem768 = "ml-kem-768"
}

public struct BackendConnection: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var serverURL: String
    /// Base64url-encoded Ed25519 seed of this device's key, loaded from Keychain.
    /// Never persisted in the connection catalog; empty means "not enrolled".
    public var deviceSecret: String
    public var tenantId: String
    public var encryption: EncryptionProtocol
    public var publicKey: String
    /// Label color as `#rrggbb`. An empty or non-hex value (older builds stored
    /// "teal") counts as unset and resolves to the id-derived default.
    public var color: String
    public init(
        id: String = UUID().uuidString, name: String = "我的后端", serverURL: String = "http://127.0.0.1:7345",
        deviceSecret: String = "", tenantId: String = "local", encryption: EncryptionProtocol = .none,
        publicKey: String = "", color: String = ""
    ) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.deviceSecret = deviceSecret
        self.tenantId = tenantId
        self.encryption = encryption
        self.publicKey = publicKey
        self.color = Self.normalizeLabelColor(color) ?? Self.defaultLabelColor(for: id)
    }
    // The device key lives in Keychain only.
    enum CodingKeys: String, CodingKey { case id, name, serverURL, tenantId, encryption, publicKey, color }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        serverURL = try c.decode(String.self, forKey: .serverURL)
        deviceSecret = ""
        tenantId = try c.decodeIfPresent(String.self, forKey: .tenantId) ?? "local"
        encryption = try c.decodeIfPresent(EncryptionProtocol.self, forKey: .encryption) ?? .none
        publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        let stored = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        color = Self.normalizeLabelColor(stored) ?? Self.defaultLabelColor(for: id)
    }
    /// The effective label color: the saved hex value, else the id-derived default.
    public var labelColor: String { Self.normalizeLabelColor(color) ?? Self.defaultLabelColor(for: id) }
    /// Desktop `BACKEND_LABEL_COLORS`, shared by backend and conversation labels.
    public static let labelColors = [
        "#3b82f6", "#8b5cf6", "#ec4899", "#ef4444", "#f97316", "#eab308", "#22c55e", "#06b6d4",
    ]
    public static func normalizeLabelColor(_ value: String) -> String? {
        let value = value.lowercased()
        guard value.count == 7, value.hasPrefix("#"), value.dropFirst().allSatisfy("0123456789abcdef".contains)
        else { return nil }
        return value
    }
    /// Same 31-multiplier hash as desktop `backendLabelColor` (which iterates
    /// code points and reads each one's first UTF-16 unit), so one backend id
    /// gets one color on every client.
    public static func defaultLabelColor(for id: String) -> String {
        var hash: UInt32 = 0
        for scalar in id.unicodeScalars { hash = hash &* 31 &+ UInt32(scalar.utf16.first ?? 0) }
        return labelColors[Int(hash % UInt32(labelColors.count))]
    }
    public func normalizedURL() throws -> URL { try Self.normalize(serverURL) }
    public static func normalize(_ raw: String) throws -> URL {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: raw), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
            let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
            c.query == nil, c.fragment == nil
        else { throw TodexError.invalid(CoreMessage.enterValidAddress) }
        if c.path.hasPrefix("/v1") { throw TodexError.invalid(CoreMessage.v1Removed) }
        guard ["", "/", "/v2", "/v2/"].contains(c.path) else { throw TodexError.invalid(CoreMessage.rootAddressOnly) }
        c.path = ""
        c.host = host.lowercased()
        c.scheme = c.scheme?.lowercased()
        guard let result = c.url else { throw TodexError.invalid(CoreMessage.invalidAddress) }
        return result
    }
}

/// How saving the backend catalog treats device secrets, which live in the
/// Keychain apart from it. Writing an empty secret deletes the item, so a
/// secret that could not be read at launch (a locked device answers
/// `errSecInteractionNotAllowed`) must never be written back as "". Secrets go
/// away only with their profile, or when the profile's address changes (a
/// different backend); an empty secret from a stale copy of an unchanged
/// profile keeps the current one.
public struct DeviceCredentialPlan: Sendable, Equatable {
    public struct Write: Sendable, Equatable {
        public let id: String
        /// Empty deletes the Keychain item.
        public let secret: String
        public init(id: String, secret: String) {
            self.id = id
            self.secret = secret
        }
    }

    /// The catalog to keep in memory, kept secrets carried over.
    public let connections: [BackendConnection]
    /// Keychain writes in order.
    public let writes: [Write]
    /// Profiles whose stored secret is still unknown (nothing written).
    public let unreadable: Set<String>

    public init(saving values: [BackendConnection], current: [BackendConnection], unreadable: Set<String>) {
        var connections: [BackendConnection] = []
        var writes: [Write] = []
        var stillUnreadable: Set<String> = []
        for value in values {
            let existing = current.first { $0.id == value.id }
            let kept = Self.keepingSecret(value, of: existing)
            connections.append(kept)
            if kept.deviceSecret.isEmpty, unreadable.contains(kept.id), Self.sameAddress(kept, existing) {
                stillUnreadable.insert(kept.id)
                continue
            }
            writes.append(Write(id: kept.id, secret: kept.deviceSecret))
        }
        for old in current where !values.contains(where: { $0.id == old.id }) {
            writes.append(Write(id: old.id, secret: ""))
        }
        self.connections = connections
        self.writes = writes
        self.unreadable = stillUnreadable
    }

    /// `value` with `existing`'s secret when `value` carries none and still
    /// points at the same backend.
    public static func keepingSecret(_ value: BackendConnection, of existing: BackendConnection?) -> BackendConnection {
        guard value.deviceSecret.isEmpty, let existing, sameAddress(value, existing) else { return value }
        var kept = value
        kept.deviceSecret = existing.deviceSecret
        return kept
    }

    private static func sameAddress(_ lhs: BackendConnection, _ rhs: BackendConnection?) -> Bool {
        guard let rhs, lhs.id == rhs.id else { return false }
        func address(_ connection: BackendConnection) -> String {
            (try? connection.normalizedURL().absoluteString)
                ?? connection.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return address(lhs) == address(rhs)
    }
}

/// TodexCore's string catalog; tests resolve expected text through it so they
/// hold under any process language.
enum CoreLocalization {
    static var bundle: Bundle { .module }
}

/// Messages ConnectionDiagnostic also recognizes. One localized source per
/// message keeps that classification independent of the display language.
enum CoreMessage {
    static var enterValidAddress: String { String(localized: "请输入有效的 HTTP 或 HTTPS 后端地址", bundle: .module) }
    static var v1Removed: String { String(localized: "/v1 协议已移除，请使用后端根地址", bundle: .module) }
    static var rootAddressOnly: String { String(localized: "请填写后端根地址，不包含接口路径", bundle: .module) }
    static var invalidAddress: String { String(localized: "后端地址无效", bundle: .module) }
    static var handshakeFailed: String { String(localized: "后端握手验证失败", bundle: .module) }
    static var invalidPolicy: String { String(localized: "后端加密要求无效", bundle: .module) }
    static var responseTooLarge: String { String(localized: "后端响应过大", bundle: .module) }
    static var addressMessages: [String] { [enterValidAddress, rootAddressOnly, invalidAddress] }
    static var handshakeMessages: [String] { [handshakeFailed, invalidPolicy] }
}

public enum TodexError: Error, LocalizedError, Sendable {
    case invalid(String)
    case server(code: String, message: String)
    case disconnected
    case unknownOutcome(String)
    /// Local setup that the backend rejects every time (encryption policy,
    /// missing or unusable public key). Retrying cannot succeed; the user must
    /// fix the connection, so reconnect loops stop on this case.
    case configuration(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .configuration(let s): s
        case .server(HistoryEncryption.clientUpgradeRequired, _):
            String(localized: "此后端已开启会话历史端到端加密，当前客户端无法读取，请更新 TodeX 应用。", bundle: .module)
        case .server(HistoryEncryption.accessRevoked, _):
            String(localized: "此设备的历史访问已被吊销，需由其他已授权设备恢复", bundle: .module)
        case .server(HistoryEncryption.readOnly, _):
            String(localized: "这是旧版未加密的历史，只能查看、导出、归档或删除", bundle: .module)
        case .server(HistoryEncryption.keyRequired, _):
            String(localized: "本设备尚未登记历史密钥，正在重新登记，请稍后重试", bundle: .module)
        case .server(HistoryEncryption.storageLow, _), .server("507", _):
            String(localized: "后端所在电脑的磁盘可用空间不足 1 GiB，暂时无法发送新消息。请清理磁盘后重试。", bundle: .module)
        case .server(_, let message): message
        case .disconnected: String(localized: "连接已断开，请重新连接后端", bundle: .module)
        case .unknownOutcome(let s): String(localized: "操作结果未知：\(s)。请先核对记录，避免重复执行。", bundle: .module)
        }
    }

    /// Failures a reconnect cannot fix: the backend rejected the device's
    /// credentials, or the local transport setup does not match its policy.
    public static func stopsReconnect(_ error: any Error) -> Bool {
        switch error {
        case TodexError.configuration: true
        case TodexError.server(let code, _): ["401", "403", "UNAUTHENTICATED", "UNAUTHORIZED"].contains(code)
        default: false
        }
    }
}
