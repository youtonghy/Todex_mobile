import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import TodexCore

struct HistoryRecoveryKeyTests {
    /// Every 256-bit English vector from trezor/python-mnemonic `vectors.json`.
    static let vectors: [(String, String)] = [
        ("0000000000000000000000000000000000000000000000000000000000000000",
         "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"),
        ("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f",
         "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"),
        ("8080808080808080808080808080808080808080808080808080808080808080",
         "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"),
        ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
         "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"),
        ("68a79eaca2324873eacc50cb9c6eca8cc68ea5d936f98787c60c7ebc74e6ce7c",
         "hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length"),
        ("9f6a2878b2520799a44ef18bc7df394e7061a224d2c33cd015b157d746869863",
         "panda eyebrow bullet gorilla call smoke muffin taste mesh discover soft ostrich alcohol speed nation flash devote level hobby quick inner drive ghost inside"),
        ("066dca1a2bb7e8a1db2832148ce9933eea0f3ac9548d793112d9a95c9407efad",
         "all hour make first leader extend hole alien behind guard gospel lava path output census museum junior mass reopen famous sing advance salt reform"),
        ("f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f",
         "void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold"),
    ]

    @Test(arguments: vectors)
    func officialVectors(entropy: String, mnemonic: String) throws {
        let seed = Data(stride(from: 0, to: entropy.count, by: 2).map {
            UInt8(entropy[entropy.index(entropy.startIndex, offsetBy: $0)..<entropy.index(entropy.startIndex, offsetBy: $0 + 2)], radix: 16)!
        })
        #expect(try HistoryRecoveryKey.words(seed: seed).joined(separator: " ") == mnemonic)
        #expect(try HistoryRecoveryKey.seed(words: mnemonic) == seed)
    }

    @Test func wordlistIsTheVerifiedOfficialList() throws {
        let list = try HistoryRecoveryKey.wordlist()
        #expect(list.count == 2048)
        #expect(list.first == "abandon" && list.last == "zoo")
        #expect(Set(list.map { $0.prefix(4) }).count == 2048)
    }

    @Test func parsingIsForgivingButChecksTheChecksum() throws {
        let seed = HistoryRecoveryKey.generateSeed()
        let words = try HistoryRecoveryKey.words(seed: seed)
        #expect(try HistoryRecoveryKey.seed(words: "  " + words.joined(separator: "\n ").uppercased() + " ") == seed)
        #expect(try HistoryRecoveryKey.seed(words: words.map { String($0.prefix(4)) }.joined(separator: ", ")) == seed)
        #expect(try HistoryRecoveryKey.seed(parsing: words.joined(separator: " ")) == seed)
        var swapped = words
        swapped.swapAt(0, 1)
        if swapped != words {
            #expect(throws: TodexError.self) { try HistoryRecoveryKey.seed(words: swapped.joined(separator: " ")) }
        }
        #expect(throws: TodexError.self) { try HistoryRecoveryKey.seed(words: words.dropLast().joined(separator: " ")) }
        #expect(throws: TodexError.self) {
            try HistoryRecoveryKey.seed(words: (["notaword"] + words.dropFirst()).joined(separator: " "))
        }
        // "abandon abandon … abandon" (24×) fails the checksum; "art" is the valid last word.
        #expect(throws: TodexError.self) {
            try HistoryRecoveryKey.seed(words: Array(repeating: "abandon", count: 24).joined(separator: " "))
        }
        #expect(throws: TodexError.self) { try HistoryRecoveryKey.words(seed: Data(count: 31)) }
    }

    @Test func qrStringRoundTrips() throws {
        let seed = HistoryRecoveryKey.generateSeed()
        let text = try HistoryRecoveryKey.qrString(seed: seed)
        #expect(text.hasPrefix("todex-recovery:v1:"))
        #expect(text.count == "todex-recovery:v1:".count + 43)
        #expect(try HistoryRecoveryKey.seed(qrString: text + "\n") == seed)
        #expect(try HistoryRecoveryKey.seed(parsing: text) == seed)
        #expect(throws: TodexError.self) { try HistoryRecoveryKey.seed(qrString: "todex-recovery:v2:" + CryptoEncoding.encode(seed)) }
        #expect(throws: TodexError.self) { try HistoryRecoveryKey.seed(qrString: "todex-recovery:v1:AAAA") }
    }
}

/// An in-memory §7 backend: keyrings per conversation, `keys.list` paging,
/// `keys.wraps` by rid and `grant.fulfill` that appends wraps.
final class FakeHistoryBackend: Sendable {
    struct State {
        var keyrings: [String: [Data: [HistoryCrypto.WrappedKey]]] = [:]
        var pageSize = 3
        var fulfillBatches: [Int] = []
        var completions: [Bool] = []
        var failFulfillAfter: Int?
        var commands: [String] = []
        var wrapsRids: [String?] = []
    }
    let state = Mutex(State())

    func add(conversation: String, kid: Data, wraps: [HistoryCrypto.WrappedKey]) {
        state.withLock { $0.keyrings[conversation, default: [:]][kid, default: []] += wraps }
    }

    func wraps(conversation: String, kid: Data) -> [HistoryCrypto.WrappedKey] {
        state.withLock { $0.keyrings[conversation]?[kid] ?? [] }
    }

    var api: HistoryAPI { HistoryAPI { [self] type, payload in try handle(type, payload) } }

    private func handle(_ type: String, _ payload: JSONValue) throws -> JSONValue {
        try state.withLock { state in
            state.commands.append(type)
            switch type {
            case "history.keys.list":
                let items = state.keyrings.keys.sorted().flatMap { conversation in
                    state.keyrings[conversation]!.keys.map { CryptoEncoding.encode($0) }.sorted().map { (conversation, $0) }
                }
                let start = Int(payload["cursor"].stringValue) ?? 0
                #expect(payload["limit"].intValue <= 500)
                let page = items[min(start, items.count)..<min(start + state.pageSize, items.count)]
                var result: JSONValue = [
                    "items": .array(page.map { ["conversationId": .string($0.0), "kid": .string($0.1)] })
                ]
                if start + state.pageSize < items.count { result["nextCursor"] = .string(String(start + state.pageSize)) }
                return result
            case "history.keys.wraps":
                state.wrapsRids.append(payload["rid"].optionalString)
                let rid = try payload["rid"].optionalString.map { try CryptoEncoding.decode($0) }
                var wraps: [String: JSONValue] = [:]
                for kidText in payload["kids"].arrayValue.map(\.stringValue) {
                    let kid = try CryptoEncoding.decode(kidText)
                    let all = state.keyrings[payload["conversationId"].stringValue]?[kid] ?? []
                    if let match = all.first(where: { rid == nil || $0.rid == rid }) {
                        wraps[kidText] = try JSONValue(encoding: match)
                    }
                }
                return ["wraps": .object(wraps)]
            case "history.grant.fulfill":
                let wraps = try payload["wraps"].decoded([HistoryGrantWrap].self)
                #expect(wraps.count <= 500)
                if let limit = state.failFulfillAfter, state.fulfillBatches.count >= limit { throw TodexError.disconnected }
                state.fulfillBatches.append(wraps.count)
                state.completions.append(payload["complete"] == true)
                var added = 0
                for wrap in wraps {
                    #expect(CryptoEncoding.encode(wrap.wrapped.rid) == payload["rid"].stringValue)
                    let kid = try CryptoEncoding.decode(wrap.kid)
                    if !(state.keyrings[wrap.conversationId]?[kid] ?? []).contains(where: { $0.rid == wrap.wrapped.rid }) {
                        state.keyrings[wrap.conversationId, default: [:]][kid, default: []].append(wrap.wrapped)
                        added += 1
                    }
                }
                return ["added": .number(Double(added))]
            default:
                throw TodexError.server(code: "UNSUPPORTED", message: type)
            }
        }
    }
}

struct HistoryGrantTests {
    @Test func reWrapsEveryReadableKeyForTheTargetInResumableBatches() async throws {
        let backend = FakeHistoryBackend()
        let source = try HistoryCrypto.generateRecipientKey()
        let target = try HistoryCrypto.generateRecipientKey()
        var keys: [(String, HistoryCrypto.SegmentKey)] = []
        for conversation in ["a", "b"] {
            for _ in 0..<4 {
                let key = HistoryCrypto.SegmentKey.generate()
                keys.append((conversation, key))
                backend.add(conversation: conversation, kid: key.kid, wraps: [try HistoryCrypto.wrap(key, for: source.publicKey.rawRepresentation)])
            }
        }
        // A key from before the source device was registered: it cannot help.
        let unreadable = HistoryCrypto.SegmentKey.generate()
        backend.add(conversation: "b", kid: unreadable.kid, wraps: [])
        let targetRecipient = HistoryRecipient(
            rid: CryptoEncoding.encode(try HistoryCrypto.recipientID(publicKey: target.publicKey.rawRepresentation)),
            kind: "device", deviceId: "dev_new", publicKey: CryptoEncoding.encode(target.publicKey.rawRepresentation))
        // The upload after the first page fails mid-run (connection lost).
        backend.state.withLock { $0.failFulfillAfter = 1 }
        let reports = Mutex<[HistoryGrant.Progress]>([])
        await #expect(throws: TodexError.self) {
            try await HistoryGrant.fulfill(
                api: backend.api, grantId: "grt_1", target: targetRecipient, source: source, sourceRid: nil
            ) { progress in reports.withLock { $0.append(progress) } }
        }
        let last = reports.withLock { $0.last }
        let checkpoint = try #require(last)
        #expect(checkpoint.cursor == "3")
        #expect(checkpoint.processed == 3)
        backend.state.withLock { $0.failFulfillAfter = nil }
        let result = try await HistoryGrant.fulfill(
            api: backend.api, grantId: "grt_1", target: targetRecipient, source: source, sourceRid: nil, resume: checkpoint)
        #expect(result.finished)
        #expect(result.processed == 8)
        #expect(result.skipped == 1)
        #expect(result.added == 8)
        for (conversation, key) in keys {
            let wrap = try #require(backend.wraps(conversation: conversation, kid: key.kid).first { $0.rid != (try? HistoryCrypto.recipientID(publicKey: source.publicKey.rawRepresentation)) })
            #expect(try HistoryCrypto.unwrap(wrap, kid: key.kid, with: target).dek == key.dek)
        }
        let batches = backend.state.withLock { $0.fulfillBatches }
        #expect(batches.allSatisfy { $0 <= 500 })
        // Only the last batch marks the grant fulfilled.
        let completions = backend.state.withLock { $0.completions }
        #expect(completions.last == true && completions.dropLast().allSatisfy { !$0 })
    }

    @Test func recoverySelfGrantUsesRecoveryWrapsAndNoGrantID() async throws {
        let backend = FakeHistoryBackend()
        let recovery = try HistoryCrypto.recipientKey(seed: HistoryRecoveryKey.generateSeed())
        let recoveryRid = try HistoryCrypto.recipientID(publicKey: recovery.publicKey.rawRepresentation)
        let device = try HistoryCrypto.generateRecipientKey()
        let key = HistoryCrypto.SegmentKey.generate()
        backend.add(conversation: "c", kid: key.kid, wraps: [try HistoryCrypto.wrap(key, for: recovery.publicKey.rawRepresentation)])
        let me = HistoryRecipient(
            rid: CryptoEncoding.encode(try HistoryCrypto.recipientID(publicKey: device.publicKey.rawRepresentation)),
            kind: "device", publicKey: CryptoEncoding.encode(device.publicKey.rawRepresentation))
        let result = try await HistoryGrant.fulfill(
            api: backend.api, grantId: nil, target: me, source: recovery, sourceRid: recoveryRid)
        #expect(result.processed == 1)
        let rids = backend.state.withLock { $0.wrapsRids }
        #expect(rids == [CryptoEncoding.encode(recoveryRid)])
        let completions = backend.state.withLock { $0.completions }
        #expect(completions == [false])
        let mine = try #require(backend.wraps(conversation: "c", kid: key.kid).first { $0.rid != recoveryRid })
        #expect(try HistoryCrypto.unwrap(mine, kid: key.kid, with: device).dek == key.dek)
    }

    @Test func targetKeyMustMatchItsRecipientID() async throws {
        let backend = FakeHistoryBackend()
        let source = try HistoryCrypto.generateRecipientKey()
        let other = try HistoryCrypto.generateRecipientKey()
        let mismatched = HistoryRecipient(
            rid: CryptoEncoding.encode(try HistoryCrypto.recipientID(publicKey: source.publicKey.rawRepresentation)),
            kind: "device", publicKey: CryptoEncoding.encode(other.publicKey.rawRepresentation))
        await #expect(throws: TodexError.self) {
            try await HistoryGrant.fulfill(api: backend.api, grantId: "g", target: mismatched, source: source, sourceRid: nil)
        }
        let commands = backend.state.withLock { $0.commands }
        #expect(commands.isEmpty)
    }
}

struct HistoryWireTests {
    @Test func commandsUseTheSpecifiedShapes() async throws {
        let sent = Mutex<[(String, JSONValue)]>([])
        let api = HistoryAPI { type, payload in
            sent.withLock { $0.append((type, payload)) }
            switch type {
            case "history.encryption.get", "history.encryption.enable":
                return [
                    "mode": "e2e", "epoch": 3, "myRid": "r1",
                    "recipients": [["rid": "r1", "kind": "device", "deviceId": "dev_1", "publicKey": "pk", "addedAt": "t", "revokedAt": nil]],
                    "grants": [["grantId": "grt_1", "rid": "r2", "deviceId": "dev_2", "requestedAt": "t", "status": "pending", "publicKey": "pk2"]],
                ]
            case "history.recipient.register", "history.recovery.set": return ["rid": "r9"]
            case "history.grant.request": return ["grantId": "grt_9"]
            case "history.grant.list": return ["grants": []]
            case "history.keys.list": return ["items": []]
            case "history.keys.wraps": return ["wraps": [:]]
            default: return [:]
            }
        }
        let state = try await api.state()
        #expect(state.isEnabled && state.epoch == 3 && state.myRid == "r1")
        #expect(state.recipients.first?.deviceId == "dev_1" && state.recipients.first?.isRevoked == false)
        #expect(state.grants.first?.isPending == true)
        #expect(state.grants.first?.recipient?.publicKey == "pk2")
        _ = try await api.enable()
        let publicKey = Data(repeating: 7, count: 1216)
        #expect(try await api.register(publicKey: publicKey) == "r9")
        #expect(try await api.requestGrant() == "grt_9")
        #expect(try await api.grants().isEmpty)
        try await api.dismissGrant("grt_1")
        _ = try await api.keys(conversationId: "c", cursor: "x", limit: 9_999)
        let wraps = try await api.wraps(conversationId: "c", kids: [Data(count: 16)], rid: Data(repeating: 1, count: 16))
        #expect(wraps.isEmpty)
        let log = sent.withLock { $0 }  // snapshot
        #expect(log.map(\.0) == [
            "history.encryption.get", "history.encryption.enable", "history.recipient.register", "history.grant.request",
            "history.grant.list", "history.grant.dismiss", "history.keys.list", "history.keys.wraps",
        ])
        #expect(log[2].1 == ["publicKey": .string(CryptoEncoding.encode(publicKey))])
        #expect(log[5].1 == ["grantId": "grt_1"])
        #expect(log[6].1 == ["conversationId": "c", "cursor": "x", "limit": 500])
        #expect(log[7].1 == ["conversationId": "c", "kids": ["AAAAAAAAAAAAAAAAAAAAAA"], "rid": "AQEBAQEBAQEBAQEBAQEBAQ"])
        await #expect(throws: TodexError.self) {
            try await api.wraps(conversationId: "c", kids: Array(repeating: Data(count: 16), count: 501))
        }
        // An older backend's empty reply is reported, not decoded as "off".
        let empty = HistoryAPI { _, _ in [:] }
        await #expect(throws: TodexError.self) { try await empty.state() }
    }

    @Test func historyErrorsReadClearly() {
        let upgrade = TodexError.server(code: "CLIENT_UPGRADE_REQUIRED", message: "raw")
        let storage = TodexError.server(code: "STORAGE_LOW", message: "raw")
        #expect(upgrade.localizedDescription != "raw" && upgrade.localizedDescription.contains("TodeX"))
        #expect(storage.localizedDescription != "raw")
        #expect(TodexError.server(code: "507", message: "raw").localizedDescription == storage.localizedDescription)
        #expect(TodexError.server(code: "OTHER", message: "raw").localizedDescription == "raw")
        #expect(ProtocolCatalog.descriptor(type: "history.grant.fulfill")?.support == .conditional)
    }

    @Test func manifestCarriesTheEncryptedTitle() throws {
        let wire: JSONValue = [
            "id": "c", "provider": "codex", "workspace": "/w", "title": "", "status": "idle", "lastSequence": 1,
            "createdAt": "t", "updatedAt": "t", "titleEnc": ["kid": "k", "ct": "x"],
        ]
        let manifest = try wire.decoded(ConversationManifest.self)
        #expect(manifest.titleEnc?["kid"] == "k")
        #expect(try JSONValue(encoding: ConversationManifest(provider: "p", workspace: "w")).objectValue["titleEnc"] == nil)
    }
}

struct ConversationEventCacheTests {
    @Test func storesEventsAsReceivedWithTheirFrames() throws {
        let fixture = try HistoryBackendFixture()
        let secret = "do not write me to disk"
        var cache = ConversationEventCache()
        let first = try fixture.event(1, payload: HistoryBackendFixture.payload(secret))
        let recorded1 = cache.record(first)
        #expect(recorded1)
        let sealed = try fixture.frameEvents([HistoryBackendFixture.payload(secret), HistoryBackendFixture.payload("2")], firstSequence: 2)
        for event in sealed.events {
            let recorded = cache.record(event, frames: sealed.frames)
            #expect(recorded)
        }
        let stored = try #require(cache.stored("c"))
        #expect(stored.events == [first] + sealed.events)
        #expect(stored.frames == sealed.frames.objectValue)
        let encoded = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        #expect(!encoded.contains(secret))
        #expect(encoded.contains("$enc"))
        #expect(try JSONDecoder().decode(CachedHistory.self, from: JSONEncoder().encode(stored)) == stored)
        // The cost estimate is the encoded size, not a multiple of it.
        #expect(ConversationEventCache.cost(try JSONValue(encoding: first)) >= (try JSONEncoder().encode(first.payload).count))
    }

    @Test func aMissingFrameOrTheByteLimitStopsThePrefix() throws {
        let fixture = try HistoryBackendFixture()
        var cache = ConversationEventCache()
        let sealed = try fixture.frameEvents([HistoryBackendFixture.payload("a")], firstSequence: 1)
        let recorded2 = cache.record(sealed.events[0], frames: .null)
        #expect(!recorded2)
        let recorded3 = cache.record(try fixture.event(1, payload: HistoryBackendFixture.payload("b")))
        #expect(!recorded3)
        #expect(cache.stored("c")?.events.isEmpty == true)

        var small = ConversationEventCache(journalByteLimit: 4_000, totalByteLimit: 1_000_000)
        var sequence = 0
        while small.record(try fixture.event(sequence + 1, payload: HistoryBackendFixture.payload(String(repeating: "x", count: 300)))) {
            sequence += 1
        }
        #expect(sequence > 1)
        #expect(small.stored("c")?.events.map(\.sequence) == Array(1...sequence))
        let recorded4 = small.record(try fixture.event(sequence + 1, payload: HistoryBackendFixture.payload("tiny")))
        #expect(!recorded4)
        #expect(small.totalBytes <= 4_000)
        small.remove("c")
        #expect(small.totalBytes == 0)
    }

    @Test func outOfOrderEventsWaitForTheGapAndLegacyFilesDecode() throws {
        var cache = ConversationEventCache()
        let event = { (sequence: Int) in
            ConversationEvent(sequence: sequence, eventId: "e\(sequence)", conversationId: "c", type: "message.delta", payload: ["text": "x"])
        }
        let recorded5 = cache.record(event(2))
        #expect(!recorded5)
        #expect(cache.stored("c")?.events.isEmpty == true)
        let recorded6 = cache.record(event(1))
        #expect(recorded6)
        #expect(cache.stored("c")?.events.map(\.sequence) == [1, 2])
        let recorded7 = cache.record(event(ConversationEventCache.maximumSequence + 1))
        #expect(!recorded7)
        let legacy = try JSONEncoder().encode([event(1)])
        #expect(try JSONDecoder().decode(CachedHistory.self, from: legacy) == CachedHistory(events: [event(1)]))
    }
}
