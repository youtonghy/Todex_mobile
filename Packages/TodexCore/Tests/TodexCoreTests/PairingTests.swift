import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import TodexCore

struct PairingTests {
    @Test func backendDevicePairingFixtureMatchesEveryDerivedValue() throws {
        let v = try fixture()
        let material = try fixtureMaterial()
        #expect(material.verificationCode == v["verificationCode"].stringValue)
        #expect(CryptoEncoding.encode(material.transcript) == v["transcript"].stringValue)
        #expect(encoded(material.wrapKey) == v["wrapKey"].stringValue)
        #expect(encoded(material.pollProof) == v["pollProof"].stringValue)
        #expect(encoded(material.cancelProof) == v["cancelProof"].stringValue)
        #expect(try material.unwrap(v) == v["authToken"].stringValue)
        let plaintext = Data(#"{"authToken":"synthetic-device-pairing-token"}"#.utf8)
        #expect(
            try CryptoEncoding.encode(
                XChaChaAEAD.seal(
                    plaintext, key: material.wrapKey, nonce: CryptoEncoding.decode(v["nonce"].stringValue),
                    aad: material.transcript)) == v["ciphertext"].stringValue)
    }

    @Test func forgedEnrollmentAndTranscriptSubstitutionAreRejected() throws {
        let v = try fixture()
        let original = try fixtureMaterial()
        var damaged = v
        var ciphertext = try CryptoEncoding.decode(v["ciphertext"].stringValue)
        ciphertext[ciphertext.count - 1] ^= 1
        damaged["ciphertext"] = .string(CryptoEncoding.encode(ciphertext))
        #expect(throws: (any Error).self) { try original.unwrap(damaged) }
        let wrongID = try PairingMaterial(
            requestID: "21111111-2222-4333-8444-555555555555", privateKey: fixturePrivateKey(),
            serverPublicKey: CryptoEncoding.decode(v["serverPublicKey"].stringValue))
        #expect(wrongID.verificationCode != original.verificationCode)
        #expect(throws: (any Error).self) { try wrongID.unwrap(v) }
        let wrongClient = try PairingMaterial(
            requestID: v["requestId"].stringValue, privateKey: .init(),
            serverPublicKey: CryptoEncoding.decode(v["serverPublicKey"].stringValue))
        #expect(throws: (any Error).self) { try wrongClient.unwrap(v) }
        for nonce in ["AA", v["nonce"].stringValue + "=", String(repeating: "A", count: 32)] {
            damaged = v
            damaged["nonce"] = .string(nonce)
            #expect(throws: (any Error).self) { try original.unwrap(damaged) }
        }
        for token: JSONValue in ["", "bad\r\nheader", .string(String(repeating: "a", count: 4097)), 42, nil] {
            let payload: JSONValue = ["authToken": token]
            damaged = try approval(plaintext: JSONEncoder().encode(payload))
            #expect(throws: (any Error).self) { try original.unwrap(damaged) }
        }
        let malformedUTF8 = try approval(plaintext: Data([0xff]))
        #expect(throws: (any Error).self) { try original.unwrap(malformedUTF8) }
    }

    @Test func importsPreserveOnlyCredentialsForTheSameBackend() throws {
        var importer = PairingImporter()
        let current = BackendConnection(
            id: "stable", name: "保留名称", serverURL: "HTTP://EXAMPLE.COM:7345/v2/", token: "enrolled", color: "purple")
        let imported = try importer.ingest(link().prettyPrinted, current: current)
        let same = try #require(imported)
        #expect(same.token == "enrolled")
        #expect(same.serverURL == "http://example.com:7345")
        #expect(same.id == current.id && same.name == current.name && same.color == current.color)
        #expect(same.encryption == .x25519)
        var other = try link()
        other["serverUrl"] = "https://elsewhere.example"
        #expect(try importer.ingest(other.prettyPrinted, current: current)?.token == "")
        other["authToken"] = "new-token"
        #expect(try importer.ingest(other.prettyPrinted, current: current)?.token == "new-token")
        var noEncryption = try link()
        noEncryption["preferredEncryption"] = "none"
        noEncryption["protocol"] = nil
        let importedNone = try importer.ingest(noEncryption.prettyPrinted, current: same)
        let none = try #require(importedNone)
        #expect(none.encryption == .none && none.publicKey.isEmpty && none.token == "enrolled")
        noEncryption["authToken"] = ""
        #expect(try importer.ingest(noEncryption.prettyPrinted, current: same)?.token == "enrolled")
    }

    @Test func mlkemQRFragmentsSupportUnorderedRepeatedScans() throws {
        let key = try MLKEM768.PrivateKey().publicKey.rawRepresentation
        var payload = try link()
        payload["preferredEncryption"] = "ml-kem-768"
        payload["protocol"] = ["id": "ml-kem-768", "publicKey": .string(CryptoEncoding.encode(key))]
        let fragments = try chunks(payload)
        #expect(fragments.count > 10)
        var importer = PairingImporter()
        let current = BackendConnection()
        #expect(try importer.ingest(fragments.last!.prettyPrinted, current: current) == nil)
        #expect(try importer.ingest(fragments.last!.prettyPrinted, current: current) == nil)
        #expect(importer.receivedCount == 1 && importer.totalCount == fragments.count)
        var completed: BackendConnection?
        for frame in fragments.dropLast().reversed() {
            completed = try importer.ingest(frame.prettyPrinted, current: current)
        }
        #expect(completed?.encryption == .mlkem768)
        #expect(completed?.publicKey == CryptoEncoding.encode(key))
        #expect(importer.receivedCount == 0 && importer.totalCount == 0)
    }

    @Test func invalidAndConflictingChunksDoNotDestroyProgress() throws {
        let frames = try chunks(link())
        var importer = PairingImporter()
        let current = BackendConnection()
        #expect(try importer.ingest(frames[0].prettyPrinted, current: current) == nil)
        var bad = frames[0]
        bad["data"] = .string(String(repeating: "A", count: 160))
        #expect(throws: (any Error).self) { try importer.ingest(bad.prettyPrinted, current: current) }
        bad = frames[1]
        bad["checksum"] = .string(CryptoEncoding.encode(Data(repeating: 1, count: 32)))
        #expect(throws: (any Error).self) { try importer.ingest(bad.prettyPrinted, current: current) }
        bad = frames[1]
        bad["total"] = .number(Double(frames.count + 1))
        #expect(throws: (any Error).self) { try importer.ingest(bad.prettyPrinted, current: current) }
        for index: JSONValue in [0, -1, 1.5, 999, true] {
            bad = frames[1]
            bad["index"] = index
            #expect(throws: (any Error).self) { try importer.ingest(bad.prettyPrinted, current: current) }
        }
        #expect(importer.receivedCount == 1 && importer.totalCount == frames.count)
        for frame in frames.dropFirst().dropLast() { _ = try importer.ingest(frame.prettyPrinted, current: current) }
        bad = frames.last!
        bad["data"] = .string(String(repeating: "A", count: bad["data"].stringValue.count))
        #expect(throws: (any Error).self) { try importer.ingest(bad.prettyPrinted, current: current) }
        #expect(importer.receivedCount == frames.count - 1)
        #expect(try importer.ingest(frames.last!.prettyPrinted, current: current) != nil)
    }

    @Test func malformedLinksAreRejectedWithoutDowngrade() throws {
        var importer = PairingImporter()
        let original = try link()
        var badLinks: [JSONValue] = [nil, true, []]
        for (field, value): (String, JSONValue) in [
            ("kind", "other"), ("version", 2), ("serverUrl", "file:///tmp"),
            ("serverUrl", "https://user:pass@example.com"), ("serverUrl", "https://example.com?token=leak"),
            ("serverUrl", "https://example.com/v1"), ("preferredEncryption", "unknown"), ("authToken", "bad\nheader"),
            ("protocol", nil), ("protocol", ["id": "ml-kem-768", "publicKey": "AA"]),
        ] {
            var bad = original
            bad[field] = value
            badLinks.append(bad)
        }
        for bad in badLinks {
            #expect(throws: (any Error).self) { try importer.ingest(bad.prettyPrinted, current: .init()) }
        }
        #expect(throws: (any Error).self) {
            try importer.ingest(String(repeating: " ", count: 65_537), current: .init())
        }
    }

    @Test func enrollmentUsesCorrectProofsAndDeliversCredentialOnce() async throws {
        let endpoint = try PairingEndpoint(results: [["status": "pending"], approvedFixture()])
        let session = try await begin(endpoint, name: "  Mac\u{0000}\u{202E}测试  ")
        #expect(session.verificationCode == "254BE-020DC")
        #expect(session.expiresAt == 2_000_000_300_000)
        #expect(session.pollIntervalMilliseconds == 1000)
        #expect(try await session.poll() == .pending)
        #expect(try await session.poll() == .approved("synthetic-device-pairing-token"))
        #expect(try await session.poll() == .expired)
        try await session.cancel()
        let calls = await endpoint.calls
        #expect(calls.map(\.action) == ["create", "poll", "poll"])
        #expect(calls[0].body["deviceName"] == "Mac测试")
        #expect(calls[0].body["clientPublicKey"] == (try fixture())["clientPublicKey"])
        #expect(calls[1].body["proof"] == (try fixture())["pollProof"])
        #expect(calls[1].body.objectValue.count == 2)
    }

    @Test(arguments: ["rejected", "expired"])
    func terminalStatesDisposeProofs(_ status: String) async throws {
        let endpoint = try PairingEndpoint(results: [["status": .string(status)]])
        let session = try await begin(endpoint)
        #expect(try await session.poll() == (status == "rejected" ? .rejected : .expired))
        #expect(try await session.poll() == .expired)
        try await session.cancel()
        #expect(await endpoint.calls.count == 2)
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
        #expect(calls.map(\.action) == ["create", "poll", "cancel"])
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
        #expect(await endpoint.calls.count == 2)
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
        }
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

    private func link() throws -> JSONValue {
        [
            "kind": "todex-pairing-link", "version": 1, "serverUrl": "http://example.com:7345",
            "preferredEncryption": "x25519",
            "protocol": ["id": "x25519", "publicKey": try fixture()["serverPublicKey"]],
        ]
    }

    private func chunks(_ payload: JSONValue) throws -> [JSONValue] {
        // Exactly the backend's UTF-8 -> unpadded base64url -> 160-byte chunks.
        let raw = try JSONEncoder().encode(payload)
        let encoded = Array(CryptoEncoding.encode(raw).utf8)
        let checksum = CryptoEncoding.encode(Data(SHA256.hash(data: raw)))
        let total = (encoded.count + 159) / 160
        return (0..<total).map { index in
            [
                "kind": "todex-pairing-chunk", "version": 1, "checksum": .string(checksum),
                "index": .number(Double(index + 1)), "total": .number(Double(total)),
                "data": .string(
                    String(decoding: encoded[(index * 160)..<min((index + 1) * 160, encoded.count)], as: UTF8.self)),
            ]
        }
    }

    private func begin(
        _ endpoint: PairingEndpoint, name: String = "Swift client", clock: PairingTestClock = .init(1_900_000_000_000)
    ) async throws -> DevicePairingSession {
        try await DevicePairingSession.begin(
            deviceName: name, privateKey: fixturePrivateKey(),
            post: { action, body in try await endpoint.post(action, body) }, now: { clock.now })
    }
}

private func fixture() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(devicePairingFixtureJSON.utf8))
}
private func fixturePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
    try .init(rawRepresentation: CryptoEncoding.decode(fixture()["clientSecret"].stringValue))
}
private func fixtureMaterial() throws -> PairingMaterial {
    try PairingMaterial(
        requestID: fixture()["requestId"].stringValue, privateKey: fixturePrivateKey(),
        serverPublicKey: CryptoEncoding.decode(fixture()["serverPublicKey"].stringValue))
}
private func encoded(_ key: SymmetricKey) -> String { key.withUnsafeBytes { CryptoEncoding.encode(Data($0)) } }
private func createFixture() throws -> JSONValue {
    let v = try fixture()
    return [
        "requestId": v["requestId"], "serverPublicKey": v["serverPublicKey"], "expiresAt": v["expiresAt"],
        "pollIntervalMs": 1000,
    ]
}
private func approvedFixture() throws -> JSONValue {
    let v = try fixture()
    return ["status": "approved", "expiresAt": v["expiresAt"], "nonce": v["nonce"], "ciphertext": v["ciphertext"]]
}
private func approval(plaintext: Data) throws -> JSONValue {
    let material = try fixtureMaterial()
    var result = try approvedFixture()
    result["ciphertext"] = .string(
        try CryptoEncoding.encode(
            XChaChaAEAD.seal(
                plaintext, key: material.wrapKey, nonce: CryptoEncoding.decode(fixture()["nonce"].stringValue),
                aad: material.transcript)))
    return result
}

private actor PairingEndpoint {
    struct Call: Sendable {
        let action: String
        let body: JSONValue
    }
    private(set) var calls: [Call] = []
    private let createResponse: JSONValue
    private var results: [JSONValue]
    private let holdPoll: Bool
    private var pollContinuation: CheckedContinuation<JSONValue, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    init(createResponse: JSONValue? = nil, results: [JSONValue] = [], holdPoll: Bool = false) throws {
        self.createResponse = try createResponse ?? createFixture()
        self.results = results
        self.holdPoll = holdPoll
    }
    func post(_ action: String, _ body: JSONValue) async throws -> JSONValue {
        calls.append(Call(action: action, body: body))
        if action == "create" { return createResponse }
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
        return HTTPClient(
            connection: .init(serverURL: "https://\(host)", token: "must-not-be-sent"),
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

// Verbatim backend tests/fixtures/device-pairing-v1.json. Only synthetic keys
// and credentials, asserted byte-for-byte by backend device_pairing.rs tests.
private let devicePairingFixtureJSON = #"""
    {
      "requestId": "11111111-2222-4333-8444-555555555555",
      "expiresAt": 2000000300000,
      "clientSecret": "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc",
      "serverSecret": "CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk",
      "clientPublicKey": "E75P6uryBMf9M1j8nAByGIHRdCeBKCJ-xnTzf3_pe20",
      "serverPublicKey": "V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE",
      "transcript": "dG9kZXguZGV2aWNlLXBhaXJpbmcudjEvdHJhbnNjcmlwdAAxMTExMTExMS0yMjIyLTQzMzMtODQ0NC01NTU1NTU1NTU1NTUAE75P6uryBMf9M1j8nAByGIHRdCeBKCJ-xnTzf3_pe21X20s1nyOuXhRuTiUSBWcEciUGNIwVDBR1PQyTPQTUIQ",
      "verificationCode": "254BE-020DC",
      "wrapKey": "uP92FjLJ_vfM8zw--x4j6kXG7OvXEls_aOhFSQfEOiI",
      "pollProof": "fY8bZQ51Yf0x0CQS6uvZiZy5oxBOMFiwHKom7sMsDwk",
      "cancelProof": "S4C76skr7KGcP8rIPyEoPX47HQnFx0jGHbBYg4yRNbk",
      "nonce": "CwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsL",
      "authToken": "synthetic-device-pairing-token",
      "ciphertext": "-Rlk4G9hSYSwJsNUrWbyPyAjeYgSoK6K38UULgs3P14WbNjQJ8-0Vo2LOzNYoqpWfz7PhiQkBhOvDhkJSrU"
    }
    """#
