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

            // A request with inline content shows its items appended in the
            // journal, so its text alone cannot match: the user message
            // carries the original request as `retryRequest` (full detail
            // only), which the client returns as text + content.
            let inlinePrompt = "Third prompt " + token
            let inlineItems: JSONValue = [["type": "text", "text": .string("Inline note " + token)]]
            try await withLiveClient(fixture.connection) { client, frames in
                let head = try await api.conversation(id: conversationID).lastSequence
                _ = try await client.command(
                    type: "conversation.subscribe",
                    payload: ["conversationId": .string(conversationID), "afterSequence": .number(Double(head))],
                    timeout: 10)
                let third = try await client.command(
                    type: "conversation.prompt",
                    payload: [
                        "conversationId": .string(conversationID), "text": .string(inlinePrompt),
                        "content": inlineItems,
                    ], timeout: 10)
                let thirdTurn = try #require(third["turnId"].optionalString)
                _ = try await frames.wait {
                    $0["type"] == "conversation.event" && $0["payload"]["type"] == "turn.completed"
                        && $0["payload"]["payload"]["turnId"] == .string(thirdTurn)
                }
            }
            try await withLiveClient(fixture.connection) { client, frames in
                let summary = try await restReplay(api: api, keys: keys, conversationID: conversationID, detail: "summary")
                let full = try await restReplay(api: api, keys: keys, conversationID: conversationID, detail: "full")
                let isUserMessage = { (event: ConversationEvent) in
                    event.type == "message.created" && event.payload["role"] == "user"
                }
                let latestSummary = try #require(summary.map(\.plain).last(where: isUserMessage))
                #expect(latestSummary.payload["retryRequest"] == .null)
                let latestFull = try #require(full.map(\.plain).last(where: isUserMessage))
                let retryRequest = latestFull.payload["retryRequest"]
                #expect(retryRequest["text"] == .string(inlinePrompt))
                #expect(retryRequest["content"] == inlineItems)
                let target: JSONValue = ["conversationId": .string(conversationID)]
                var textOnly = target
                textOnly["prompt"] = .string(inlinePrompt)
                await expectServerError(["CONFLICT", "409"]) {
                    _ = try await client.command(type: "conversation.retry", payload: textOnly, timeout: 10)
                }
                var tampered = target
                tampered["text"] = retryRequest["text"]
                tampered["content"] = [["type": "text", "text": "Something else"]]
                await expectServerError(["CONFLICT", "409"]) {
                    _ = try await client.command(type: "conversation.retry", payload: tampered, timeout: 10)
                }
                _ = try await client.command(
                    type: "conversation.subscribe",
                    payload: [
                        "conversationId": .string(conversationID),
                        "afterSequence": .number(Double(full.last?.raw.sequence ?? 0)),
                    ],
                    timeout: 10)
                var retry = target
                retry["text"] = retryRequest["text"]
                retry["content"] = retryRequest["content"]
                let retried = try await client.command(type: "conversation.retry", payload: retry, timeout: 10)
                #expect(retried["retried"] == true)
                let turnID = try #require(retried["turnId"].optionalString)
                _ = try await frames.wait {
                    $0["type"] == "conversation.event" && $0["payload"]["type"] == "turn.completed"
                        && $0["payload"]["payload"]["turnId"] == .string(turnID)
                }
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

extension RealtimeLiveTests {
    /// Two devices (fixture `device.txt` = A, `device-b.txt` = B):
    /// B registers after A wrote history, so B's copy is locked; A fulfills
    /// B's grant and the `history.encryption.updated` push alone makes B's
    /// already loaded events decrypt (AppSession's path: unlock scope →
    /// `forgetUnavailable()` → decrypt the same raw events again, no reload).
    /// Then A revokes B (every history command but `get` is refused with
    /// `HISTORY_ACCESS_REVOKED`) and restores it, after which B registers a
    /// fresh key. Requires the backend's push/revocation support.
    @Test func actualGrantPushUnlocksAndDeviceRevocationIsPermanentUntilRestored() async throws {
        let fixture = try LiveFixture()
        let deviceB = try LiveFixture.secondDevice(fixture)
        let deviceBID = try #require(DeviceIdentity(secretKeyBase64URL: deviceB.deviceSecret)?.deviceID)
        let clientA = RealtimeClient(connection: fixture.connection)
        try await clientA.connect()
        let historyA = HistoryAPI(client: clientA)
        let wasEnabled = try await historyA.state().isEnabled
        let seedA = try HistoryCrypto.generateRecipientKey().seedRepresentation
        let keysA = try HistoryDecryptor(deviceSeed: seedA) { conversationId, kids, _ in
            try await historyA.wraps(conversationId: conversationId, kids: kids)
        }
        let token = "push-live-" + UUID().uuidString.lowercased()
        let prompt = "Granted prompt " + token
        do {
            _ = try await historyA.register(publicKey: keysA.devicePublicKey)
            if !wasEnabled { #expect(try await historyA.enable().isEnabled) }
            let conversationID = try await withLiveClient(fixture.connection) { client, frames in
                try await runTurn(client: client, frames: frames, fixture: fixture, prompt: prompt, title: "Push " + token)
                    .conversationID
            }

            try await withLiveClient(deviceB) { clientB, framesB in
                let historyB = HistoryAPI(client: clientB)
                // A previous failed run may have left B blocked.
                if try await historyB.state().isAccessRevoked { _ = try await historyA.restoreDevice(deviceBID) }
                let seedB = try HistoryCrypto.generateRecipientKey().seedRepresentation
                let keysB = try HistoryDecryptor(deviceSeed: seedB) { conversationId, kids, _ in
                    try await historyB.wraps(conversationId: conversationId, kids: kids)
                }
                let ridB = try await historyB.register(publicKey: keysB.devicePublicKey)
                #expect(ridB == HistoryEncryption.encodeID(keysB.deviceRecipientID))
                #expect(try await historyB.state().myAccess == "active")

                // B loads the conversation: written before B registered, so locked.
                let api = APIClient(connection: deviceB)
                let page = try await api.events(conversationId: conversationID, after: 0, limit: 200, detail: "full")
                let raw = try page["events"].arrayValue.map { try $0.decoded(ConversationEvent.self) }
                let before = try await keysB.decrypt(raw, frames: page["frames"])
                #expect(before.contains { HistoryEncryption.isLocked($0.payload) }, "B could read history before a grant")

                // B asks; A re-wraps for B (AppSession.authorizeHistoryGrant).
                let grantId = try await historyB.requestGrant()
                let grant = try #require(try await historyA.grants().first { $0.grantId == grantId })
                let target = try #require(grant.recipient)
                let progress = try await HistoryGrant.fulfill(
                    api: historyA, grantId: grantId, target: target,
                    source: HistoryCrypto.recipientKey(seed: seedA), sourceRid: nil)
                #expect(progress.finished && progress.processed > 0)

                // B learns it from the push, not by polling.
                let pushed = try await framesB.wait { frame in
                    guard let update = HistoryEncryptionUpdate(frame: frame) else { return false }
                    return update.unlockScope(forRecipient: ridB)?.contains(conversationID) == true
                }
                let update = try #require(HistoryEncryptionUpdate(frame: pushed))
                #expect([.grantProgress, .grantFulfilled].contains(update.reason))
                #expect(pushed["payload"].objectValue.keys.allSatisfy { !["wrapped", "key", "dek", "seed"].contains($0) })
                let fulfilled = try await framesB.wait {
                    HistoryEncryptionUpdate(frame: $0).map { $0.reason == .grantFulfilled && $0.rid == ridB } == true
                }
                #expect(HistoryEncryptionUpdate(frame: fulfilled)?.grantId == grantId)
                await keysB.forgetUnavailable()
                let after = try await keysB.decrypt(raw, frames: page["frames"])
                try checkPlaintext(after, contains: [prompt, "Fixture Codex: " + prompt], detail: "after grant push")

                // Revoking B's recipient blocks the device permanently.
                let revokedState = try await historyA.revoke(rid: ridB)
                #expect(revokedState.revokedDevices.contains { $0.deviceId == deviceBID })
                _ = try await framesB.wait {
                    HistoryEncryptionUpdate(frame: $0).map { [.recipientRevoked, .deviceRevoked].contains($0.reason) } == true
                }
                let blocked = try await historyB.state()
                #expect(blocked.myAccess == "revoked" && blocked.isAccessRevoked)
                let fresh = try HistoryCrypto.recipientKey(seed: HistoryCrypto.generateRecipientKey().seedRepresentation)
                await expectServerError([HistoryEncryption.accessRevoked, "403"]) {
                    _ = try await historyB.register(publicKey: fresh.publicKey.rawRepresentation)
                }
                await expectServerError([HistoryEncryption.accessRevoked, "403"]) { _ = try await historyB.requestGrant() }
                await expectServerError([HistoryEncryption.accessRevoked, "403"]) {
                    _ = try await historyB.keys(conversationId: conversationID)
                }

                // A restores B: B registers again, with a fresh key only.
                let restored = try await historyA.restoreDevice(deviceBID)
                #expect(!restored.revokedDevices.contains { $0.deviceId == deviceBID })
                _ = try await framesB.wait {
                    HistoryEncryptionUpdate(frame: $0).map { $0.reason == .deviceRestored && $0.deviceId == deviceBID } == true
                }
                #expect(try await historyB.state().myAccess != "revoked")
                await expectServerError(["CONFLICT", "409"]) {
                    _ = try await historyB.register(publicKey: keysB.devicePublicKey)
                }
                let newRid = try await historyB.register(publicKey: fresh.publicKey.rawRepresentation)
                let active = try await historyB.state()
                #expect(active.myAccess == "active" && active.myRid == newRid && newRid != ridB)
            }
        } catch {
            _ = try? await historyA.restoreDevice(deviceBID)
            if !wasEnabled { _ = try? await historyA.disable() }
            await clientA.disconnect()
            throw error
        }
        if !wasEnabled { #expect(try await historyA.disable().isEnabled == false) }
        await clientA.disconnect()
    }
}

extension LiveFixture {
    /// The second enrolled fixture device (`device-b.txt`, written by
    /// `backend_fixture.py start` since the multi-device history tests).
    static func secondDevice(_ fixture: LiveFixture) throws -> BackendConnection {
        let path = try #require(ProcessInfo.processInfo.environment["TODEX_LIVE_FIXTURE"])
        let file = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("device-b.txt")
        let secret = try #require(
            try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            "device-b.txt is missing: start a new fixture with scripts/backend_fixture.py")
        var connection = fixture.connection
        connection.id = UUID().uuidString
        connection.name = "Isolated live test B"
        connection.deviceSecret = secret
        return connection
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

/// A client whose upgrade omits `historyEncryption=1`, otherwise signed and
/// framed exactly like a real one (transport v2 when the fixture pins a key).
private func legacySocketClient(_ connection: BackendConnection) throws -> RealtimeClient {
    RealtimeClient(connection: connection, transport: PreHistoryTransport(base: BackendSecureTransport(connection: connection)))
}

private struct PreHistoryTransport: SecureTransport {
    let base: BackendSecureTransport
    var mode: SecureTransportMode { base.mode }
    func request(
        method: HTTPMethod, path: String, query: [String: String], headers: [String: String], body: Data?
    ) async throws -> SecureTransportResponse {
        try await base.request(method: method, path: path, query: query, headers: headers, body: body)
    }
    func openWebSocket(path: String, query: [String: String]) async throws -> any SecureWebSocket {
        try await base.openWebSocket(path: path, query: query.filter { $0.key != "historyEncryption" })
    }
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
