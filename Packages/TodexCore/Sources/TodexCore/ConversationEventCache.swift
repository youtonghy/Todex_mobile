import Foundation

/// The device's offline journal cache: per conversation, a contiguous prefix
/// from sequence 1 of events exactly as the backend sent them. Under history
/// encryption that is ciphertext; callers decrypt after loading, so no
/// readable history is written to disk. Sealed-segment events keep the
/// `frames` they reference beside them.
///
/// Neither arrival order nor the sequence cap may turn a tail into a
/// seemingly complete offline journal: once an event does not fit (bytes,
/// or a referenced frame is missing) the conversation stops growing.
public struct ConversationEventCache: Sendable {
    public static let maximumSequence = 10_000
    public static let maximumConversations = 32
    public static let maximumPending = 256
    public let journalByteLimit: Int
    public let totalByteLimit: Int
    public private(set) var totalBytes = 0

    private struct Journal: Sendable {
        var events: [ConversationEvent] = []
        var frames: [String: JSONValue] = [:]
        var pending: [Int: ConversationEvent] = [:]
        var pendingFrames: [String: JSONValue] = [:]
        var bytes = 0
        var saturated = false
    }
    private var journals: [String: Journal] = [:]

    public init(journalByteLimit: Int = 8 * 1_024 * 1_024, totalByteLimit: Int = 32 * 1_024 * 1_024) {
        self.journalByteLimit = journalByteLimit
        self.totalByteLimit = totalByteLimit
    }

    /// Offers one received event; `frames` is its page's `frames` map.
    /// Returns true when the stored prefix grew and should be persisted.
    @discardableResult
    public mutating func record(_ event: ConversationEvent, frames: JSONValue = .null) -> Bool {
        let id = event.conversationId
        guard event.sequence > 0, event.sequence <= Self.maximumSequence,
            journals[id] != nil || journals.count < Self.maximumConversations
        else { return false }
        var journal = journals[id] ?? Journal()
        guard !journal.saturated, event.sequence > journal.events.count, journal.pending[event.sequence] == nil
        else { return false }
        guard event.sequence == journal.events.count + 1 || journal.pending.count < Self.maximumPending else {
            return false
        }
        var newFrames: [String: JSONValue] = [:]
        var complete = true
        for frameID in HistoryEncryption.Envelope.frameIDs(event.payload)
        where journal.frames[frameID] == nil && journal.pendingFrames[frameID] == nil {
            // Without its frame a cached event could never decrypt again, and
            // the prefix would hide it from the network replay.
            guard let frame = frames.objectValue[frameID] else {
                complete = false
                break
            }
            newFrames[frameID] = frame
        }
        let bytes = Self.cost(event) + newFrames.values.reduce(0) { $0 + Self.cost($1) }
        guard complete, bytes <= journalByteLimit - journal.bytes, bytes <= totalByteLimit - totalBytes else {
            journal.saturated = true
            let refund =
                journal.pending.values.reduce(0) { $0 + Self.cost($1) }
                + journal.pendingFrames.values.reduce(0) { $0 + Self.cost($1) }
            journal.bytes -= refund
            totalBytes -= refund
            journal.pending.removeAll()
            journal.pendingFrames.removeAll()
            journals[id] = journal
            return false
        }
        journal.pending[event.sequence] = event
        journal.pendingFrames.merge(newFrames) { old, _ in old }
        journal.bytes += bytes
        totalBytes += bytes
        var grew = false
        while let next = journal.pending.removeValue(forKey: journal.events.count + 1) {
            journal.events.append(next)
            for frameID in HistoryEncryption.Envelope.frameIDs(next.payload) {
                if let frame = journal.pendingFrames.removeValue(forKey: frameID) { journal.frames[frameID] = frame }
            }
            grew = true
        }
        journals[id] = journal
        return grew
    }

    /// The stored prefix and the frames it references.
    public func stored(_ id: String) -> CachedHistory? {
        journals[id].map { CachedHistory(events: $0.events, frames: $0.frames) }
    }

    public mutating func remove(_ id: String) {
        if let old = journals.removeValue(forKey: id) { totalBytes -= old.bytes }
    }

    public mutating func removeAll() {
        journals.removeAll()
        totalBytes = 0
    }

    /// Bytes the JSON encoding of `event` occupies, computed without encoding
    /// (escaped characters count their escape sequence).
    public static func cost(_ event: ConversationEvent) -> Int {
        64
            + [
                event.eventId, event.conversationId, event.type, event.time, event.provider ?? "",
                event.normalizedType ?? "", event.rawType ?? "",
            ].reduce(0) { $0 + cost(string: $1) + 16 }
            + cost(event.payload)
    }

    static func cost(_ value: JSONValue) -> Int {
        switch value {
        case .string(let string): return cost(string: string)
        case .array(let values): return values.reduce(2) { $0 + cost($1) + 1 }
        case .object(let values): return values.reduce(2) { $0 + cost(string: $1.key) + 1 + cost($1.value) + 1 }
        default: return 24
        }
    }

    private static func cost(string: String) -> Int {
        var bytes = 2
        for byte in string.utf8 {
            // JSONEncoder escapes quotes, backslashes, slashes and controls.
            bytes += byte < 0x20 ? 6 : (byte == 0x22 || byte == 0x5C || byte == 0x2F) ? 2 : 1
        }
        return bytes
    }
}

/// The on-disk cache file. Older builds stored a bare event array.
public struct CachedHistory: Codable, Sendable, Equatable {
    public var events: [ConversationEvent]
    public var frames: [String: JSONValue]

    public init(events: [ConversationEvent] = [], frames: [String: JSONValue] = [:]) {
        self.events = events
        self.frames = frames
    }

    private enum CodingKeys: String, CodingKey { case events, frames }

    public init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode([ConversationEvent].self) {
            self.init(events: legacy)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            events: try c.decode([ConversationEvent].self, forKey: .events),
            frames: try c.decodeIfPresent([String: JSONValue].self, forKey: .frames) ?? [:])
    }
}
