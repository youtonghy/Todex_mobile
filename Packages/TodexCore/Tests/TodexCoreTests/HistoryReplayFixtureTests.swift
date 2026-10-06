import Foundation
import Testing

@testable import TodexCore

/// Interop with the backend's `tests/fixtures/history-e2e-replay.json`
/// (docs/history-encryption.md §5.3): REST pages in both details and the
/// socket backfill of one conversation with a sealed segment (frame-level
/// `fr`, counter = segment << 32 | ordinal) and active records (event-level
/// `s`/`f`), decrypted through the same `HistoryDecryptor` path the app uses.
struct HistoryReplayFixtureTests {
    @Test func restPagesDecryptToTheExpectedPayloads() async throws {
        let fixture = try replayFixture()
        let seed = try hex(fixture["seed"])
        let rid = try HistoryCrypto.recipientID(publicKey: HistoryCrypto.recipientKey(seed: seed).publicKey.rawRepresentation)
        #expect(HistoryEncryption.encodeID(rid) == fixture["rid"].stringValue)
        for (detail, expected) in [("full", fixture["expected"]), ("summary", fixture["expectedSummary"])] {
            let page = fixture["pages"][detail]
            let lookup = try keyringLookup(fixture)
            let decryptor = try HistoryDecryptor(deviceSeed: hex(fixture["seed"]), fetchWraps: lookup.fetch)
            let events = try page["events"].arrayValue.map { try $0.decoded(ConversationEvent.self) }
            #expect(events.allSatisfy { HistoryEncryption.isEncrypted($0.payload) })
            let plain = try await decryptor.decrypt(events, frames: page["frames"])
            #expect(plain.map(\.sequence) == Array(1...10), "\(detail)")
            #expect(plain.map(\.payload) == expected.arrayValue, "\(detail)")
            #expect(plain.allSatisfy { !HistoryEncryption.isLocked($0.payload) }, "\(detail)")
            // Every key is fetched with the conversation's own id, once.
            #expect(lookup.calls.allSatisfy { $0.0 == fixture["conversationId"].stringValue })
            #expect(Set(lookup.calls.flatMap(\.1)).count == lookup.calls.flatMap(\.1).count)
        }
    }

    @Test func socketBackfillMessagesDecryptOneByOneWithTheirOwnFrames() async throws {
        let fixture = try replayFixture()
        let decryptor = try HistoryDecryptor(deviceSeed: hex(fixture["seed"]), fetchWraps: keyringLookup(fixture).fetch)
        let messages = fixture["socketBackfillSummary"].arrayValue
        let expected = fixture["expectedSummary"].arrayValue
        #expect(messages.count == expected.count)
        for (message, payload) in zip(messages, expected) {
            #expect(message["type"] == "conversation.event")
            let event = try message["payload"].decoded(ConversationEvent.self)
            let plain = try await decryptor.decrypt(event, frames: message["frames"])
            #expect(plain.payload == payload, "sequence \(event.sequence)")
        }
    }

    @Test func frameCountersAboveTwoToTheThirtyTwoParseExactly() throws {
        let fixture = try replayFixture()
        for detail in ["full", "summary"] {
            for (_, value) in fixture["pages"][detail]["frames"].objectValue {
                let frame = try HistoryEncryption.Frame(value)
                #expect(frame.counter == 1 << 32)
            }
        }
        // The largest counter the wire allows (2^53 - 1) survives JSON decoding.
        let wire = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"kid":"SkvGTqwgDBeubTEHwSUufg","stream":4,"counter":9007199254740991,"c":"c","ct":"AA"}"#.utf8))
        #expect(try HistoryEncryption.Frame(wire).counter == 9_007_199_254_740_991)
    }

    @Test func encryptedTitleDecryptsWhenThePlainTitleIsOmitted() async throws {
        let fixture = try replayFixture()
        let decryptor = try HistoryDecryptor(deviceSeed: hex(fixture["seed"]), fetchWraps: keyringLookup(fixture).fetch)
        let conversationId = fixture["conversationId"].stringValue
        // An e2e manifest omits `title` and carries `titleEnc` instead.
        var wire: JSONValue = [
            "id": .string(conversationId), "provider": "codex", "workspace": "/w", "status": "idle", "lastSequence": 10,
            "createdAt": "2026-10-06T00:00:00Z", "updatedAt": "2026-10-06T00:00:00Z",
        ]
        wire["titleEnc"] = fixture["manifest"]["titleEnc"]
        let manifest = try wire.decoded(ConversationManifest.self)
        #expect(manifest.title == nil)
        let titleEnc = try #require(manifest.titleEnc)
        let title = try await decryptor.decryptTitle(titleEnc, conversationId: manifest.id)
        #expect(title == fixture["manifest"]["expectedTitle"].stringValue)
    }

    @Test func providerOwnedEncFieldIsNotCiphertext() async throws {
        let fixture = try replayFixture()
        let lookup = try keyringLookup(fixture)
        let decryptor = try HistoryDecryptor(deviceSeed: hex(fixture["seed"]), fetchWraps: lookup.fetch)
        // §4.5: a provider payload's own top-level `$enc` is stored as `_$enc`.
        let payload: JSONValue = ["turnId": "t1", "_$enc": ["v": 1, "kid": "x", "f": "not ciphertext"]]
        let event = ConversationEvent(
            sequence: 1, eventId: "evt_1", conversationId: "c", type: "provider.raw", payload: payload)
        #expect(!HistoryEncryption.isEncrypted(payload))
        #expect(try await decryptor.decrypt(event).payload == payload)
        #expect(lookup.calls.isEmpty)
    }
}

private func replayFixture() throws -> JSONValue {
    let url = try #require(
        Bundle.module.url(forResource: "history-e2e-replay", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

/// Answers `history.keys.wraps` from the fixture's `keyring` (`{kid: [WrappedKey]}`).
private func keyringLookup(_ fixture: JSONValue) throws -> WrapLookup {
    let lookup = WrapLookup()
    for (kid, wraps) in fixture["keyring"].objectValue {
        let kid = try CryptoEncoding.decode(kid, count: HistoryCrypto.kidLength)
        for wrapped in wraps.arrayValue { lookup.add(try wrapped.decoded(HistoryCrypto.WrappedKey.self), kid: kid) }
    }
    return lookup
}

private func hex(_ value: JSONValue) throws -> Data {
    let bytes = Array(value.stringValue.utf8)
    guard bytes.count.isMultiple(of: 2) else { throw TodexError.invalid("odd hex length") }
    return try Data(
        stride(from: 0, to: bytes.count, by: 2).map { index in
            guard let byte = UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16) else {
                throw TodexError.invalid("invalid hex")
            }
            return byte
        })
}
