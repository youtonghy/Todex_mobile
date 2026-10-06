import CryptoKit
import Foundation

/// Decrypts end-to-end encrypted history payloads (`$enc`, §5.3) before they
/// reach `ConversationRuntime`. Events are never dropped or reordered: content
/// this device cannot read becomes the plaintext envelope fields plus
/// `detailLocked: true`, and its sequence still advances.
///
/// Segment keys (DEKs) are fetched lazily as wrapped keys for this device's
/// recipient id — or, while one is imported, the recovery key's — unwrapped
/// with the X-Wing private key, and kept in a bounded LRU cache. Keys the
/// backend has no wrap for are not asked for again until `retryInterval`
/// passes or `forgetUnavailable()` runs (for example after a grant arrives).
public actor HistoryDecryptor {
    /// Wrapped keys for `kids` addressed to `rid`, read from `conversationId`'s
    /// keyring (`history.keys.wraps`). Missing kids are simply absent.
    public typealias FetchWraps = @Sendable (_ conversationId: String, _ kids: [Data], _ rid: Data) async throws
        -> [Data: HistoryCrypto.WrappedKey]

    private struct Recipient: Sendable {
        let key: XWingMLKEM768X25519.PrivateKey
        let rid: Data
        init(seed: Data) throws {
            key = try HistoryCrypto.recipientKey(seed: seed)
            rid = try HistoryCrypto.recipientID(publicKey: key.publicKey.rawRepresentation)
        }
    }

    public nonisolated let deviceRecipientID: Data
    public nonisolated let devicePublicKey: Data
    private let device: Recipient
    private var recovery: Recipient?
    private let fetchWraps: FetchWraps
    private let capacity: Int
    private let retryInterval: Duration
    private let clock = ContinuousClock()
    private var keys: [Data: (key: HistoryCrypto.SegmentKey, used: UInt64)] = [:]
    private var useCounter: UInt64 = 0
    private var unavailable: [Data: ContinuousClock.Instant] = [:]
    private var inflight: [Data: Task<Void, any Error>] = [:]
    private static let unavailableLimit = 4_096

    public init(
        deviceSeed: Data, recoverySeed: Data? = nil, cacheCapacity: Int = 256, retryInterval: Duration = .seconds(60),
        fetchWraps: @escaping FetchWraps
    ) throws {
        device = try Recipient(seed: deviceSeed)
        recovery = try recoverySeed.map { try Recipient(seed: $0) }
        deviceRecipientID = device.rid
        devicePublicKey = device.key.publicKey.rawRepresentation
        capacity = max(1, cacheCapacity)
        self.retryInterval = retryInterval
        self.fetchWraps = fetchWraps
    }

    /// Imports (or with nil, forgets) a recovery key; its wraps are tried for
    /// keys this device has none for. The seed lives only in memory.
    public func setRecoverySeed(_ seed: Data?) throws {
        recovery = try seed.map { try Recipient(seed: $0) }
        unavailable.removeAll()
    }

    /// Retry every key that was unavailable, e.g. after a grant was fulfilled.
    public func forgetUnavailable() { unavailable.removeAll() }

    public var cachedKeyCount: Int { keys.count }

    /// Decrypts every `$enc` payload in order. `frames` is the page's or
    /// replay message's top-level `frames` map. Throws only for transport
    /// failures while fetching keys (the caller retries the page); a missing
    /// key, a failed authentication or a malformed envelope locks that event.
    public func decrypt(_ events: [ConversationEvent], frames: JSONValue = .null) async throws -> [ConversationEvent] {
        guard events.contains(where: { HistoryEncryption.isEncrypted($0.payload) }) else { return events }
        var parsedFrames: [String: HistoryEncryption.Frame?] = [:]
        func frame(_ id: String?) -> HistoryEncryption.Frame? {
            guard let id else { return nil }
            if let parsed = parsedFrames[id] { return parsed }
            let parsed = frames.objectValue[id].flatMap { try? HistoryEncryption.Frame($0) }
            parsedFrames[id] = parsed
            return parsed
        }
        // Gather the keys each conversation's events need, then fetch them in batches.
        var needed: [String: [Data]] = [:]
        var envelopes: [Int: HistoryEncryption.Envelope] = [:]
        for (index, event) in events.enumerated() {
            guard let raw = event.payload.objectValue[HistoryEncryption.Envelope.field],
                let envelope = try? HistoryEncryption.Envelope(raw)
            else { continue }
            envelopes[index] = envelope
            var kids = [envelope.kid]
            if let reference = envelope.frame {
                kids += [frame(reference.full), frame(reference.summary)].compactMap { $0?.kid }
            }
            needed[event.conversationId, default: []] += kids
        }
        for (conversationId, kids) in needed.sorted(by: { $0.key < $1.key }) {
            try await resolve(Array(Set(kids)), conversationId: conversationId)
        }
        var openedFrames: [String: [JSONValue]] = [:]
        func payloads(_ id: String) -> [JSONValue]? {
            if let opened = openedFrames[id] { return opened }
            guard let frame = frame(id), let key = cached(frame.kid),
                let plaintext = try? HistoryCrypto.open(
                    frame.ciphertext, key: key, conversationID: frame.conversationId, stream: frame.stream,
                    counter: frame.counter),
                let inflated = try? HistoryEncryption.inflate(plaintext),
                case .array(let values)? = try? Self.json(inflated)
            else { return nil }
            openedFrames[id] = values
            return values
        }
        return events.enumerated().map { index, event in
            guard HistoryEncryption.isEncrypted(event.payload) else { return event }
            var output = event
            output.payload = envelopes[index].flatMap { envelope in
                open(envelope, event: event, frame: payloads)
            } ?? HistoryEncryption.lockedPayload(event.payload)
            return output
        }
    }

    public func decrypt(_ event: ConversationEvent, frames: JSONValue = .null) async throws -> ConversationEvent {
        try await decrypt([event], frames: frames)[0]
    }

    /// `manifest.titleEnc = {kid, ct}`: stream 2, counter 0, UTF-8 title. Nil
    /// when the key is unavailable or the ciphertext does not authenticate.
    public func decryptTitle(_ titleEnc: JSONValue, conversationId: String) async throws -> String? {
        guard let kid = try? CryptoEncoding.decode(titleEnc["kid"].stringValue, count: HistoryCrypto.kidLength),
            let ciphertext = try? CryptoEncoding.decode(titleEnc["ct"].stringValue)
        else { return nil }
        try await resolve([kid], conversationId: conversationId)
        guard let key = cached(kid),
            let plaintext = try? HistoryCrypto.open(
                ciphertext, key: key, conversationID: conversationId, stream: .eventFull, counter: 0)
        else { return nil }
        return String(data: plaintext, encoding: .utf8)
    }

    /// One plaintext event: event-level `s`/`f` (stream 1/2, counter = AAD
    /// sequence) or a frame-level `fr` entry. Full content wins over summary.
    private func open(
        _ envelope: HistoryEncryption.Envelope, event: ConversationEvent, frame payloads: (String) -> [JSONValue]?
    ) -> JSONValue? {
        // Within one conversation the AAD sequence must be the event's own, or
        // the backend could replay one ciphertext at another position. Forked
        // copies name their source conversation and keep its sequences.
        if envelope.conversationId == event.conversationId, envelope.sequence != UInt64(clamping: event.sequence) {
            return nil
        }
        var payload: JSONValue?
        if let key = cached(envelope.kid) {
            for (ciphertext, stream) in [(envelope.full, HistoryCrypto.ContentStream.eventFull), (envelope.summary, .eventSummary)] {
                guard let ciphertext,
                    let plaintext = try? HistoryCrypto.open(
                        ciphertext, key: key, conversationID: envelope.conversationId, stream: stream,
                        counter: envelope.sequence),
                    let value = try? Self.json(plaintext)
                else { continue }
                payload = value
                break
            }
        }
        if payload == nil, let reference = envelope.frame {
            for id in [reference.full, reference.summary].compactMap({ $0 }) {
                guard let values = payloads(id), values.indices.contains(reference.index) else { continue }
                payload = values[reference.index]
                break
            }
        }
        guard case .object? = payload else { return nil }
        return payload
    }

    private static func json(_ plaintext: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: plaintext)
    }

    private func cached(_ kid: Data) -> HistoryCrypto.SegmentKey? {
        guard let entry = keys[kid] else { return nil }
        useCounter &+= 1
        keys[kid] = (entry.key, useCounter)
        return entry.key
    }

    private func store(_ key: HistoryCrypto.SegmentKey) {
        useCounter &+= 1
        keys[key.kid] = (key, useCounter)
        unavailable.removeValue(forKey: key.kid)
        while keys.count > capacity, let oldest = keys.min(by: { $0.value.used < $1.value.used })?.key {
            keys.removeValue(forKey: oldest)
        }
    }

    private func markUnavailable(_ kids: some Sequence<Data>) {
        let now = clock.now
        if unavailable.count >= Self.unavailableLimit {
            unavailable = unavailable.filter { now - $0.value < retryInterval }
            if unavailable.count >= Self.unavailableLimit { unavailable.removeAll() }
        }
        for kid in kids where keys[kid] == nil { unavailable[kid] = now }
    }

    /// Ensures each kid is cached or marked unavailable. Concurrent callers
    /// share an in-flight fetch for the same kid.
    private func resolve(_ kids: [Data], conversationId: String) async throws {
        let now = clock.now
        var waiting: [Task<Void, any Error>] = []
        var missing: [Data] = []
        for kid in kids where keys[kid] == nil {
            if let since = unavailable[kid], now - since < retryInterval { continue }
            if let task = inflight[kid] { waiting.append(task) } else { missing.append(kid) }
        }
        for start in stride(from: 0, to: missing.count, by: HistoryEncryption.batchLimit) {
            let batch = Array(missing[start..<min(start + HistoryEncryption.batchLimit, missing.count)])
            let task = Task { try await self.fetch(batch, conversationId: conversationId) }
            for kid in batch { inflight[kid] = task }
            waiting.append(task)
        }
        for task in waiting { try await task.value }
    }

    private func fetch(_ kids: [Data], conversationId: String) async throws {
        defer { for kid in kids { inflight.removeValue(forKey: kid) } }
        var remaining = Set(kids)
        for recipient in [device, recovery].compactMap({ $0 }) where !remaining.isEmpty {
            let wraps: [Data: HistoryCrypto.WrappedKey]
            do {
                wraps = try await fetchWraps(conversationId, Array(remaining), recipient.rid)
            } catch TodexError.server {
                // The backend refused this lookup (unknown kid, not authorized):
                // the content stays locked rather than failing the whole page.
                continue
            }
            for (kid, wrapped) in wraps where remaining.contains(kid) {
                guard let key = try? HistoryCrypto.unwrap(wrapped, kid: kid, with: recipient.key) else { continue }
                store(key)
                remaining.remove(kid)
            }
        }
        markUnavailable(remaining)
    }
}
