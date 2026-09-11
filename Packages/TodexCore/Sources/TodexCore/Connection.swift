import Foundation

public enum EncryptionProtocol: String, Codable, CaseIterable, Sendable {
    case none, x25519
    case mlkem768 = "ml-kem-768"
}

public struct BackendConnection: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var serverURL: String
    public var token: String
    public var encryption: EncryptionProtocol
    public var publicKey: String
    public var color: String
    public init(
        id: String = UUID().uuidString, name: String = "我的后端", serverURL: String = "http://127.0.0.1:7345",
        token: String = "", encryption: EncryptionProtocol = .none, publicKey: String = "", color: String = "teal"
    ) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.token = token
        self.encryption = encryption
        self.publicKey = publicKey
        self.color = color
    }
    // Authentication credentials live in Keychain only.
    enum CodingKeys: String, CodingKey { case id, name, serverURL, encryption, publicKey, color }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        serverURL = try c.decode(String.self, forKey: .serverURL)
        token = ""
        encryption = try c.decodeIfPresent(EncryptionProtocol.self, forKey: .encryption) ?? .none
        publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "teal"
    }
    public func normalizedURL() throws -> URL { try Self.normalize(serverURL) }
    public static func normalize(_ raw: String) throws -> URL {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: raw), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
            let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
            c.query == nil, c.fragment == nil
        else { throw TodexError.invalid("请输入有效的 HTTP 或 HTTPS 后端地址") }
        if c.path.hasPrefix("/v1") { throw TodexError.invalid("/v1 协议已移除，请使用后端根地址") }
        guard ["", "/", "/v2", "/v2/"].contains(c.path) else { throw TodexError.invalid("请填写后端根地址，不包含接口路径") }
        c.path = ""
        c.host = host.lowercased()
        c.scheme = c.scheme?.lowercased()
        guard let result = c.url else { throw TodexError.invalid("后端地址无效") }
        return result
    }
}

public enum TodexError: Error, LocalizedError, Sendable {
    case invalid(String)
    case server(code: String, message: String)
    case disconnected
    case unknownOutcome(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s): s
        case .server(_, let message): message
        case .disconnected: "连接已断开，请重新连接后端"
        case .unknownOutcome(let s): "操作结果未知：\(s)。请先核对记录，避免重复执行。"
        }
    }
}
