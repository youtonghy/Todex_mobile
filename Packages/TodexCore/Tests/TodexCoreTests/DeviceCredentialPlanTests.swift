import Foundation
import Testing

@testable import TodexCore

struct DeviceCredentialPlanTests {
    private typealias Write = DeviceCredentialPlan.Write

    private func profile(_ id: String, _ url: String = "https://lan.example:7345", secret: String = "") -> BackendConnection {
        BackendConnection(id: id, name: id, serverURL: url, deviceSecret: secret)
    }

    @Test func unreadableSecretIsNeverWrittenBackOnARename() {
        // Launched while locked: the Keychain answered errSecInteractionNotAllowed.
        let current = [profile("a"), profile("b", secret: "seed-b")]
        var renamed = current
        renamed[0].name = "renamed"
        let plan = DeviceCredentialPlan(saving: renamed, current: current, unreadable: ["a"])
        #expect(plan.writes == [Write(id: "b", secret: "seed-b")])
        #expect(plan.unreadable == ["a"])
        #expect(plan.connections.map(\.name) == ["renamed", "b"])
    }

    @Test func onlyRemovalOrANewAddressDeletesASecret() {
        let current = [profile("a"), profile("b", secret: "seed-b"), profile("c", secret: "seed-c")]
        // "a" (unreadable) points at another backend now; "c" is removed.
        let saving = [profile("a", "https://other.example"), profile("b", secret: "seed-b")]
        let plan = DeviceCredentialPlan(saving: saving, current: current, unreadable: ["a"])
        #expect(plan.writes == [Write(id: "a", secret: ""), Write(id: "b", secret: "seed-b"), Write(id: "c", secret: "")])
        #expect(plan.unreadable.isEmpty)

        let removed = DeviceCredentialPlan(saving: [], current: [profile("a")], unreadable: ["a"])
        #expect(removed.writes == [Write(id: "a", secret: "")])
        #expect(removed.unreadable.isEmpty)
    }

    @Test func aNewSecretReplacesAnUnreadableOne() {
        let plan = DeviceCredentialPlan(
            saving: [profile("a", secret: "fresh")], current: [profile("a")], unreadable: ["a"])
        #expect(plan.writes == [Write(id: "a", secret: "fresh")])
        #expect(plan.unreadable.isEmpty)
    }

    @Test func staleCopyOfAnUnchangedProfileKeepsTheSecret() {
        // Settings still holds the copy from before the secret was recovered.
        let current = [profile("a", secret: "seed-a")]
        let stale = [profile("a", "https://LAN.example:7345/")]
        let plan = DeviceCredentialPlan(saving: stale, current: current, unreadable: [])
        #expect(plan.connections.first?.deviceSecret == "seed-a")
        #expect(plan.writes == [Write(id: "a", secret: "seed-a")])

        // A changed address is a different backend: the secret goes.
        let moved = DeviceCredentialPlan(
            saving: [profile("a", "https://other.example")], current: current, unreadable: [])
        #expect(moved.connections.first?.deviceSecret == "")
        #expect(moved.writes == [Write(id: "a", secret: "")])
    }

    @Test func newProfilesWriteWhatTheyCarry() {
        let plan = DeviceCredentialPlan(
            saving: [profile("a"), profile("b", secret: "seed-b")], current: [], unreadable: [])
        #expect(plan.writes == [Write(id: "a", secret: ""), Write(id: "b", secret: "seed-b")])
    }
}
