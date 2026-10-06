import Foundation
import Testing

@testable import TodexCore

/// History v3 end to end against the isolated fixture backend
/// (docs/history-encryption.md §5.3, §5.4, §7). Part of the serialized
/// `RealtimeLiveTests` suite so no plaintext-mode test overlaps it, and it
/// switches encryption back off when done so their order does not matter.
/// Conversations it encrypted stay encrypted.
extension RealtimeLiveTests {
    @Test func actualEndToEndEncryptedHistory() async throws {
        let fixture = try LiveFixture()
        let api = APIClient(connection: fixture.connection)
        let wrapsClient = RealtimeClient(connection: fixture.connection)
        try await wrapsClient.connect()
        let seed = try HistoryCrypto.generateRecipientKey().seedRepresentation
        // The same wiring as AppSession.historyKeys(): the device's own wraps
        // use the default (caller) recipient.
        let keys = try HistoryDecryptor(deviceSeed: seed) { conversationId, kids, _ in
            try await HistoryAPI(client: wrapsClient).wraps(conversationId: conversationId, kids: kids)
        }
        let token = "e2e-live-" + UUID().uuidString.lowercased()
        let prompt = "Encrypted prompt " + token
        let title = "Encrypted title " + token
        let renamed = "Renamed title " + token

        do {
            let (earlier, conversationID) = try await withLiveClient(fixture.connection) { client, frames in
                let history = HistoryAPI(client: client)
                // An existing plaintext conversation: enabling e2e re-encrypts
                // it into sealed frames (§8), served as `fr` + `frames`.
                let earlier = try await history.state().isEnabled ? nil : try await quietPlaintextConversation(fixture, keys)
                let rid = try await history.register(publicKey: keys.devicePublicKey)
                #expect(rid == HistoryEncryption.encodeID(keys.deviceRecipientID))
                let recovery = try HistoryCrypto.recipientKey(seed: HistoryRecoveryKey.generateSeed())
                _ = try await history.setRecovery(publicKey: recovery.publicKey.rawRepresentation)
                let enabled = try await history.enable()
                #expect(enabled.isEnabled)
                #expect(enabled.myRid == rid)
                #expect(enabled.activeRecovery != nil)

                let turn = try await runTurn(client: client, frames: frames, fixture: fixture, prompt: prompt, title: title)
                #expect(turn.created["title"].isNull)
                let titleEnc = try #require(turn.created["titleEnc"].objectValue.isEmpty ? nil : turn.created["titleEnc"])
                #expect(try await keys.decryptTitle(titleEnc, conversationId: turn.conversationID) == title)
                var live: [ConversationEvent] = []
                for frame in turn.frames {
                    let event = try frame["payload"].decoded(ConversationEvent.self)
                    // Live pushes carry the journal's ciphertext, never plaintext content.
                    #expect(HistoryEncryption.isEncrypted(event.payload), "\(event.type) #\(event.sequence) was not encrypted")
                    live.append(try await keys.decrypt(event, frames: frame["frames"]))
                }
                try checkPlaintext(live, contains: [prompt, "Fixture Codex: " + prompt], detail: "live")
                return (earlier, turn.conversationID)
            }

            // Title: stored as `titleEnc` only, decrypted with the conversation's keyring.
            let updated = try await api.updateConversation(id: conversationID, patch: ["title": .string(renamed)])
            for manifest in [updated, try await api.conversation(id: conversationID)] {
                #expect((manifest.title ?? "").isEmpty)
                let titleEnc = try #require(manifest.titleEnc)
                #expect(try await keys.decryptTitle(titleEnc, conversationId: conversationID) == renamed)
            }

            try await checkReplays(
                fixture: fixture, api: api, keys: keys, conversationID: conversationID,
                contains: [prompt, "Fixture Codex: " + prompt])
            if let earlier {
                let (earlierID, earlier) = earlier
                try await waitForMigration(fixture: fixture, conversationID: earlierID)
                let sealed = try await checkReplays(
                    fixture: fixture, api: api, keys: keys, conversationID: earlierID, contains: [])
                #expect(sealed.contains { $0.raw.payload[HistoryEncryption.Envelope.field]["fr"] != .null }, "no sealed frames")
                // Re-encryption keeps every record; sealing may only compact
                // deltas that a final record supersedes, and dedup hashes become MACs (§4.5).
                #expect(sealed.map(\.raw.sequence) == earlier.map(\.sequence))
                for (after, before) in zip(sealed.map(\.plain), earlier) where after.type == before.type {
                    #expect(withoutDedupKeys(after.payload) == withoutDedupKeys(before.payload), "#\(before.sequence) \(before.type)")
                }
                try expectCiphertextJournal(fixture.dataDirectory.appendingPathComponent("conversations/\(earlierID)"))
            } else {
                print("No conversation was quiet for 2 minutes in plaintext; skipping the migration check")
            }

            // Retry needs the decrypted prompt, taken the way AppSession takes
            // it: the newest user message of the projected runtime. Prompts run
            // trimmed and the journal shows them so; the backend's textMac
            // covers that form, so surrounding whitespace must not break retry.
            let latestPrompt = "  Second prompt " + token + "\n"
            try await withLiveClient(fixture.connection) { client, frames in
                let head = try await api.conversation(id: conversationID).lastSequence
                _ = try await client.command(
                    type: "conversation.subscribe",
                    payload: ["conversationId": .string(conversationID), "afterSequence": .number(Double(head))],
                    timeout: 10)
                let second = try await client.command(
                    type: "conversation.prompt",
                    payload: ["conversationId": .string(conversationID), "text": .string(latestPrompt)], timeout: 10)
                let secondTurn = try #require(second["turnId"].optionalString)
                _ = try await frames.wait {
                    $0["type"] == "conversation.event" && $0["payload"]["type"] == "turn.completed"
                        && $0["payload"]["payload"]["turnId"] == .string(secondTurn)
                }
            }
            try await withLiveClient(fixture.connection) { client, frames in
                let full = try await restReplay(api: api, keys: keys, conversationID: conversationID, detail: "full")
                var runtime = ConversationRuntime(conversationId: conversationID)
                for event in full.map(\.plain) { runtime.ingest(event) }
                let retryPrompt = try #require(
                    runtime.messages.first { $0.role == "user" && !$0.text.isEmpty }?.text)
                #expect(retryPrompt == latestPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
                var older = ["conversationId": .string(conversationID)] as JSONValue
                older["prompt"] = .string(prompt)
                await expectServerError(["CONFLICT", "409"]) {
                    _ = try await client.command(type: "conversation.retry", payload: older, timeout: 10)
                }
                let target: JSONValue = ["conversationId": .string(conversationID)]
                await expectServerError(["INVALID_REQUEST", "400"]) {
                    _ = try await client.command(type: "conversation.retry", payload: target, timeout: 10)
                }
                var wrong = target
                wrong["prompt"] = "not the original prompt"
                await expectServerError(["CONFLICT", "409"]) {
                    _ = try await client.command(type: "conversation.retry", payload: wrong, timeout: 10)
                }
                _ = try await client.command(
                    type: "conversation.subscribe",
                    payload: [
                        "conversationId": .string(conversationID),
                        "afterSequence": .number(Double(full.last?.raw.sequence ?? 0)),
                    ],
                    timeout: 10)
                var retry = target
                retry["prompt"] = .string(retryPrompt)
                let retried = try await client.command(type: "conversation.retry", payload: retry, timeout: 10)
                #expect(retried["retried"] == true)
                let turnID = try #require(retried["turnId"].optionalString)
                let completed = try await frames.wait {
                    $0["type"] == "conversation.event" && $0["payload"]["type"] == "turn.completed"
                        && $0["payload"]["payload"]["turnId"] == .string(turnID)
                }
                let plain = try await keys.decrypt(
                    completed["payload"].decoded(ConversationEvent.self), frames: completed["frames"])
                #expect(!HistoryEncryption.isLocked(plain.payload))
            }

            // A fork copies the ciphertext with its source's AAD id and
            // sequences; its keys are fetched under the fork's own id.
            let fork = try await wrapsClient.command(
                type: "conversation.fork", payload: ["conversationId": .string(conversationID)], timeout: 10)
            let forkID = try #require(fork["conversationId"].optionalString)
            let forked = try await restReplay(api: api, keys: keys, conversationID: forkID, detail: "full")
            #expect(forked.contains { $0.raw.payload[HistoryEncryption.Envelope.field]["c"] == .string(conversationID) })
            try checkPlaintext(forked.map(\.plain), contains: [prompt, "Fixture Codex: " + prompt], detail: "fork")

            // Clients that do not declare `historyEncryption=1` are refused.
            await expectServerError(["CLIENT_UPGRADE_REQUIRED", "426"]) {
                _ = try await HTTPClient(connection: fixture.connection).request(
                    path: "/v2/conversations/\(conversationID)/events", query: ["afterSequence": "0"])
            }
            let legacy = try legacySocketClient(fixture.connection)
            try await legacy.connect()
            await expectServerError(["CLIENT_UPGRADE_REQUIRED", "426"]) {
                _ = try await legacy.command(
                    type: "conversation.subscribe", payload: ["conversationId": .string(conversationID)], timeout: 10)
            }
            await legacy.disconnect()

            // Nothing typed, answered or titled reaches the journal in plaintext.
            let leaks = try plaintextLeaks(in: fixture.dataDirectory, token: token)
            #expect(leaks.isEmpty, "plaintext in \(leaks)")
            let directory = fixture.dataDirectory.appendingPathComponent("conversations/\(conversationID)")
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("keyring.json").path))
            try expectCiphertextJournal(directory)
        } catch {
            _ = try? await HistoryAPI(client: wrapsClient).disable()
            await wrapsClient.disconnect()
            throw error
        }
        #expect(try await HistoryAPI(client: wrapsClient).disable().isEnabled == false)
        await wrapsClient.disconnect()
    }
}

/// Creates a titled Codex conversation, runs one prompt on the fake CLI and
/// returns the create result and the turn's live `conversation.event` frames.
private func runTurn(client: RealtimeClient, frames: LiveFrames, fixture: LiveFixture, prompt: String, title: String)
    async throws -> (conversationID: String, created: JSONValue, frames: [JSONValue])
{
    let created = try await client.command(
        type: "conversation.create",
        payload: ["provider": "codex", "workspace": .string(fixture.workspace), "title": .string(title)], timeout: 10)
    let conversationID = try #require(created["id"].optionalString)
    _ = try await checkReplay(client: client, frames: frames, conversationID: conversationID, after: 0)
    let result = try await client.command(
        type: "conversation.prompt", payload: ["conversationId": .string(conversationID), "text": .string(prompt)],
        timeout: 10)
    let turnID = try #require(result["turnId"].optionalString)
    _ = try await frames.wait {
        $0["type"] == "conversation.event" && $0["payload"]["type"] == "turn.completed"
            && $0["payload"]["payload"]["turnId"] == .string(turnID)
    }
    let live = frames.snapshot.filter {
        $0["type"] == "conversation.event" && $0["payload"]["conversationId"] == .string(conversationID)
    }
    return (conversationID, created, live)
}

/// REST replay in both details and a subscription backfill on a new socket,
/// each page or message decrypted with its own `frames`. Returns the raw
/// `detail=full` events with their plaintext.
@discardableResult
private func checkReplays(
    fixture: LiveFixture, api: APIClient, keys: HistoryDecryptor, conversationID: String, contains: [String]
) async throws -> [(raw: ConversationEvent, plain: ConversationEvent)] {
    var full: [(raw: ConversationEvent, plain: ConversationEvent)] = []
    for detail in ["summary", "full"] {
        let replay = try await restReplay(api: api, keys: keys, conversationID: conversationID, detail: detail)
        #expect(replay.allSatisfy { HistoryEncryption.isEncrypted($0.raw.payload) })
        try checkPlaintext(replay.map(\.plain), contains: contains, detail: detail)
        if detail == "full" { full = replay }
    }
    let backfill = try await withLiveClient(fixture.connection) { client, frames in
        let requestID = UUID().uuidString
        let response = try await client.command(
            type: "conversation.subscribe",
            payload: ["conversationId": .string(conversationID), "afterSequence": 0, "detail": "summary"],
            timeout: 10, id: requestID)
        #expect(response["subscribed"] == true)
        #expect(!response["hasMore"].boolValue)
        _ = try await frames.wait { $0["id"] == .string(requestID) }
        var plain: [ConversationEvent] = []
        for frame in frames.snapshot.prefix(while: { $0["id"] != .string(requestID) })
        where frame["type"] == "conversation.event" && frame["payload"]["conversationId"] == .string(conversationID) {
            plain.append(try await keys.decrypt(frame["payload"].decoded(ConversationEvent.self), frames: frame["frames"]))
        }
        return plain
    }
    #expect(backfill.map(\.sequence) == Array(1...(backfill.last?.sequence ?? 0)))
    try checkPlaintext(backfill, contains: contains, detail: "backfill")
    return full
}

/// The full plaintext replay of a conversation the background migration will
/// pick up right after e2e is enabled: idle and unchanged for over 2 minutes
/// (`MIGRATION_QUIET`). Nil when there is none, e.g. on a fixture seeded
/// moments ago.
private func quietPlaintextConversation(_ fixture: LiveFixture, _ keys: HistoryDecryptor) async throws
    -> (id: String, events: [ConversationEvent])?
{
    let http = HTTPClient(connection: fixture.connection)
    let api = APIClient(connection: fixture.connection)
    let quietSince = Date().addingTimeInterval(-150)
    let dates = ISO8601DateFormatter()
    dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for manifest in try await http.request(path: "/v2/conversations")["conversations"].arrayValue
    where manifest["historyEncryptedAt"].isNull && manifest["lastSequence"].intValue > 0
        && !["running", "waiting_permission"].contains(manifest["status"].stringValue)
    {
        guard let updated = dates.date(from: manifest["updatedAt"].stringValue), updated < quietSince else { continue }
        let id = manifest["id"].stringValue
        let replay = try await restReplay(api: api, keys: keys, conversationID: id, detail: "full")
        guard !replay.contains(where: { HistoryEncryption.isEncrypted($0.raw.payload) }) else { continue }
        return (id, replay.map(\.plain))
    }
    return nil
}

/// A payload without the dedup fields that migration turns into MACs.
private func withoutDedupKeys(_ payload: JSONValue) -> JSONValue {
    var fields = payload.objectValue
    fields["requestFingerprint"] = nil
    fields["textMac"] = nil
    if case .object(var control)? = fields["control"] {
        control["textMac"] = nil
        fields["control"] = .object(control)
    }
    return .object(fields)
}

/// Journal lines carry ciphertext (`x`, never `c`) and the last request has no prompt text.
private func expectCiphertextJournal(_ directory: URL) throws {
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
    where name.hasPrefix("events") && name.hasSuffix(".jsonl") {
        for line in try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n") {
            let record = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            #expect(record["c"].isNull, "\(name) #\(record["s"].intValue) is plaintext")
        }
    }
    let lastRequest = directory.appendingPathComponent("last-request.json")
    if FileManager.default.fileExists(atPath: lastRequest.path) {
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: lastRequest))["request"]
        #expect(request["text"] == "")
        #expect(!request["textMac"].stringValue.isEmpty)
        #expect(!request["content"].arrayValue.contains { ["text", "image"].contains($0["type"].stringValue) })
    }
}

/// Polls the manifest until the background migration stamps `historyEncryptedAt`.
private func waitForMigration(fixture: LiveFixture, conversationID: String) async throws {
    let http = HTTPClient(connection: fixture.connection)
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while ContinuousClock.now < deadline {
        if try await !http.request(path: "/v2/conversations/\(conversationID)")["historyEncryptedAt"].isNull { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("Conversation \(conversationID) was not re-encrypted within 60 s")
}

/// Every event decrypted, and the plaintext contains each of `contains`.
private func checkPlaintext(_ events: [ConversationEvent], contains: [String], detail: String) throws {
    #expect(!events.isEmpty, "\(detail)")
    for event in events {
        #expect(!HistoryEncryption.isEncrypted(event.payload), "\(detail) \(event.type) #\(event.sequence)")
        #expect(!HistoryEncryption.isLocked(event.payload), "\(detail) \(event.type) #\(event.sequence) is locked")
    }
    let text = try events.map { String(decoding: try JSONEncoder().encode($0.payload), as: UTF8.self) }.joined()
    for expected in contains { #expect(text.contains(expected), "\(detail) lacks \(expected)") }
}

/// Forward HTTP replay in small pages, as received and as decrypted.
private func restReplay(api: APIClient, keys: HistoryDecryptor, conversationID: String, detail: String)
    async throws -> [(raw: ConversationEvent, plain: ConversationEvent)]
{
    var events: [(raw: ConversationEvent, plain: ConversationEvent)] = []
    var cursor = 0
    for _ in 0..<1_000 {
        let page = try await api.events(conversationId: conversationID, after: cursor, limit: 3, detail: detail)
        let raw = try page["events"].arrayValue.map { try $0.decoded(ConversationEvent.self) }
        events += zip(raw, try await keys.decrypt(raw, frames: page["frames"])).map { ($0, $1) }
        guard page["hasMore"].boolValue else { break }
        let next = page["nextSequence"].intValue
        try #require(next > cursor, "REST replay did not advance")
        cursor = next
    }
    #expect(events.map(\.raw.sequence) == Array(1...(events.last?.raw.sequence ?? 0)))
    return events
}

/// A socket whose upgrade omits `historyEncryption=1`, signed like a real one.
private func legacySocketClient(_ connection: BackendConnection) throws -> RealtimeClient {
    var components = URLComponents(url: try connection.normalizedURL(), resolvingAgainstBaseURL: false)!
    components.scheme = "ws"
    components.path = "/v2/ws"
    let device = try #require(DeviceIdentity(secretKeyBase64URL: connection.deviceSecret))
    components.percentEncodedQuery = try device.authQuery(pathAndQuery: "/v2/ws")
    let request = URLRequest(url: try #require(components.url))
    return RealtimeClient(
        connection: connection, http: HTTPClient(connection: connection),
        makeSocket: { _ in LegacyWebSocket(request: request) })
}

/// A plain URLSession socket for the hand-built pre-v3 upgrade request.
private final class LegacyWebSocket: RealtimeSocket {
    private let task: URLSessionWebSocketTask
    init(request: URLRequest) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.resume()
    }
    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        task.send(.string(text)) { completion($0) }
    }
    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: throw TodexError.invalid("unknown WebSocket message")
        }
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

private func expectServerError(_ codes: Set<String>, _ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected one of \(codes.sorted())")
    } catch TodexError.server(let code, _) {
        #expect(codes.contains(code), "got \(code)")
    } catch {
        Issue.record("Expected one of \(codes.sorted()), got \(error)")
    }
}

/// Journal files under the data directory that contain `token` verbatim.
private func plaintextLeaks(in dataDirectory: URL, token: String) throws -> [String] {
    let journal = try #require(FileManager.default.enumerator(at: dataDirectory, includingPropertiesForKeys: nil))
    var leaks: [String] = []
    for case let url as URL in journal {
        let name = url.lastPathComponent
        guard (name.hasPrefix("events") && (name.hasSuffix(".jsonl") || name.hasSuffix(".seg")))
            || ["manifest.json", "last-request.json", "snapshot.json"].contains(name)
        else { continue }
        let data = try Data(contentsOf: url)
        if data.range(of: Data(token.utf8)) != nil { leaks.append(url.path) }
    }
    return leaks
}
