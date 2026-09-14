import Foundation
import Synchronization
import Testing

@testable import TodexCore

/// Opt in with TODEX_LIVE_FIXTURE=/absolute/path/to/fixture.json.
/// Only scripts/backend_fixture.py's isolated loopback fixture is accepted.
/// Reads the enrolled fixture device seed from sibling device.txt without logging it.
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["TODEX_LIVE_FIXTURE"] != nil,
        "Set TODEX_LIVE_FIXTURE to run against an isolated Rust backend"))
struct RealtimeLiveTests {
    @Test func actualFoundationSocketPolicyPingAuthAndSeededReplay() async throws {
        let fixture = try LiveFixture()
        let http = HTTPClient(connection: fixture.connection)
        let policy = try await http.request(path: "/v2/transport-policy", authenticated: false)
        #expect(policy["requiredProtocol"] == "none")

        for invalidSecret in ["", "not-a-valid-device-seed"] {
            var connection = fixture.connection
            connection.deviceSecret = invalidSecret
            let rejected = RealtimeClient(connection: connection)
            do {
                try await rejected.connect()
                Issue.record("Rust backend accepted missing or incorrect WebSocket authentication")
            } catch TodexError.server(let code, _) {
                #expect(["401", "403", "UNAUTHORIZED"].contains(code))
            } catch {
                Issue.record("WebSocket authentication failure lost its HTTP status: \(error)")
            }
            await rejected.disconnect()
        }

        let existing = try await http.request(path: "/v2/conversations/\(fixture.conversationID)")
        let cursor = max(0, existing["lastSequence"].intValue - 2)
        try await withLiveClient(fixture.connection) { client, frames in
            let pingID = UUID().uuidString
            #expect(
                try await client.command(type: "server.ping", payload: [:], timeout: 5, id: pingID) == ["pong": true])
            let ping = try await frames.wait { $0["id"] == .string(pingID) }
            #expect(ping["type"] == "server.result")
            #expect(frames.snapshot.contains { $0["type"] == "connection.ready" })
            let events = try await checkReplay(
                client: client, frames: frames, conversationID: fixture.conversationID, after: cursor)
            #expect(!events.isEmpty)
        }
    }

    @Test(arguments: ["codex", "claude-code"])
    func actualSwiftPromptPermissionCompletionAndReconnect(_ provider: String) async throws {
        let fixture = try LiveFixture()
        let conversationID = try await withLiveClient(fixture.connection) { client, frames in
            let created = try await client.command(
                type: "conversation.create",
                payload: [
                    "provider": .string(provider), "workspace": .string(fixture.workspace),
                    "title": .string("Swift WebSocket fixture \(provider) \(UUID().uuidString.prefix(8))"),
                ], timeout: 10)
            let conversationID = try #require(created["id"].optionalString)
            do {
                _ = try await checkReplay(client: client, frames: frames, conversationID: conversationID, after: 0)
                let requestID = UUID().uuidString
                let result = try await client.command(
                    type: "conversation.prompt",
                    payload: [
                        "conversationId": .string(conversationID),
                        "text": "fixture:permission Swift socket integration",
                    ], timeout: 10, id: requestID)
                let turnID = try #require(result["turnId"].optionalString)
                #expect(result["conversationId"] == .string(conversationID))
                let confirmation = try await frames.wait { $0["id"] == .string(requestID) }
                #expect(confirmation["type"] == "server.result")
                #expect(confirmation["payload"] == result)
                let started = try await frames.event(conversationID, "turn.started", turnID: turnID)
                #expect(started["payload"]["clientRequestId"] == .string(requestID))
                let userMessage = try await frames.event(conversationID, "message.created", turnID: turnID)
                #expect(userMessage["payload"]["clientRequestId"] == .string(requestID))
                #expect(userMessage["payload"]["role"] == "user")
                let permission = try await frames.event(conversationID, "permission.requested", turnID: turnID)
                let permissionID = try #require(permission["payload"]["permissionId"].optionalString)
                let accepted = try await client.command(
                    type: "conversation.permission.respond",
                    payload: [
                        "conversationId": .string(conversationID), "permissionId": .string(permissionID),
                        "decision": ["outcome": "allow_once"],
                    ], timeout: 10)
                #expect(accepted["accepted"] == true)
                #expect(accepted["permissionId"] == .string(permissionID))
                let resolved = try await frames.event(conversationID, "permission.resolved", turnID: turnID)
                #expect(resolved["payload"]["outcome"] == "allow_once")
                let delta = try await frames.event(conversationID, "message.delta", turnID: turnID)
                let text = delta["payload"]["delta"].optionalString ?? delta["payload"]["delta"]["text"].stringValue
                #expect(text.contains(provider == "codex" ? "permission:accept" : "permission:allow"))
                let completed = try await frames.event(conversationID, "turn.completed", turnID: turnID)
                #expect(completed["sequence"].intValue > permission["sequence"].intValue)
                return conversationID
            } catch {
                // A failed assertion must not leave a fake provider awaiting approval.
                _ = try? await client.command(
                    type: "conversation.cancel", payload: ["conversationId": .string(conversationID)], timeout: 3)
                throw error
            }
        }
        // A new Foundation socket receives durable replay, with one event per
        // backend page. No in-memory events from the old client can satisfy this.
        try await withLiveClient(fixture.connection) { client, frames in
            let replay = try await checkReplay(client: client, frames: frames, conversationID: conversationID, after: 0)
            #expect(replay.contains { $0["type"] == "permission.resolved" })
            #expect(replay.contains { $0["type"] == "turn.completed" })
            #expect(Set(replay.map { $0["eventId"].stringValue }).count == replay.count)
        }
    }
}

private struct LiveFixture: Sendable {
    let connection: BackendConnection
    let workspace: String
    let conversationID: String
    init() throws {
        let path = try #require(ProcessInfo.processInfo.environment["TODEX_LIVE_FIXTURE"])
        let url = URL(fileURLWithPath: path)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        try #require(
            manifest["kind"] == "todex-mobile-isolated-fixture-v1",
            "Live mutations require the isolated fixture manifest")
        let serverURL = try #require(manifest["url"].optionalString)
        let components = try #require(URLComponents(string: serverURL))
        try #require(components.host == "127.0.0.1" && components.scheme == "http" && components.port != nil)
        let deviceSecret = try String(
            contentsOf: url.deletingLastPathComponent().appendingPathComponent("device.txt"), encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!deviceSecret.isEmpty, "Fixture device secret is empty")
        connection = BackendConnection(name: "Isolated live test", serverURL: serverURL, deviceSecret: deviceSecret)
        workspace = try #require(manifest["workspace"].optionalString)
        conversationID = try #require(manifest["conversationId"].optionalString)
    }
}

private func withLiveClient<T: Sendable>(
    _ connection: BackendConnection,
    operation: @Sendable (RealtimeClient, LiveFrames) async throws -> T
) async throws -> T {
    let client = RealtimeClient(connection: connection)
    let frames = LiveFrames()
    let consumer = Task { for await frame in client.events { frames.append(frame) } }
    do {
        try await client.connect()
        let result = try await operation(client, frames)
        await client.disconnect()
        consumer.cancel()
        await consumer.value
        return result
    } catch {
        await client.disconnect()
        consumer.cancel()
        await consumer.value
        throw error
    }
}

private func checkReplay(client: RealtimeClient, frames: LiveFrames, conversationID: String, after: Int) async throws
    -> [JSONValue]
{
    let requestID = UUID().uuidString
    let response = try await client.command(
        type: "conversation.subscribe",
        payload: [
            "conversationId": .string(conversationID), "afterSequence": .number(Double(after)), "limit": 1,
        ], timeout: 10, id: requestID)
    #expect(response["subscribed"] == true)
    _ = try await frames.wait { $0["id"] == .string(requestID) }
    let beforeAck = frames.snapshot.prefix { $0["id"] != .string(requestID) }
    let events = beforeAck.filter {
        $0["type"] == "conversation.event" && $0["payload"]["conversationId"] == .string(conversationID)
    }.map { $0["payload"] }
    let highWater = response["nextSequence"].intValue
    try #require(highWater >= after)
    #expect(events.map { $0["sequence"].intValue } == Array((after + 1)..<(highWater + 1)))
    return events
}

private final class LiveFrames: Sendable {
    private let frames = Mutex<[JSONValue]>([])
    var snapshot: [JSONValue] { frames.withLock { $0 } }
    func append(_ frame: JSONValue) { frames.withLock { $0.append(frame) } }
    func wait(_ predicate: @Sendable (JSONValue) -> Bool) async throws -> JSONValue {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let frame = snapshot.first(where: predicate) { return frame }
            if let closed = snapshot.first(where: { $0["type"] == "connection.closed" }) {
                throw TodexError.invalid("Live socket closed: \(closed["payload"]["message"].stringValue)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TodexError.invalid("Timed out waiting for a live fixture event")
    }
    func event(_ conversationID: String, _ type: String, turnID: String) async throws -> JSONValue {
        let frame = try await wait {
            $0["type"] == "conversation.event" && $0["payload"]["conversationId"] == .string(conversationID)
                && $0["payload"]["type"] == .string(type) && $0["payload"]["payload"]["turnId"] == .string(turnID)
        }
        return frame["payload"]
    }
}
