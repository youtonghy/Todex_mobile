import Compression
import Foundation

/// Wire models for end-to-end encrypted conversation history (history v3,
/// `TodeX_backend/docs/history-encryption.md`). Binary fields travel as
/// base64url without padding, like `HistoryCrypto.WrappedKey`.
public enum HistoryEncryption {
    /// Declared on subscribe, session resume and history pages (§5.4). An
    /// `e2e` backend rejects clients that omit it with `CLIENT_UPGRADE_REQUIRED`.
    public static let protocolVersion = 1
    public static let capabilityField = "historyEncryption"
    /// Marks a payload whose content could not be decrypted on this device.
    public static let lockedField = "detailLocked"
    public static let clientUpgradeRequired = "CLIENT_UPGRADE_REQUIRED"
    public static let storageLow = "STORAGE_LOW"
    /// `history.keys.list`, `history.keys.wraps` and `history.grant.fulfill` batch limit.
    public static let batchLimit = 500

    /// The wire text of a binary id (rid, kid): base64url without padding.
    public static func encodeID(_ data: Data) -> String { CryptoEncoding.encode(data) }

    /// Upper bound for one inflated sealed-segment frame (frames hold about
    /// 1 MiB of payloads); a larger output is rejected, not truncated.
    public static let maximumFrameBytes = 64 * 1_024 * 1_024

    /// Sealed-segment frame plaintext is raw DEFLATE (RFC 1951, no zlib
    /// header) of the JSON payload array; Compression's ZLIB is raw deflate.
    public static func inflate(_ data: Data, limit: Int = maximumFrameBytes) throws -> Data {
        let failure = TodexError.invalid(String(localized: "历史加密帧格式不受支持", bundle: .module))
        guard !data.isEmpty else { throw failure }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { throw failure }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        return try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.pointee.src_ptr = input.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                guard output.count + produced <= limit else { throw failure }
                output.append(buffer, count: produced)
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK:
                    // No progress with input exhausted: the stream is truncated.
                    if produced == 0 && stream.pointee.src_size == 0 { throw failure }
                default: throw failure
                }
            }
        }
    }

    /// Whether the payload still carries ciphertext (`$enc`).
    public static func isEncrypted(_ payload: JSONValue) -> Bool { payload.objectValue[Envelope.field] != nil }

    /// Whether decryption failed and only the plaintext envelope fields remain.
    public static func isLocked(_ payload: JSONValue) -> Bool { payload[lockedField] == .bool(true) }

    /// The placeholder for content this device cannot read: the plaintext
    /// envelope fields plus `detailLocked: true` (§5.3).
    public static func lockedPayload(_ payload: JSONValue) -> JSONValue {
        var fields = payload.objectValue
        fields.removeValue(forKey: Envelope.field)
        fields[lockedField] = .bool(true)
        return .object(fields)
    }

    /// `payload["$enc"]`: where one event's content ciphertext lives.
    public struct Envelope: Sendable, Equatable {
        public static let field = "$enc"
        /// Frame ids into the page's `frames` map and the payload index inside them.
        public struct FrameReference: Sendable, Equatable {
            public var summary: String?
            public var full: String?
            public var index: Int
        }
        public var version: Int
        public var kid: Data
        /// The AAD conversation id and sequence. Forks copy ciphertext and keep
        /// the source values, so they can differ from the event's own.
        public var conversationId: String
        public var sequence: UInt64
        public var summary: Data?
        public var full: Data?
        public var frame: FrameReference?

        public init(_ value: JSONValue) throws {
            guard case .object = value, let version = Int(exactly: value["v"].doubleValue ?? -1), version == 1 else {
                throw TodexError.invalid(String(localized: "不支持的历史加密格式", bundle: .module))
            }
            self.version = version
            kid = try CryptoEncoding.decode(value["kid"].stringValue, count: HistoryCrypto.kidLength)
            conversationId = value["c"].stringValue
            guard !conversationId.isEmpty, let sequence = HistoryEncryption.unsigned(value["n"]) else {
                throw TodexError.invalid(String(localized: "历史加密信封无效", bundle: .module))
            }
            self.sequence = sequence
            summary = try value["s"].optionalString.map { try CryptoEncoding.decode($0) }
            full = try value["f"].optionalString.map { try CryptoEncoding.decode($0) }
            if case .object = value["fr"] {
                let reference = value["fr"]
                guard let index = HistoryEncryption.unsigned(reference["i"]), index <= UInt64(Int.max) else {
                    throw TodexError.invalid(String(localized: "历史加密信封无效", bundle: .module))
                }
                frame = FrameReference(
                    summary: reference["s"].optionalString, full: reference["f"].optionalString, index: Int(index))
            }
            guard summary != nil || full != nil || frame?.summary != nil || frame?.full != nil else {
                throw TodexError.invalid(String(localized: "历史加密信封无效", bundle: .module))
            }
        }

        /// Frame ids an event references; a cache keeps these frames beside it.
        public static func frameIDs(_ payload: JSONValue) -> [String] {
            let reference = payload[field]["fr"]
            return [reference["s"].optionalString, reference["f"].optionalString].compactMap { $0 }
        }
    }

    /// One entry of a page's top-level `frames` map: a sealed-segment frame
    /// whose plaintext is a JSON array of payloads.
    public struct Frame: Sendable, Equatable {
        public var kid: Data
        public var stream: HistoryCrypto.ContentStream
        public var counter: UInt64
        public var conversationId: String
        public var ciphertext: Data

        public init(_ value: JSONValue) throws {
            guard case .object = value,
                let rawStream = HistoryEncryption.unsigned(value["stream"]),
                let stream = HistoryCrypto.ContentStream(rawValue: UInt32(clamping: rawStream)),
                stream == .frameSummary || stream == .frameFull,
                let counter = HistoryEncryption.unsigned(value["counter"]),
                !value["c"].stringValue.isEmpty
            else { throw TodexError.invalid(String(localized: "历史加密帧无效", bundle: .module)) }
            kid = try CryptoEncoding.decode(value["kid"].stringValue, count: HistoryCrypto.kidLength)
            self.stream = stream
            self.counter = counter
            conversationId = value["c"].stringValue
            ciphertext = try CryptoEncoding.decode(value["ct"].stringValue)
        }
    }

    /// A non-negative integral JSON number (sequences, counters, indexes).
    static func unsigned(_ value: JSONValue) -> UInt64? {
        guard let number = value.doubleValue, number.isFinite, number >= 0, number <= 9_007_199_254_740_991,
            number.rounded(.towardZero) == number
        else { return nil }
        return UInt64(number)
    }
}

/// One public key the backend wraps history keys for (`recipients.json`).
public struct HistoryRecipient: Codable, Sendable, Equatable, Identifiable {
    public var rid: String
    /// `device` or `recovery`.
    public var kind: String
    public var deviceId: String?
    public var publicKey: String
    public var addedAt: String?
    public var revokedAt: String?
    public var id: String { rid }
    public var isRevoked: Bool { !(revokedAt ?? "").isEmpty }
    public var isRecovery: Bool { kind == "recovery" }

    public init(
        rid: String, kind: String, deviceId: String? = nil, publicKey: String, addedAt: String? = nil,
        revokedAt: String? = nil
    ) {
        self.rid = rid
        self.kind = kind
        self.deviceId = deviceId
        self.publicKey = publicKey
        self.addedAt = addedAt
        self.revokedAt = revokedAt
    }

    private enum CodingKeys: String, CodingKey { case rid, kind, deviceId, publicKey, addedAt, revokedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rid = try c.decode(String.self, forKey: .rid)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "device"
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt)
        revokedAt = try c.decodeIfPresent(String.self, forKey: .revokedAt)
    }

    /// The validated raw X-Wing public key, checked against `rid` so a mixed-up
    /// directory entry cannot redirect a grant to another key.
    public func verifiedPublicKey() throws -> Data {
        let key = try CryptoEncoding.decode(publicKey, count: HistoryCrypto.publicKeyLength)
        guard try CryptoEncoding.encode(HistoryCrypto.recipientID(publicKey: key)) == rid else {
            throw TodexError.invalid(String(localized: "接收方公钥与标识不一致", bundle: .module))
        }
        return key
    }
}

/// A device's request to read history from before it was registered.
public struct HistoryGrantRequest: Codable, Sendable, Equatable, Identifiable {
    public var grantId: String
    public var rid: String
    public var deviceId: String?
    public var requestedAt: String?
    /// `pending`, `fulfilled`, `dismissed` or `revoked`.
    public var status: String
    /// The requesting recipient's public key, when the backend lists it.
    public var publicKey: String?
    public var id: String { grantId }
    public var isPending: Bool { status == "pending" }

    public init(
        grantId: String, rid: String, deviceId: String? = nil, requestedAt: String? = nil, status: String = "pending",
        publicKey: String? = nil
    ) {
        self.grantId = grantId
        self.rid = rid
        self.deviceId = deviceId
        self.requestedAt = requestedAt
        self.status = status
        self.publicKey = publicKey
    }

    /// The target as a recipient, for `HistoryGrant.fulfill`.
    public var recipient: HistoryRecipient? {
        publicKey.map { HistoryRecipient(rid: rid, kind: "device", deviceId: deviceId, publicKey: $0) }
    }

    private enum CodingKeys: String, CodingKey { case grantId, rid, deviceId, requestedAt, status, publicKey }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grantId = try c.decode(String.self, forKey: .grantId)
        rid = try c.decode(String.self, forKey: .rid)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        requestedAt = try c.decodeIfPresent(String.self, forKey: .requestedAt)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey)
    }
}

/// `history.encryption.get|enable|disable` and `history.recipient.revoke`.
public struct HistoryEncryptionState: Codable, Sendable, Equatable {
    /// `off` or `e2e`.
    public var mode: String
    public var epoch: Int
    public var recipients: [HistoryRecipient]
    /// This device's recipient id when it has registered.
    public var myRid: String?
    public var grants: [HistoryGrantRequest]
    public var isEnabled: Bool { mode == "e2e" }
    public var activeRecovery: HistoryRecipient? { recipients.first { $0.isRecovery && !$0.isRevoked } }

    public init(
        mode: String = "off", epoch: Int = 0, recipients: [HistoryRecipient] = [], myRid: String? = nil,
        grants: [HistoryGrantRequest] = []
    ) {
        self.mode = mode
        self.epoch = epoch
        self.recipients = recipients
        self.myRid = myRid
        self.grants = grants
    }

    private enum CodingKeys: String, CodingKey { case mode, epoch, recipients, myRid, grants }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(String.self, forKey: .mode)
        epoch = try c.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        recipients = try c.decodeIfPresent([HistoryRecipient].self, forKey: .recipients) ?? []
        myRid = try c.decodeIfPresent(String.self, forKey: .myRid)
        grants = try c.decodeIfPresent([HistoryGrantRequest].self, forKey: .grants) ?? []
    }
}

/// One `history.keys.list` page: every key id of the caller's conversations.
public struct HistoryKeyPage: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var conversationId: String
        public var kid: String
        public init(conversationId: String, kid: String) {
            self.conversationId = conversationId
            self.kid = kid
        }
    }
    public var items: [Item]
    public var nextCursor: String?
    public init(items: [Item], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// A re-wrapped key uploaded with `history.grant.fulfill`.
public struct HistoryGrantWrap: Codable, Sendable, Equatable {
    public var conversationId: String
    public var kid: String
    public var wrapped: HistoryCrypto.WrappedKey
    public init(conversationId: String, kid: String, wrapped: HistoryCrypto.WrappedKey) {
        self.conversationId = conversationId
        self.kid = kid
        self.wrapped = wrapped
    }
}

/// Typed §7 commands over the v2 WebSocket command channel. `send` is
/// `RealtimeClient.command` (or the app session's wrapper of it).
public struct HistoryAPI: Sendable {
    public typealias Send = @Sendable (_ type: String, _ payload: JSONValue) async throws -> JSONValue
    private let send: Send

    public init(send: @escaping Send) { self.send = send }

    public init(client: RealtimeClient) {
        self.init { type, payload in try await client.command(type: type, payload: payload) }
    }

    private func call(_ command: ProtocolCatalog.Command, _ payload: JSONValue = [:]) async throws -> JSONValue {
        try await send(command.rawValue, payload)
    }

    private func state(_ command: ProtocolCatalog.Command, _ payload: JSONValue = [:]) async throws
        -> HistoryEncryptionState
    {
        try Self.decode(try await call(command, payload), as: HistoryEncryptionState.self)
    }

    public func state() async throws -> HistoryEncryptionState { try await state(.historyEncryptionGet) }
    public func enable() async throws -> HistoryEncryptionState { try await state(.historyEncryptionEnable) }
    public func disable() async throws -> HistoryEncryptionState { try await state(.historyEncryptionDisable) }
    public func revoke(rid: String) async throws -> HistoryEncryptionState {
        try await state(.historyRecipientRevoke, ["rid": .string(rid)])
    }

    /// Registers this device's public key; idempotent, a new key replaces the old.
    public func register(publicKey: Data) async throws -> String {
        try Self.string(try await call(.historyRecipientRegister, ["publicKey": .string(CryptoEncoding.encode(publicKey))]), "rid")
    }

    public func setRecovery(publicKey: Data) async throws -> String {
        try Self.string(try await call(.historyRecoverySet, ["publicKey": .string(CryptoEncoding.encode(publicKey))]), "rid")
    }

    public func requestGrant() async throws -> String {
        try Self.string(try await call(.historyGrantRequest), "grantId")
    }

    public func grants() async throws -> [HistoryGrantRequest] {
        try Self.decode(try await call(.historyGrantList)["grants"], as: [HistoryGrantRequest].self)
    }

    public func dismissGrant(_ grantId: String) async throws {
        _ = try await call(.historyGrantDismiss, ["grantId": .string(grantId)])
    }

    public func keys(conversationId: String? = nil, cursor: String? = nil, limit: Int = HistoryEncryption.batchLimit)
        async throws -> HistoryKeyPage
    {
        var payload: JSONValue = ["limit": .number(Double(min(max(1, limit), HistoryEncryption.batchLimit)))]
        if let conversationId { payload["conversationId"] = .string(conversationId) }
        if let cursor { payload["cursor"] = .string(cursor) }
        return try Self.decode(try await call(.historyKeysList, payload), as: HistoryKeyPage.self)
    }

    /// The caller's (or `rid`'s) wrapped keys by kid. Entries that fail to
    /// decode are omitted; their content stays locked.
    public func wraps(conversationId: String, kids: [Data], rid: Data? = nil) async throws
        -> [Data: HistoryCrypto.WrappedKey]
    {
        guard !kids.isEmpty else { return [:] }
        guard kids.count <= HistoryEncryption.batchLimit else {
            throw TodexError.invalid(String(localized: "单次最多请求 500 个历史密钥", bundle: .module))
        }
        var payload: JSONValue = [
            "conversationId": .string(conversationId), "kids": .array(kids.map { .string(CryptoEncoding.encode($0)) }),
        ]
        if let rid { payload["rid"] = .string(CryptoEncoding.encode(rid)) }
        let result = try await call(.historyKeysWraps, payload)
        guard case .object(let entries) = result["wraps"] else {
            throw TodexError.invalid(String(localized: "后端未返回历史密钥列表", bundle: .module))
        }
        var wraps: [Data: HistoryCrypto.WrappedKey] = [:]
        for (kid, value) in entries {
            guard let kid = try? CryptoEncoding.decode(kid, count: HistoryCrypto.kidLength),
                let wrapped = try? value.decoded(HistoryCrypto.WrappedKey.self)
            else { continue }
            wraps[kid] = wrapped
        }
        return wraps
    }

    /// Uploads at most 500 re-wrapped keys; returns how many were new.
    /// `complete` on the last batch marks the grant fulfilled.
    public func fulfill(grantId: String?, rid: String, wraps: [HistoryGrantWrap], complete: Bool = false)
        async throws -> Int
    {
        guard wraps.count <= HistoryEncryption.batchLimit else {
            throw TodexError.invalid(String(localized: "单次最多上传 500 个历史密钥", bundle: .module))
        }
        var payload: JSONValue = ["rid": .string(rid), "wraps": try JSONValue(encoding: wraps)]
        if let grantId { payload["grantId"] = .string(grantId) }
        if complete { payload["complete"] = true }
        return try await call(.historyGrantFulfill, payload)["added"].intValue
    }

    private static func decode<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
        do { return try value.decoded(type) } catch {
            throw TodexError.invalid(String(localized: "后端历史加密响应无效，请检查后端版本", bundle: .module))
        }
    }

    private static func string(_ value: JSONValue, _ key: String) throws -> String {
        guard let text = value[key].optionalString, !text.isEmpty else {
            throw TodexError.invalid(String(localized: "后端历史加密响应无效，请检查后端版本", bundle: .module))
        }
        return text
    }
}
