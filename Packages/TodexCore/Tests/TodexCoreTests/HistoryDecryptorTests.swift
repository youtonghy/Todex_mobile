import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import TodexCore

/// Builds the ciphertext a history-v3 backend would send, with the real
/// primitives (the backend wiring does not exist yet).
struct HistoryBackendFixture: Sendable {
    let device: XWingMLKEM768X25519.PrivateKey
    let deviceSeed: Data
    let key: HistoryCrypto.SegmentKey

    init() throws {
        device = try HistoryCrypto.generateRecipientKey()
        deviceSeed = device.seedRepresentation
        key = .generate()
    }

    var devicePublicKey: Data { device.publicKey.rawRepresentation }
    var kidText: String { CryptoEncoding.encode(key.kid) }

    static func payload(_ text: String, turn: String = "t1", role: String = "assistant") -> JSONValue {
        ["turnId": .string(turn), "role": .string(role), "block": ["category": "assistant_final", "id": "b1", "phase": "delta"], "delta": ["text": .string(text)], "text": .string(text)]
    }

    static func envelopeFields(_ payload: JSONValue) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for key in ["turnId", "role"] { fields[key] = payload.objectValue[key] }
        return .object(fields)
    }

    /// Event-level ciphertext: `f` (stream 2) and optionally `s` (stream 1).
    func event(
        _ sequence: Int, conversation: String = "c", type: String = "message.delta", payload: JSONValue,
        summary: JSONValue? = nil, includeFull: Bool = true, aadConversation: String? = nil, aadSequence: Int? = nil,
        key: HistoryCrypto.SegmentKey? = nil
    ) throws -> ConversationEvent {
        let key = key ?? self.key
        let aadConversation = aadConversation ?? conversation
        let counter = UInt64(aadSequence ?? sequence)
        var enc: JSONValue = [
            "v": 1, "kid": .string(CryptoEncoding.encode(key.kid)), "c": .string(aadConversation),
            "n": .number(Double(counter)),
            "f": .string(
                CryptoEncoding.encode(
                    try HistoryCrypto.seal(
                        JSONEncoder().encode(payload), key: key, conversationID: aadConversation, stream: .eventFull,
                        counter: counter))),
        ]
        if !includeFull { enc["f"] = nil }
        if let summary {
            enc["s"] = .string(
                CryptoEncoding.encode(
                    try HistoryCrypto.seal(
                        JSONEncoder().encode(summary), key: key, conversationID: aadConversation, stream: .eventSummary,
                        counter: counter)))
        }
        var wire = Self.envelopeFields(payload)
        wire[HistoryEncryption.Envelope.field] = enc
        return ConversationEvent(
            sequence: sequence, eventId: "evt_\(sequence)", conversationId: conversation, type: type, payload: wire)
    }

    /// A sealed-segment frame (stream 3/4) plus events referencing it by index.
    func frameEvents(
        _ payloads: [JSONValue], firstSequence: Int, conversation: String = "c", frameID: String = "fr1",
        stream: HistoryCrypto.ContentStream = .frameFull, counter: UInt64 = 0, plaintext: Data? = nil
    ) throws -> (events: [ConversationEvent], frames: JSONValue) {
        let sealed = try HistoryCrypto.seal(
            plaintext ?? JSONEncoder().encode(JSONValue.array(payloads)), key: key, conversationID: conversation,
            stream: stream, counter: counter)
        let frames: JSONValue = [
            frameID: [
                "kid": .string(kidText), "stream": .number(Double(stream.rawValue)), "counter": .number(Double(counter)),
                "c": .string(conversation), "ct": .string(CryptoEncoding.encode(sealed)),
            ]
        ]
        let events = payloads.enumerated().map { index, payload in
            var wire = Self.envelopeFields(payload)
            let reference: JSONValue =
                stream == .frameFull
                ? ["f": .string(frameID), "i": .number(Double(index))] : ["s": .string(frameID), "i": .number(Double(index))]
            wire[HistoryEncryption.Envelope.field] = [
                "v": 1, "kid": .string(kidText), "c": .string(conversation),
                "n": .number(Double(firstSequence + index)), "fr": reference,
            ]
            return ConversationEvent(
                sequence: firstSequence + index, eventId: "evt_\(firstSequence + index)", conversationId: conversation,
                type: "message.delta", payload: wire)
        }
        return (events, frames)
    }

    func wrap(for publicKey: Data) throws -> HistoryCrypto.WrappedKey { try HistoryCrypto.wrap(key, for: publicKey) }
}

/// Records `history.keys.wraps`-style lookups and answers from a fixed table.
final class WrapLookup: Sendable {
    private let state = Mutex<(calls: [(String, [Data], Data)], table: [Data: [Data: HistoryCrypto.WrappedKey]])>(([], [:]))
    let failure: TodexError?

    init(failure: TodexError? = nil) { self.failure = failure }

    func add(_ wrapped: HistoryCrypto.WrappedKey, kid: Data) { state.withLock { $0.table[wrapped.rid, default: [:]][kid] = wrapped } }
    var calls: [(String, [Data], Data)] { state.withLock { $0.calls } }

    var fetch: HistoryDecryptor.FetchWraps {
        { [self] conversation, kids, rid in
            state.withLock { $0.calls.append((conversation, kids, rid)) }
            if let failure { throw failure }
            let table = state.withLock { $0.table[rid] ?? [:] }
            return table.filter { kids.contains($0.key) }
        }
    }
}

struct HistoryDecryptorTests {
    @Test func eventLevelPayloadsDecryptInOrderAndPassPlainEventsThrough() async throws {
        let fixture = try HistoryBackendFixture()
        let lookup = WrapLookup()
        lookup.add(try fixture.wrap(for: fixture.devicePublicKey), kid: fixture.key.kid)
        let decryptor = try HistoryDecryptor(deviceSeed: fixture.deviceSeed, fetchWraps: lookup.fetch)
        let plain = ConversationEvent(sequence: 2, eventId: "evt_2", conversationId: "c", type: "turn.started", payload: ["turnId": "t1"])
        let first = HistoryBackendFixture.payload("hello")
        let summaryOnly = HistoryBackendFixture.payload("summary text")
        // `detail=summary` pages ship only `s`.
        let summaryEvent = try fixture.event(
            3, payload: HistoryBackendFixture.payload("full"), summary: summaryOnly, includeFull: false)
        let events = [try fixture.event(1, payload: first), plain, summaryEvent]
        let output = try await decryptor.decrypt(events)
        #expect(output.map(\.sequence) == [1, 2, 3])
        #expect(output[0].payload == first)
        #expect(output[1] == plain)
        #expect(output[2].payload == summaryOnly)
        #expect(output.allSatisfy { !HistoryEncryption.isEncrypted($0.payload) })
        #expect(lookup.calls.count == 1)
        #expect(lookup.calls.first?.2 == decryptor.deviceRecipientID)
        // Cached: a second page needs no lookup.
        _ = try await decryptor.decrypt([try fixture.event(4, payload: first)])
        #expect(lookup.calls.count == 1)
    }

    @Test func framePayloadsDecryptByIndexForBothFrameStreams() async throws {
        let fixture = try HistoryBackendFixture()
        let lookup = WrapLookup()
        lookup.add(try fixture.wrap(for: fixture.devicePublicKey), kid: fixture.key.kid)
        let decryptor = try HistoryDecryptor(deviceSeed: fixture.deviceSeed, fetchWraps: lookup.fetch)
        let payloads = (0..<3).map { HistoryBackendFixture.payload("frame \($0)") }
        let full = try fixture.frameEvents(payloads, firstSequence: 10, counter: 7)
        let output = try await decryptor.decrypt(full.events, frames: full.frames)
        #expect(output.map(\.payload) == payloads)
        let summary = try fixture.frameEvents(payloads, firstSequence: 20, frameID: "fs", stream: .frameSummary, counter: 2)
        #expect(try await decryptor.decrypt(summary.events, frames: summary.frames).map(\.payload) == payloads)
        // A frame that is not in the page, or an index past its end, locks only that event.
        var outOfRange = full.events[0]
        outOfRange.payload["$enc"]["fr"]["i"] = 9
        let missing = try await decryptor.decrypt([outOfRange, full.events[1]], frames: .null)
        #expect(missing.allSatisfy { HistoryEncryption.isLocked($0.payload) })
        let partly = try await decryptor.decrypt([outOfRange, full.events[1]], frames: full.frames)
        #expect(HistoryEncryption.isLocked(partly[0].payload))
        #expect(partly[1].payload == payloads[1])
    }

    @Test func undecryptableContentBecomesEnvelopeFieldsWithDetailLocked() async throws {
        let fixture = try HistoryBackendFixture()
        let lookup = WrapLookup()  // no wraps: grant not received yet
        let decryptor = try HistoryDecryptor(deviceSeed: fixture.deviceSeed, fetchWraps: lookup.fetch)
        let events = try (1...3).map { try fixture.event($0, payload: HistoryBackendFixture.payload("secret \($0)")) }
        let output = try await decryptor.decrypt(events)
        #expect(output.map(\.sequence) == [1, 2, 3])
        #expect(output.map(\.eventId) == events.map(\.eventId))
        for event in output {
            #expect(event.payload == ["turnId": "t1", "role": "assistant", "detailLocked": true])
        }
        #expect(lookup.calls.count == 1)
        // Unavailable keys are not asked for again until forgotten.
        _ = try await decryptor.decrypt(events)
        #expect(lookup.calls.count == 1)
        lookup.add(try fixture.wrap(for: fixture.devicePublicKey), kid: fixture.key.kid)
        await decryptor.forgetUnavailable()
        #expect(try await decryptor.decrypt(events)[0].payload == HistoryBackendFixture.payload("secret 1"))
        #expect(lookup.calls.count == 2)
    }

    @Test func wrongRecipientTamperingAndReplayLock() async throws {
        let fixture = try HistoryBackendFixture()
        let other = try HistoryCrypto.generateRecipientKey()
        let lookup = WrapLookup()
        // A wrap addressed to another device, served under this device's rid.
        let foreign = try fixture.wrap(for: other.publicKey.rawRepresentation)
        let misaddressed = try HistoryCrypto.WrappedKey(
            rid: try HistoryCrypto.recipientID(publicKey: fixture.devicePublicKey), kemCt: foreign.kemCt, wrapped: foreign.wrapped)
        lookup.add(misaddressed, kid: fixture.key.kid)
        let decryptor = try HistoryDecryptor(deviceSeed: fixture.deviceSeed, fetchWraps: lookup.fetch)
        let event = try fixture.event(1, payload: HistoryBackendFixture.payload("x"))
        #expect(HistoryEncryption.isLocked(try await decryptor.decrypt(event).payload))

        let good = WrapLookup()
        good.add(try fixture.wrap(for: fixture.devicePublicKey), kid: fixture.key.kid)
        let trusted = try HistoryDecryptor(deviceSeed: fixture.deviceSeed, fetchWraps: good.fetch)
        var tampered = event
        var ciphertext = try CryptoEncoding.decode(tampered.payload["$enc"]["f"].stringValue)
        ciphertext[ciphertext.startIndex] ^= 1
        tampered.payload["$enc"]["f"] = .string(CryptoEncoding.encode(ciphertext))
        // Ciphertext moved to another sequence of the same conversation.
        var replayed = try fixture.event(2, payload: HistoryBackendFixture.payload("y"))
        replayed.sequence = 5
        // A plaintext envelope field rewritten by the backend is replaced by the authenticated one.
        var rewritten = try fixture.event(3, payload: HistoryBackendFixture.payload("z"))
        rewritten.payload["role"] = "user"
        // Fork copies keep the source conversation and sequence in the AAD.
        let forked = try fixture.event(1, conversation: "fork", payload: HistoryBackendFixture.payload("f"), aadConversation: "c", aadSequence: 40)
        var badVersion = event
        badVersion.payload["$enc"]["v"] = 2
        let output = try await trusted.decrypt([tampered, replayed, rewritten, forked, badVersion])
        #expect(HistoryEncryption.isLocked(output[0].payload))
        #expect(HistoryEncryption.isLocked(output[1].payload))
        #expect(output[2].payload == HistoryBackendFixture.payload("z"))
        #expect(output[3].payload == HistoryBackendFixture.payload("f"))
        #expect(HistoryEncryption.isLocked(output[4].payload))
        #expect(output[4].payload.objectValue["$enc"] == nil)
    }

    @Test func keyCacheIsBoundedAndRecoveryWrapsAreUsed() async throws {
        let fixture = try HistoryBackendFixture()
        let recovery = HistoryRecoveryKey.generateSeed()
        let recoveryKey = try HistoryCrypto.recipientKey(seed: recovery)
        let lookup = WrapLookup()
        var events: [ConversationEvent] = []
        for index in 0..<4 {
            let key = HistoryCrypto.SegmentKey.generate()
            // Only the recovery recipient holds wraps for these keys.
            lookup.add(try HistoryCrypto.wrap(key, for: recoveryKey.publicKey.rawRepresentation), kid: key.kid)
            events.append(try fixture.event(index + 1, payload: HistoryBackendFixture.payload("k\(index)"), key: key))
        }
        let decryptor = try HistoryDecryptor(deviceSeed: fixture.deviceSeed, cacheCapacity: 2, fetchWraps: lookup.fetch)
        #expect(try await decryptor.decrypt(events).allSatisfy { HistoryEncryption.isLocked($0.payload) })
        try await decryptor.setRecoverySeed(recovery)
        let output = try await decryptor.decrypt(Array(events.prefix(2)))
        #expect(output.map(\.payload) == [HistoryBackendFixture.payload("k0"), HistoryBackendFixture.payload("k1")])
        _ = try await decryptor.decrypt(events)
        #expect(await decryptor.cachedKeyCount == 2)
        let rids = Set(lookup.calls.map(\.2))
        #expect(rids == [decryptor.deviceRecipientID, try HistoryCrypto.recipientID(publicKey: recoveryKey.publicKey.rawRepresentation)])
    }

    @Test func transportFailuresThrowAndServerRefusalsLock() async throws {
        let fixture = try HistoryBackendFixture()
        let event = try fixture.event(1, payload: HistoryBackendFixture.payload("x"))
        let offline = try HistoryDecryptor(deviceSeed: fixture.deviceSeed, fetchWraps: WrapLookup(failure: .disconnected).fetch)
        await #expect(throws: TodexError.self) { try await offline.decrypt(event) }
        let refused = try HistoryDecryptor(
            deviceSeed: fixture.deviceSeed, fetchWraps: WrapLookup(failure: .server(code: "FORBIDDEN", message: "no")).fetch)
        #expect(HistoryEncryption.isLocked(try await refused.decrypt(event).payload))
    }

    @Test func compressedFramesAndTitlesAreHandled() async throws {
        let fixture = try HistoryBackendFixture()
        let lookup = WrapLookup()
        lookup.add(try fixture.wrap(for: fixture.devicePublicKey), kid: fixture.key.kid)
        let decryptor = try HistoryDecryptor(deviceSeed: fixture.deviceSeed, fetchWraps: lookup.fetch)
        let zstd = try fixture.frameEvents(
            [HistoryBackendFixture.payload("a")], firstSequence: 1, plaintext: Data([0x28, 0xB5, 0x2F, 0xFD, 0, 1]))
        #expect(HistoryEncryption.isLocked(try await decryptor.decrypt(zstd.events, frames: zstd.frames)[0].payload))

        let title = try HistoryCrypto.seal(Data("计划 🔐".utf8), key: fixture.key, conversationID: "c", stream: .eventFull, counter: 0)
        let titleEnc: JSONValue = ["kid": .string(fixture.kidText), "ct": .string(CryptoEncoding.encode(title))]
        #expect(try await decryptor.decryptTitle(titleEnc, conversationId: "c") == "计划 🔐")
        #expect(try await decryptor.decryptTitle(titleEnc, conversationId: "other") == nil)
        #expect(try await decryptor.decryptTitle(["kid": "bad"], conversationId: "c") == nil)
    }

    @Test func runtimeShowsOneQuietRowPerLockedRunAndKeepsLifecycle() {
        var runtime = ConversationRuntime(conversationId: "c")
        let locked = { (sequence: Int, type: String, payload: JSONValue) in
            ConversationEvent(sequence: sequence, eventId: "evt_\(sequence)", conversationId: "c", type: type, payload: payload)
        }
        runtime.ingest(locked(1, "turn.started", ["turnId": "t1", "detailLocked": true]))
        runtime.ingest(locked(2, "message.created", ["turnId": "t1", "role": "user", "detailLocked": true]))
        runtime.ingest(locked(3, "message.delta", ["turnId": "t1", "role": "assistant", "detailLocked": true]))
        runtime.ingest(locked(4, "tool.started", ["turnId": "t1", "toolCallId": "x", "detailLocked": true]))
        #expect(runtime.status == "running")
        runtime.ingest(locked(5, "turn.completed", ["turnId": "t1", "stopReason": "endTurn", "detailLocked": true]))
        #expect(runtime.status == "completed")
        #expect(runtime.appliedSequence == 5)
        #expect(runtime.messages.count == 1)
        #expect(runtime.messages[0].category == ConversationRuntime.lockedCategory)
        #expect(runtime.messages[0].detail["firstSequence"] == 2)
        #expect(runtime.messages[0].detail["lastSequence"] == 4)
        #expect(ConversationExport.transcriptMessages(runtime.messages).isEmpty)
    }
}
