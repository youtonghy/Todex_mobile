import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import TodexCore

struct PairingTests {
    @Test func pairingV3MaterialMatchesVectorAndUnwrapsUnderTheFullTranscript() throws {
        let v = try fixture()
        let material = try fixtureMaterial()
        #expect(material.verificationCode == v["verificationCode"].stringValue)
        #expect(CryptoEncoding.encode(material.transcript) == v["transcript"].stringValue)
        #expect(encoded(material.wrapKey) == v["wrapKey"].stringValue)
        #expect(encoded(material.pollProof) == v["pollProof"].stringValue)
        #expect(encoded(material.cancelProof) == v["cancelProof"].stringValue)
        // The backend seals the credential with the full v3 transcript as AAD.
        let expected = PairingTransport(encryption: .mlkem768, publicKey: v["transportPublicKey"].stringValue)
        #expect(try material.unwrap(approvedFixture()) == expected)
        var shortAAD = try approvedFixture()
        shortAAD["ciphertext"] = .string(
            try CryptoEncoding.encode(
                XChaChaAEAD.seal(
                    credentialPlaintext(), key: material.wrapKey,
                    nonce: CryptoEncoding.decode(v["nonce"].stringValue), aad: material.transcript.dropLast(32))))
        #expect(throws: (any Error).self) { try material.unwrap(shortAAD) }
        // The transport is part of the transcript: another key changes the
        // code, so the operator sees the substitution.
        let tampered = try TodexCoreTests.material(transportPublicKey: v["tamperedTransportPublicKey"].stringValue)
        #expect(tampered.verificationCode == v["tamperedVerificationCode"].stringValue)
        #expect(tampered.verificationCode != material.verificationCode)
        #expect(throws: (any Error).self) { try tampered.unwrap(approvedFixture()) }
    }

    @Test func forgedEnrollmentAndTranscriptSubstitutionAreRejected() throws {
        let v = try approvedFixture()
        let original = try fixtureMaterial()
        var damaged = v
        var ciphertext = try CryptoEncoding.decode(v["ciphertext"].stringValue)
        ciphertext[ciphertext.count - 1] ^= 1
        damaged["ciphertext"] = .string(CryptoEncoding.encode(ciphertext))
        #expect(throws: (any Error).self) { try original.unwrap(damaged) }
        let wrongID = try material(requestID: "21111111-2222-4333-8444-555555555555")
        #expect(wrongID.verificationCode != original.verificationCode)
        #expect(throws: (any Error).self) { try wrongID.unwrap(v) }
        let wrongClient = try material(privateKey: .init())
        #expect(throws: (any Error).self) { try wrongClient.unwrap(v) }
        // The reveal binds the committed nonce; a different one changes the code and key.
        let wrongNonce = try material(clientNonce: Data(repeating: 7, count: 32))
        #expect(wrongNonce.verificationCode != original.verificationCode)
        #expect(throws: (any Error).self) { try wrongNonce.unwrap(v) }
        #expect(throws: (any Error).self) { try wrongClient.unwrap(v) }
        // A credential addressed to a different device key must not unwrap here.
        let otherDevice = try material(device: DeviceIdentity())
        #expect(throws: (any Error).self) { try otherDevice.unwrap(v) }
        for nonce in ["AA", v["nonce"].stringValue + "=", String(repeating: "A", count: 32)] {
            damaged = v
            damaged["nonce"] = .string(nonce)
            #expect(throws: (any Error).self) { try original.unwrap(damaged) }
        }
        #expect(throws: Never.self) { try original.unwrap(approval(plaintext: credentialPlaintext(extra: #","future":1"#))) }
        for deviceId: JSONValue in ["", "dev_wrong0000000000", .string(String(repeating: "a", count: 4097)), 42, nil] {
            let payload: JSONValue = [
                "deviceId": deviceId, "transportProtocol": (try fixture())["transportProtocol"],
                "transportPublicKey": (try fixture())["transportPublicKey"],
            ]
            damaged = try approval(plaintext: JSONEncoder().encode(payload))
            #expect(throws: (any Error).self) { try original.unwrap(damaged) }
        }
        let malformedUTF8 = try approval(plaintext: Data([0xff]))
        #expect(throws: (any Error).self) { try original.unwrap(malformedUTF8) }
    }

    @Test func credentialMustRepeatTheAnnouncedTransportExactly() throws {
        let material = try fixtureMaterial()
        let v = try fixture()
        let other = try MLKEM768.PrivateKey().publicKey.rawRepresentation
        let otherX25519 = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        for (transportProtocol, transportPublicKey): (JSONValue, JSONValue) in [
            ("x25519", v["transportPublicKey"]), ("none", ""), ("ml-kem-768", .string(CryptoEncoding.encode(other))),
            ("x25519", .string(CryptoEncoding.encode(otherX25519))), ("ml-kem-768", .string(v["transportPublicKey"].stringValue + "A")),
            (nil, v["transportPublicKey"]), ("ml-kem-768", nil), (42, v["transportPublicKey"]),
        ] {
            var payload: JSONValue = ["deviceId": v["deviceId"]]
            if transportProtocol != nil { payload["transportProtocol"] = transportProtocol }
            if transportPublicKey != nil { payload["transportPublicKey"] = transportPublicKey }
            let response = try approval(plaintext: JSONEncoder().encode(payload))
            #expect(throws: (any Error).self, "\(payload)") { try material.unwrap(response) }
        }
    }

    @Test func linksFillTheAddressOnlyAndIgnoreTransportFields() throws {
        let current = BackendConnection(
            id: "stable", name: "保留名称", serverURL: "HTTP://EXAMPLE.COM:7345/v2/", deviceSecret: "enrolled",
            encryption: .x25519, publicKey: "pinned", transportVerified: true, color: "purple")
        for version: JSONValue in [1, 2] {
            var payload = try link()
            payload["version"] = version
            let same = try PairingImporter.ingest(payload.prettyPrinted, current: current)
            // Same backend: the device key and verified pin survive; nothing
            // in the link (protocol, key, authToken) is read.
            #expect(same.serverURL == "http://example.com:7345")
            #expect(same.deviceSecret == "enrolled")
            #expect(same.encryption == .x25519 && same.publicKey == "pinned" && same.transportVerified)
            #expect(same.id == current.id && same.name == current.name && same.color == current.color)
        }
        var other = try link()
        other["serverUrl"] = "https://elsewhere.example"
        other["authToken"] = "stale-token"
        let moved = try PairingImporter.ingest(other.prettyPrinted, current: current)
        #expect(moved.serverURL == "https://elsewhere.example")
        #expect(moved.deviceSecret.isEmpty && moved.encryption == .none && moved.publicKey.isEmpty)
        #expect(!moved.transportVerified)
        // A remote address with no key is still importable: verification
        // pins the key next; until then the profile is refused.
        #expect(SecureTransportMode.resolve(moved) == .refused)
        let keyless = try PairingImporter.ingest(
            #"{"kind":"todex-pairing-link","version":2,"serverUrl":"http://127.0.0.1:7345"}"#, current: .init())
        #expect(keyless.serverURL == "http://127.0.0.1:7345" && keyless.encryption == .none)
    }

    @Test func malformedLinksAndRetiredChunksAreRejected() throws {
        let original = try link()
        var badLinks: [JSONValue] = [nil, true, [], "text"]
        for (field, value): (String, JSONValue) in [
            ("kind", "todex-pairing-chunk"), ("kind", "other"), ("version", 3), ("version", 0), ("version", "2"),
            ("serverUrl", nil), ("serverUrl", "file:///tmp"), ("serverUrl", "https://user:pass@example.com"),
            ("serverUrl", "https://example.com?token=leak"), ("serverUrl", "https://example.com/v1"),
        ] {
            var bad = original
            bad[field] = value
            badLinks.append(bad)
        }
        // The chunk format is gone; a chunk from an older backend is not a link.
        badLinks.append([
            "kind": "todex-pairing-chunk", "version": 1, "checksum": .string(CryptoEncoding.encode(Data(count: 32))),
            "index": 1, "total": 1, "data": "AAAA",
        ])
        for bad in badLinks {
            #expect(throws: (any Error).self, "\(bad)") { try PairingImporter.ingest(bad.prettyPrinted, current: .init()) }
        }
        #expect(throws: (any Error).self) {
            try PairingImporter.ingest(String(repeating: " ", count: 65_537), current: .init())
        }
    }

    @Test func createResponseTransportIsValidatedBeforeAnythingIsDerived() async throws {
        let zero = CryptoEncoding.encode(Data(count: 32))
        let x25519 = CryptoEncoding.encode(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        let mlkem = try CryptoEncoding.encode(MLKEM768.PrivateKey().publicKey.rawRepresentation)
        for (transportProtocol, transportPublicKey): (JSONValue, JSONValue) in [
            (nil, .string(mlkem)), ("ml-kem-768", nil), ("future", .string(mlkem)), (1, .string(mlkem)),
            ("x25519", .string(zero)), ("x25519", .string(mlkem)), ("x25519", .string(x25519 + "=")),
            ("ml-kem-768", .string(x25519)), ("ml-kem-768", .string(CryptoEncoding.encode(Data(repeating: 0xff, count: 1184)))),
            ("none", .string(x25519)), ("none", nil),
        ] {
            var response = try createFixture()
            response["transportProtocol"] = transportProtocol
            response["transportPublicKey"] = transportPublicKey
            let invalid = try PairingEndpoint(createResponse: response)
            await #expect(throws: (any Error).self, "\(transportProtocol) \(transportPublicKey)") {
                try await begin(invalid)
            }
            #expect(await invalid.calls.map(\.action) == ["create"])
        }
        // `none` is for loopback only: a remote server answering plaintext
        // asks for encryption instead of pinning nothing.
        var plaintext = try createFixture()
        plaintext["transportProtocol"] = "none"
        plaintext["transportPublicKey"] = ""
        let remote = try PairingEndpoint(createResponse: plaintext)
        do {
            _ = try await begin(remote, loopback: false)
            Issue.record("a remote plaintext pairing was accepted")
        } catch TodexError.configuration(let message) {
            #expect(message == SecureTransportError.encryptionRequired.localizedDescription)
        }
        let local = try PairingEndpoint(createResponse: plaintext)
        let session = try await begin(local, loopback: true)
        #expect(session.transport == PairingTransport(encryption: .none, publicKey: ""))
        #expect(session.transport.fingerprint == "none")
        #expect(session.verificationCode == (try fixture())["noneVerificationCode"].stringValue)
    }

    @Test func profilesPinOnlyThroughVerificationAndForgetPinsOnAnotherAddress() throws {
        // Saved by an older build: the key decodes unverified and is refused,
        // loopback included.
        let old = try JSONDecoder().decode(
            BackendConnection.self,
            from: Data(
                #"{"id":"a","name":"n","serverURL":"http://127.0.0.1:7345","encryption":"x25519","publicKey":"k"}"#.utf8))
        #expect(!old.transportVerified)
        #expect(SecureTransportMode.resolve(old) == .refused)
        let saved = try JSONDecoder().decode(
            BackendConnection.self, from: JSONEncoder().encode(BackendConnection(transportVerified: true)))
        #expect(saved.transportVerified)
        #expect(!BackendConnection().transportVerified)
        let transport = PairingTransport(encryption: .mlkem768, publicKey: (try fixture())["transportPublicKey"].stringValue)
        var profile = BackendConnection(serverURL: "https://lan.example:7345")
        profile.pin(transport, deviceSecret: "seed")
        #expect(profile.deviceSecret == "seed" && profile.encryption == .mlkem768 && profile.transportVerified)
        #expect(SecureTransportMode.resolve(profile) == .v2(.mlkem768))
        // The same origin spelled differently keeps everything.
        profile.setServerURL("HTTPS://LAN.EXAMPLE:7345/v2")
        #expect(profile.deviceSecret == "seed" && profile.publicKey == transport.publicKey && profile.transportVerified)
        profile.setServerURL("https://other.example:7345")
        #expect(profile.deviceSecret.isEmpty && profile.encryption == .none && profile.publicKey.isEmpty)
        #expect(!profile.transportVerified)
    }

    @Test func fingerprintGroupsTheFirstEightBytesOfTheKeyHash() throws {
        let v = try fixture()
        let transport = PairingTransport(encryption: .mlkem768, publicKey: v["transportPublicKey"].stringValue)
        #expect(transport.fingerprint == v["fingerprint"].stringValue)
        #expect(transport.fingerprint.range(of: "^[0-9A-F]{4}(-[0-9A-F]{4}){3}$", options: .regularExpression) != nil)
        #expect(PairingTransport.fingerprint(encryption: .x25519, publicKey: "not base64!") == nil)
        #expect(PairingTransport(encryption: .none, publicKey: "").fingerprint == "none")
    }

    @Test func enrollmentUsesCorrectProofsAndDeliversCredentialOnce() async throws {
        let endpoint = try PairingEndpoint(results: [["status": "pending"], approvedFixture()])
        let session = try await begin(endpoint, name: "  Mac\u{0000}\u{202E}测试  ")
        #expect(session.verificationCode == (try fixture())["verificationCode"].stringValue)
        #expect(session.expiresAt == 2_000_000_300_000)
        #expect(session.pollIntervalMilliseconds == 1000)
        #expect(session.transport.encryption == .mlkem768)
        #expect(try await session.poll() == .pending)
        #expect(try await session.poll() == .approved(session.transport))
        #expect(try await session.poll() == .expired)
        try await session.cancel()
        let calls = await endpoint.calls
        #expect(calls.map(\.action) == ["create", "reveal", "poll", "poll"])
        // Commit first: create carries only the commitment, never the key.
        #expect(calls[0].body["deviceName"] == "Mac测试")
        #expect(calls[0].body["clientCommitment"] == (try fixture())["commitment"])
        #expect(calls[0].body["devicePublicKey"] == (try fixture())["devicePublicKey"])
        #expect(calls[0].body["transportBinding"] == 1)
        #expect(calls[0].body.objectValue.count == 4)
        #expect(
            calls[1].body == [
                "requestId": (try fixture())["requestId"], "clientPublicKey": (try fixture())["clientPublicKey"],
                "clientNonce": (try fixture())["clientNonce"],
            ])
        #expect(calls[2].body["proof"] == (try fixture())["pollProof"])
        #expect(calls[2].body.objectValue.count == 2)
    }

    @Test(arguments: ["rejected", "expired"])
    func terminalStatesDisposeProofs(_ status: String) async throws {
        let endpoint = try PairingEndpoint(results: [["status": .string(status)]])
        let session = try await begin(endpoint)
        #expect(try await session.poll() == (status == "rejected" ? .rejected : .expired))
        #expect(try await session.poll() == .expired)
        try await session.cancel()
        #expect(await endpoint.calls.count == 3)
    }

    @Test func concurrentPollAndCancelDoNotReleaseAnApprovedCredential() async throws {
        let endpoint = try PairingEndpoint(holdPoll: true)
        let session = try await begin(endpoint)
        let polling = Task { try await session.poll() }
        await endpoint.waitForPoll()
        await #expect(throws: (any Error).self) { try await session.poll() }
        try await session.cancel()
        try await session.cancel()
        await endpoint.completePoll(try approvedFixture())
        #expect(try await polling.value == .expired)
        let calls = await endpoint.calls
        #expect(calls.map(\.action) == ["create", "reveal", "poll", "cancel"])
        #expect(calls.last?.body["proof"] == (try fixture())["cancelProof"])
    }

    @Test func expiryDuringPollDiscardsApproval() async throws {
        let endpoint = try PairingEndpoint(holdPoll: true)
        let clock = PairingTestClock(1_900_000_000_000)
        let session = try await begin(endpoint, clock: clock)
        let polling = Task { try await session.poll() }
        await endpoint.waitForPoll()
        clock.set(session.expiresAt)
        await endpoint.completePoll(try approvedFixture())
        #expect(try await polling.value == .expired)
        #expect(try await session.poll() == .expired)
        #expect(await endpoint.calls.count == 3)
    }

    @Test func failedApprovalIsTerminalAndInvalidCreationIsRejected() async throws {
        var forged = try approvedFixture()
        forged["ciphertext"] = "AA"
        let endpoint = try PairingEndpoint(results: [forged])
        let session = try await begin(endpoint)
        await #expect(throws: (any Error).self) { try await session.poll() }
        #expect(try await session.poll() == .expired)
        for (field, value): (String, JSONValue) in [
            ("requestId", "invalid"), ("requestId", "11111111-2222-1333-8444-555555555555"), ("expiresAt", 1),
            ("expiresAt", 2_000_000_300_000.5), ("pollIntervalMs", 0), ("pollIntervalMs", 1.5),
            ("pollIntervalMs", 60001),
            ("serverPublicKey", .string(CryptoEncoding.encode(Data(repeating: 0, count: 32)))),
        ] {
            var response = try createFixture()
            response[field] = value
            let invalid = try PairingEndpoint(createResponse: response)
            await #expect(throws: (any Error).self) { try await begin(invalid) }
            #expect(await invalid.calls.map(\.action) == ["create"])
        }
        // A reveal that does not answer pending is refused and withdrawn.
        let badReveal = try PairingEndpoint(revealResponse: ["status": "approved"])
        await #expect(throws: (any Error).self) { try await begin(badReveal) }
        await badReveal.waitForCalls(3)
        let calls = await badReveal.calls
        #expect(calls.map(\.action) == ["create", "reveal", "cancel"])
        #expect(calls.last?.body["proof"] == (try fixture())["cancelProof"])
        #expect(DevicePairingSession.sanitizedDeviceName(" \n\u{202E}") == "TodeX")
        #expect(DevicePairingSession.sanitizedDeviceName(String(repeating: "🦦", count: 100)).unicodeScalars.count == 80)
    }

    @Test func bootstrapIsUnauthenticatedBoundedAndDoesNotRetry() async throws {
        let recorder = PairingHTTPRecorder()
        let client = PairingURLProtocol.client { request in
            recorder.record(request)
            return (200, Data(#"{"status":"pending"}"#.utf8))
        }
        #expect(
            try await PairingBootstrap.post(
                client: client, action: "poll", body: ["requestId": "test", "proof": "synthetic"]) == [
                    "status": "pending"
                ])
        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/device-pairing/poll")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-todex-device-id") == nil)
        #expect(request.value(forHTTPHeaderField: "x-todex-transport") == nil)
        // The bootstrap client reaches nothing but the pairing routes, unsigned.
        await #expect(throws: TodexError.self) { _ = try await client.request(path: "/v2/version", authenticated: false) }
        await #expect(throws: TodexError.self) {
            _ = try await client.request(.post, path: "/v2/device-pairing/poll", body: [:], authenticated: true)
        }
        #expect(recorder.requests.count == 1)
        for (status, data) in [
            (401, Data("{}".utf8)), (429, Data("{}".utf8)), (200, Data("[]".utf8)),
            (
                200,
                Data(
                    #"{"large":"PLACEHOLDER"}"#.replacingOccurrences(
                        of: "PLACEHOLDER", with: String(repeating: "x", count: 16_385)
                    ).utf8)
            ),
        ] {
            let failed = PairingHTTPRecorder()
            let client = PairingURLProtocol.client { request in
                failed.record(request)
                return (status, data)
            }
            await #expect(throws: (any Error).self) {
                try await PairingBootstrap.post(client: client, action: "create", body: [:])
            }
            #expect(failed.requests.count == 1)
        }
        let stalled = PairingHTTPRecorder()
        let timeoutClient = PairingURLProtocol.client { request in
            stalled.record(request)
            return nil
        }
        await #expect(throws: (any Error).self) {
            try await PairingBootstrap.post(
                client: timeoutClient, action: "poll", body: [:], timeout: .milliseconds(30))
        }
        #expect(stalled.requests.count == 1)
    }

    @Test(arguments: [
        (404, "", "create", "当前后端不支持设备验证，请更新后端。"),
        (404, #"{"code":"NOT_FOUND","message":"pairing request no longer exists"}"#, "poll", "设备验证申请无效或已过期，请重新申请"),
        (429, #"{"code":"RESOURCE_EXHAUSTED","message":"queue full"}"#, "create", "设备申请过于频繁或队列已满，请稍后重试"),
        (401, "{}", "poll", "设备验证请求未被接受，请重新申请"),
        (403, #"{"code":"UNAUTHORIZED","message":"denied"}"#, "create", "设备验证请求未被接受，请重新申请"),
        (502, "", "create", "设备验证失败（HTTP %@），请检查后端状态"),
        (400, #"{"code":"INVALID_REQUEST","message":"bad key"}"#, "create", "bad key"),
    ])
    func bootstrapHTTPFailuresAreActionable(_ status: Int, _ body: String, _ action: String, _ expected: String)
        async throws
    {
        let client = PairingURLProtocol.client { _ in (status, Data(body.utf8)) }
        do {
            _ = try await PairingBootstrap.post(client: client, action: action, body: [:])
            Issue.record("expected HTTP \(status) to fail")
        } catch {
            // Expected text is a catalog key (server messages pass through).
            let format = String(localized: String.LocalizationValue(expected), bundle: CoreLocalization.bundle)
            #expect(error.localizedDescription == (expected.contains("%@") ? String(format: format, String(status)) : format))
        }
    }

    /// A version 1 link as older backends emitted it: the protocol fields
    /// must be ignored.
    private func link() throws -> JSONValue {
        [
            "kind": "todex-pairing-link", "version": 1, "serverUrl": "http://example.com:7345",
            "preferredEncryption": "x25519",
            "protocol": ["id": "x25519", "publicKey": try fixture()["serverPublicKey"]],
        ]
    }

    private func begin(
        _ endpoint: PairingEndpoint, name: String = "Swift client", loopback: Bool = false,
        clock: PairingTestClock = .init(1_900_000_000_000)
    ) async throws -> DevicePairingSession {
        try await DevicePairingSession.begin(
            deviceName: name, device: fixtureDevice(), loopback: loopback, privateKey: fixturePrivateKey(),
            clientNonce: CryptoEncoding.decode((try fixture())["clientNonce"].stringValue), post: { action, body in try await endpoint.post(action, body) }, now: { clock.now })
    }
}

/// Device pairing v3 vector from TodeX_protocol's transport-v2.json (the
/// backend asserts the same values), re-encoded as base64url like the wire.
private func fixture() throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "transport-v2", withExtension: "json", subdirectory: "Fixtures"))
    let v = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))["pairingV3"]
    func b64(_ name: String) throws -> JSONValue { .string(CryptoEncoding.encode(try hexBytes(v[name]))) }
    let device = try #require(DeviceIdentity(secretKeyBase64URL: CryptoEncoding.encode(try hexBytes(v["deviceSeed"]))))
    return [
        "requestId": v["requestId"], "expiresAt": 2_000_000_300_000, "clientSecret": try b64("clientSecretKey"),
        "clientPublicKey": try b64("clientPublicKey"), "serverPublicKey": try b64("serverPublicKey"),
        "deviceSecret": try b64("deviceSeed"), "devicePublicKey": try b64("devicePublicKey"),
        "deviceId": .string(device.deviceID), "clientNonce": try b64("clientNonce"),
        "commitment": v["commitmentBase64Url"], "transcript": try b64("transcript"),
        "verificationCode": v["verificationCode"], "wrapKey": try b64("wrapKey"), "pollProof": try b64("pollProof"),
        "cancelProof": try b64("cancelProof"), "nonce": .string(CryptoEncoding.encode(Data(repeating: 0x0b, count: 24))),
        "transportProtocol": v["transportProtocol"], "transportPublicKey": v["transportPublicKey"],
        "fingerprint": v["fingerprint"], "tamperedTransportPublicKey": v["tampered"]["transportPublicKey"],
        "tamperedVerificationCode": v["tampered"]["verificationCode"],
        "noneVerificationCode": v["noneCase"]["verificationCode"],
    ]
}
private func hexBytes(_ value: JSONValue) throws -> Data {
    let text = Array(value.stringValue.utf8)
    try #require(text.count % 2 == 0)
    return Data(
        try stride(from: 0, to: text.count, by: 2).map { index in
            try #require(UInt8(String(decoding: text[index..<index + 2], as: UTF8.self), radix: 16))
        })
}
private func fixturePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
    try .init(rawRepresentation: CryptoEncoding.decode(fixture()["clientSecret"].stringValue))
}
private func material(
    requestID: String? = nil, privateKey: Curve25519.KeyAgreement.PrivateKey? = nil, device: DeviceIdentity? = nil,
    clientNonce: Data? = nil, transportPublicKey: String? = nil
) throws -> PairingMaterial {
    let v = try fixture()
    let (transport, key) = try PairingTransport.validated(
        protocol: v["transportProtocol"].stringValue,
        publicKey: transportPublicKey ?? v["transportPublicKey"].stringValue, loopback: false)
    return try PairingMaterial(
        v3RequestID: requestID ?? v["requestId"].stringValue, privateKey: privateKey ?? fixturePrivateKey(),
        serverPublicKey: CryptoEncoding.decode(v["serverPublicKey"].stringValue), device: device ?? fixtureDevice(),
        clientNonce: clientNonce ?? CryptoEncoding.decode(v["clientNonce"].stringValue), transport: transport,
        transportKey: key)
}
private func fixtureMaterial() throws -> PairingMaterial { try material() }
private func fixtureDevice() throws -> DeviceIdentity {
    try #require(DeviceIdentity(secretKeyBase64URL: fixture()["deviceSecret"].stringValue))
}
private func encoded(_ key: SymmetricKey) -> String { key.withUnsafeBytes { CryptoEncoding.encode(Data($0)) } }
private func createFixture() throws -> JSONValue {
    let v = try fixture()
    return [
        "requestId": v["requestId"], "serverPublicKey": v["serverPublicKey"], "expiresAt": v["expiresAt"],
        "pollIntervalMs": 1000, "transportProtocol": v["transportProtocol"], "transportPublicKey": v["transportPublicKey"],
    ]
}
/// What the backend's poll returns once approved: the device credential
/// sealed under the v3 wrap key with the full transcript as AAD.
private func approvedFixture() throws -> JSONValue {
    try approval(plaintext: credentialPlaintext())
}
/// The credential in the backend's field order; extra fields are ignored.
private func credentialPlaintext(extra: String = "") throws -> Data {
    let v = try fixture()
    return Data(
        #"{"deviceId":"\#(v["deviceId"].stringValue)","transportProtocol":"\#(v["transportProtocol"].stringValue)","transportPublicKey":"\#(v["transportPublicKey"].stringValue)"\#(extra)}"#
            .utf8)
}
private func approval(plaintext: Data) throws -> JSONValue {
    let v = try fixture()
    let material = try fixtureMaterial()
    return [
        "status": "approved", "expiresAt": v["expiresAt"], "nonce": v["nonce"],
        "ciphertext": .string(
            try CryptoEncoding.encode(
                XChaChaAEAD.seal(
                    plaintext, key: material.wrapKey, nonce: CryptoEncoding.decode(v["nonce"].stringValue),
                    aad: material.transcript))),
    ]
}

private actor PairingEndpoint {
    struct Call: Sendable {
        let action: String
        let body: JSONValue
    }
    private(set) var calls: [Call] = []
    private let createResponse: JSONValue
    private let revealResponse: JSONValue
    private var results: [JSONValue]
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private let holdPoll: Bool
    private var pollContinuation: CheckedContinuation<JSONValue, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    init(
        createResponse: JSONValue? = nil, revealResponse: JSONValue = ["status": "pending"], results: [JSONValue] = [],
        holdPoll: Bool = false
    ) throws {
        self.createResponse = try createResponse ?? createFixture()
        self.revealResponse = revealResponse
        self.results = results
        self.holdPoll = holdPoll
    }
    func post(_ action: String, _ body: JSONValue) async throws -> JSONValue {
        calls.append(Call(action: action, body: body))
        let ready = callWaiters.filter { $0.0 <= calls.count }
        callWaiters.removeAll { $0.0 <= calls.count }
        for waiter in ready { waiter.1.resume() }
        if action == "create" { return createResponse }
        if action == "reveal" { return revealResponse }
        if action == "cancel" { return ["status": "expired"] }
        if holdPoll {
            return await withCheckedContinuation {
                pollContinuation = $0
                startedContinuation?.resume()
                startedContinuation = nil
            }
        }
        guard !results.isEmpty else { throw TodexError.invalid("Unexpected extra poll") }
        return results.removeFirst()
    }
    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }
    func waitForPoll() async {
        if pollContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func completePoll(_ result: JSONValue) {
        pollContinuation?.resume(returning: result)
        pollContinuation = nil
    }
}

private final class PairingTestClock: Sendable {
    private let value: Mutex<Double>
    init(_ now: Double) { value = Mutex(now) }
    var now: Double { value.withLock { $0 } }
    func set(_ now: Double) { value.withLock { $0 = now } }
}

private final class PairingHTTPRecorder: Sendable {
    private let storage = Mutex<[URLRequest]>([])
    var requests: [URLRequest] { storage.withLock { $0 } }
    func record(_ request: URLRequest) { storage.withLock { $0.append(request) } }
}

// URLProtocol inherits unchecked sendability from Foundation. All shared test
// handlers are protected by Mutex; no mutable transport/session state is shared.
private final class PairingURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)?
    private static let handlers = Mutex<[String: Handler]>([:])
    static func client(_ handler: @escaping Handler) -> HTTPClient {
        let host = UUID().uuidString.lowercased() + ".invalid"
        handlers.withLock { $0[host] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        config.urlCache = nil
        config.httpCookieStorage = nil
        // Pinned and remote on purpose: pairing still goes direct and unsigned.
        return HTTPClient.pairingBootstrap(
            connection: .init(
                serverURL: "https://\(host)", deviceSecret: "must-not-be-sent", encryption: .x25519,
                publicKey: "V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE"),
            session: URLSession(configuration: config))
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let host = request.url?.host, let handler = Self.handlers.withLock({ $0[host] }) else {
                throw URLError(.badURL)
            }
            guard let (status, data) = try handler(request) else { return }
            guard let url = request.url,
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
            else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
