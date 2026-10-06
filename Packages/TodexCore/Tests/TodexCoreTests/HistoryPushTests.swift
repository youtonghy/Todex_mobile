import Foundation
import Synchronization
import Testing

@testable import TodexCore

/// `history.encryption.updated` pushes, permanent device revocation and the
/// decryptor reset a grant push triggers.
struct HistoryPushTests {
    @Test func parsesTheGlobalUpdatePush() throws {
        let frame: JSONValue = [
            "eventId": "evt_9", "type": "history.encryption.updated",
            "payload": [
                "epoch": 7, "mode": "e2e", "reason": "grant.progress", "rid": "rid-b", "grantId": "grt_1",
                "conversationIds": ["c1", "c2", "", 3],
            ],
        ]
        let update = try #require(HistoryEncryptionUpdate(frame: frame))
        #expect(update.eventId == "evt_9")
        #expect(update.epoch == 7 && update.mode == "e2e")
        #expect(update.reason == .grantProgress)
        #expect(update.rid == "rid-b" && update.grantId == "grt_1" && update.deviceId == nil)
        #expect(update.conversationIds == ["c1", "c2"])

        let revoked = try #require(
            HistoryEncryptionUpdate(frame: [
                "type": "history.encryption.updated",
                "payload": ["epoch": 8, "mode": "e2e", "reason": "device.revoked", "deviceId": "dev_b"],
            ]))
        #expect(revoked.reason == .deviceRevoked && revoked.deviceId == "dev_b" && revoked.conversationIds == nil)
        // A reason added later still parses: clients re-read the state.
        #expect(HistoryEncryptionUpdate(frame: ["type": "history.encryption.updated", "payload": ["reason": "x.y"]])?.reason == .other("x.y"))
        // A conversation event or a payload-less frame is not this push.
        #expect(HistoryEncryptionUpdate(frame: ["type": "conversation.event", "payload": ["reason": "mode"]]) == nil)
        #expect(HistoryEncryptionUpdate(frame: ["type": "history.encryption.updated"]) == nil)
        for (raw, reason) in [
            ("mode", HistoryEncryptionUpdate.Reason.mode), ("recipient.registered", .recipientRegistered),
            ("recipient.revoked", .recipientRevoked), ("device.restored", .deviceRestored),
            ("device.revoked", .deviceRevoked), ("recovery.set", .recoverySet), ("grant.requested", .grantRequested),
            ("grant.dismissed", .grantDismissed), ("grant.progress", .grantProgress), ("grant.fulfilled", .grantFulfilled),
        ] {
            #expect(HistoryEncryptionUpdate.Reason(raw) == reason)
        }
    }

    @Test func onlyGrantsForThisRecipientUnlock() throws {
        func update(_ reason: String, rid: String?, ids: [String]? = nil) throws -> HistoryEncryptionUpdate {
            var payload: JSONValue = ["epoch": 1, "mode": "e2e", "reason": .string(reason)]
            if let rid { payload["rid"] = .string(rid) }
            if let ids { payload["conversationIds"] = .array(ids.map { .string($0) }) }
            return try #require(HistoryEncryptionUpdate(frame: ["type": "history.encryption.updated", "payload": payload]))
        }
        #expect(try update("grant.progress", rid: "me", ids: ["c1"]).unlockScope(forRecipient: "me") == .conversations(["c1"]))
        // Unlisted conversations: every loaded encrypted one is retried.
        #expect(try update("grant.progress", rid: "me").unlockScope(forRecipient: "me") == .all)
        #expect(try update("grant.fulfilled", rid: "me", ids: []).unlockScope(forRecipient: "me") == .all)
        #expect(try update("grant.fulfilled", rid: "other").unlockScope(forRecipient: "me") == nil)
        #expect(try update("grant.progress", rid: nil).unlockScope(forRecipient: "me") == nil)
        for reason in ["grant.requested", "recipient.registered", "device.restored", "mode"] {
            #expect(try update(reason, rid: "me").unlockScope(forRecipient: "me") == nil)
        }
        let scope = HistoryEncryptionUpdate.UnlockScope.conversations(["a"])
        #expect(scope.merged(.conversations(["b"])) == .conversations(["a", "b"]))
        #expect(scope.merged(.all) == .all && HistoryEncryptionUpdate.UnlockScope.all.merged(scope) == .all)
        #expect(scope.contains("a") && !scope.contains("b") && HistoryEncryptionUpdate.UnlockScope.all.contains("z"))
    }

    @Test func stateCarriesAccessAndRevokedDevices() async throws {
        let sent = Mutex<[(String, JSONValue)]>([])
        let api = HistoryAPI { type, payload in
            sent.withLock { $0.append((type, payload)) }
            return [
                "mode": "e2e", "epoch": 4, "myAccess": "revoked",
                "revokedDevices": [["deviceId": "dev_b", "revokedAt": "2026-10-06T00:00:00Z"]],
            ]
        }
        let state = try await api.state()
        #expect(state.isAccessRevoked && state.myAccess == "revoked")
        #expect(state.revokedDevices == [HistoryRevokedDevice(deviceId: "dev_b", revokedAt: "2026-10-06T00:00:00Z")])
        _ = try await api.restoreDevice("dev_b")
        #expect(sent.withLock { $0.last?.0 } == "history.device.restore")
        #expect(sent.withLock { $0.last?.1 } == ["deviceId": "dev_b"])
        // Backends before permanent revocation omit both fields.
        let old = try (["mode": "off"] as JSONValue).decoded(HistoryEncryptionState.self)
        #expect(old.myAccess == nil && !old.isAccessRevoked && old.revokedDevices.isEmpty)
        #expect(ProtocolCatalog.descriptor(type: "history.device.restore")?.support == .conditional)
    }

    @Test func revokedAccessReadsAsALocalizedNotice() {
        let error = TodexError.server(code: HistoryEncryption.accessRevoked, message: "raw")
        #expect(error.localizedDescription != "raw" && !error.localizedDescription.isEmpty)
        // A revoked history key is not a revoked connection: keep reconnecting.
        #expect(!TodexError.stopsReconnect(error))
    }

    /// A grant push arrives while an earlier lookup (answered before the new
    /// wraps existed) is still in flight: its miss must not stick, or the
    /// re-decrypt the push triggers would stay locked for 60 s.
    @Test(.timeLimit(.minutes(1))) func forgettingDuringAnInFlightLookupRetriesWithTheNewWraps() async throws {
        let fixture = try HistoryBackendFixture()
        let lookup = WrapLookup()
        let firstCall = PushGate(), releaseFirst = PushGate()
        let calls = Mutex(0)
        let decryptor = try HistoryDecryptor(deviceSeed: fixture.deviceSeed) { conversation, kids, rid in
            let call = calls.withLock { $0 += 1; return $0 }
            // The first lookup has read "no wraps" and is slow to come back.
            let answer = try await lookup.fetch(conversation, kids, rid)
            if call == 1 {
                await firstCall.open()
                await releaseFirst.wait()
            }
            return answer
        }
        let event = try fixture.event(1, payload: HistoryBackendFixture.payload("granted"))
        let stale = Task { try await decryptor.decrypt([event]) }
        await firstCall.wait()
        // The grant lands and its push resets the cache while that lookup is open.
        lookup.add(try fixture.wrap(for: fixture.devicePublicKey), kid: fixture.key.kid)
        await decryptor.forgetUnavailable()
        // A new decrypt does not join the stale lookup.
        let fresh = try await decryptor.decrypt([event])
        #expect(fresh[0].payload == HistoryBackendFixture.payload("granted"))
        await releaseFirst.open()
        // The earlier caller finishes with the key the fresh lookup cached.
        #expect(try await stale.value[0].payload == HistoryBackendFixture.payload("granted"))
        // The stale miss was not recorded: the key stays usable.
        #expect(try await decryptor.decrypt([event])[0].payload == HistoryBackendFixture.payload("granted"))
        #expect(calls.withLock { $0 } == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aStaleMissIsNotRememberedAfterForgetting() async throws {
        let fixture = try HistoryBackendFixture()
        let lookup = WrapLookup()
        let entered = PushGate(), release = PushGate()
        let decryptor = try HistoryDecryptor(deviceSeed: fixture.deviceSeed) { conversation, kids, rid in
            let answer = try await lookup.fetch(conversation, kids, rid)
            await entered.open()
            await release.wait()
            return answer
        }
        let event = try fixture.event(1, payload: HistoryBackendFixture.payload("later"))
        let stale = Task { try await decryptor.decrypt([event]) }
        await entered.wait()
        await decryptor.forgetUnavailable()
        await release.open()
        _ = try await stale.value
        lookup.add(try fixture.wrap(for: fixture.devicePublicKey), kid: fixture.key.kid)
        // Without the generation check this lookup would be skipped for 60 s.
        #expect(try await decryptor.decrypt([event])[0].payload == HistoryBackendFixture.payload("later"))
        #expect(lookup.calls.count == 2)
    }
}

/// A one-shot latch for ordering concurrent test steps.
private actor PushGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
