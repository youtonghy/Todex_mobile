import CryptoKit
import Foundation
import Testing

@testable import TodexCore

struct HistoryCryptoTests {
    @Test func vectorDerivesPublicKeyAndRecipientID() throws {
        let v = try historyVector()
        let privateKey = try HistoryCrypto.recipientKey(seed: hex(v["seed"]))
        #expect(privateKey.publicKey.rawRepresentation == (try hex(v["pk"])))
        let rid = try HistoryCrypto.recipientID(publicKey: privateKey.publicKey.rawRepresentation)
        #expect(rid == (try hex(v["rid"])))
        #expect(CryptoEncoding.encode(rid) == v["ridText"].stringValue)
    }

    @Test func vectorWrappedKeyUnwrapsAndReencodes() throws {
        let v = try historyVector()
        let wrapped = try JSONDecoder().decode(HistoryCrypto.WrappedKey.self, from: Data(v["wrap"]["json"].prettyPrinted.utf8))
        #expect(wrapped.kemCt == (try hex(v["wrap"]["kemCt"])))
        #expect(wrapped.wrapped == (try hex(v["wrap"]["wrapped"])))
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(wrapped)) == v["wrap"]["json"])
        let key = try vectorKey(v)
        #expect(key.kid == (try hex(v["kid"])))
        #expect(key.dek.withUnsafeBytes { Data($0) } == (try hex(v["dek"])))
    }

    @Test func vectorContentSealsByteForByte() throws {
        let v = try historyVector()
        let key = try vectorKey(v)
        let conversationID = v["conversationId"].stringValue
        let cases = v["content"].arrayValue
        #expect(cases.count == 4)
        for entry in cases {
            let stream = try #require(HistoryCrypto.ContentStream(rawValue: UInt32(entry["stream"].intValue)))
            let counter = try UInt64(#require(entry["counter"].doubleValue))
            let plaintext = try hex(entry["plaintext"])
            let sealed = try HistoryCrypto.seal(
                plaintext, key: key, conversationID: conversationID, stream: stream, counter: counter)
            #expect(sealed == (try hex(entry["ciphertext"])))
            let (nonce, aad) = try HistoryCrypto.contentParams(
                key: key, conversationID: conversationID, stream: stream, counter: counter)
            #expect(Data(nonce) == (try hex(entry["nonce"])))
            #expect(aad == (try hex(entry["aad"])))
            #expect(
                try HistoryCrypto.open(sealed, key: key, conversationID: conversationID, stream: stream, counter: counter)
                    == plaintext)
        }
    }

    @Test func randomKeysRoundTrip() throws {
        let recipient = try HistoryCrypto.generateRecipientKey()
        #expect(recipient.seedRepresentation.count == 32)
        let key = HistoryCrypto.SegmentKey.generate()
        let first = try HistoryCrypto.wrap(key, for: recipient.publicKey.rawRepresentation)
        let second = try HistoryCrypto.wrap(key, for: recipient.publicKey.rawRepresentation)
        #expect(first.kemCt != second.kemCt)
        let parsed = try JSONDecoder().decode(HistoryCrypto.WrappedKey.self, from: JSONEncoder().encode(first))
        #expect(parsed == first)
        let restored = try HistoryCrypto.recipientKey(seed: recipient.seedRepresentation)
        let unwrapped = try HistoryCrypto.unwrap(parsed, kid: key.kid, with: restored)
        #expect(unwrapped.dek == key.dek)
        let plaintext = Data("历史 🔐".utf8)
        let sealed = try HistoryCrypto.seal(plaintext, key: key, conversationID: "c", stream: .eventFull, counter: 7)
        #expect(sealed.count == plaintext.count + 16)
        #expect(try HistoryCrypto.open(sealed, key: unwrapped, conversationID: "c", stream: .eventFull, counter: 7) == plaintext)
        let max = try HistoryCrypto.seal(Data(), key: key, conversationID: "c", stream: .frameFull, counter: .max)
        #expect(try HistoryCrypto.open(max, key: key, conversationID: "c", stream: .frameFull, counter: .max).isEmpty)
    }

    @Test func tamperingWrongContextAndWrongRecipientFail() throws {
        let recipient = try HistoryCrypto.generateRecipientKey()
        let key = HistoryCrypto.SegmentKey.generate()
        let sealed = try HistoryCrypto.seal(Data([1, 2, 3]), key: key, conversationID: "c1", stream: .frameFull, counter: 3)
        var flipped = sealed
        flipped[0] ^= 1
        #expect(throws: TodexError.self) {
            try HistoryCrypto.open(flipped, key: key, conversationID: "c1", stream: .frameFull, counter: 3)
        }
        #expect(throws: TodexError.self) {
            try HistoryCrypto.open(sealed, key: key, conversationID: "c2", stream: .frameFull, counter: 3)
        }
        #expect(throws: TodexError.self) {
            try HistoryCrypto.open(sealed, key: key, conversationID: "c1", stream: .frameSummary, counter: 3)
        }
        #expect(throws: TodexError.self) {
            try HistoryCrypto.open(sealed, key: key, conversationID: "c1", stream: .frameFull, counter: 4)
        }
        #expect(throws: TodexError.self) {
            try HistoryCrypto.open(Data(count: 15), key: key, conversationID: "c1", stream: .frameFull, counter: 3)
        }
        let otherKey = try HistoryCrypto.SegmentKey(kid: key.kid, dek: SymmetricKey(size: .bits256))
        #expect(throws: TodexError.self) {
            try HistoryCrypto.open(sealed, key: otherKey, conversationID: "c1", stream: .frameFull, counter: 3)
        }

        let wrapped = try HistoryCrypto.wrap(key, for: recipient.publicKey.rawRepresentation)
        #expect(throws: TodexError.self) {
            try HistoryCrypto.unwrap(wrapped, kid: key.kid, with: HistoryCrypto.generateRecipientKey())
        }
        #expect(throws: TodexError.self) { try HistoryCrypto.unwrap(wrapped, kid: Data(count: 16), with: recipient) }
        var badWrap = wrapped.wrapped
        badWrap[0] ^= 1
        #expect(throws: TodexError.self) {
            try HistoryCrypto.unwrap(
                .init(rid: wrapped.rid, kemCt: wrapped.kemCt, wrapped: badWrap), kid: key.kid, with: recipient)
        }
        var badKem = wrapped.kemCt
        badKem[0] ^= 1
        #expect(throws: TodexError.self) {
            try HistoryCrypto.unwrap(
                .init(rid: wrapped.rid, kemCt: badKem, wrapped: wrapped.wrapped), kid: key.kid, with: recipient)
        }
    }

    @Test func inputsAreValidated() throws {
        #expect(HistoryCrypto.ContentStream(rawValue: 0) == nil)
        #expect(HistoryCrypto.ContentStream(rawValue: 5) == nil)
        #expect(HistoryCrypto.ContentStream.allCases.map(\.rawValue) == [1, 2, 3, 4])
        let key = HistoryCrypto.SegmentKey.generate()
        #expect(throws: TodexError.self) { try HistoryCrypto.wrap(key, for: Data(count: 1215)) }
        #expect(throws: TodexError.self) { try HistoryCrypto.wrap(key, for: Data(repeating: 0xff, count: 1216)) }
        #expect(throws: TodexError.self) { try HistoryCrypto.recipientKey(seed: Data(count: 31)) }
        #expect(throws: TodexError.self) { try HistoryCrypto.SegmentKey(kid: Data(count: 15), dek: SymmetricKey(size: .bits256)) }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HistoryCrypto.WrappedKey.self, from: Data(#"{"rid":"AA","kemCt":"AA","wrapped":"AA"}"#.utf8))
        }
    }
}

private func historyVector() throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "history-crypto-v1", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

private func vectorKey(_ v: JSONValue) throws -> HistoryCrypto.SegmentKey {
    let wrapped = try HistoryCrypto.WrappedKey(
        rid: hex(v["rid"]),
        kemCt: hex(v["wrap"]["kemCt"]), wrapped: hex(v["wrap"]["wrapped"]))
    return try HistoryCrypto.unwrap(wrapped, kid: hex(v["kid"]), with: HistoryCrypto.recipientKey(seed: hex(v["seed"])))
}

private func hex(_ value: JSONValue) throws -> Data { try hex(value.stringValue) }

private func hex(_ value: String) throws -> Data {
    let bytes = Array(value.utf8)
    guard bytes.count.isMultiple(of: 2) else { throw TodexError.invalid("odd hex length") }
    return try Data(
        stride(from: 0, to: bytes.count, by: 2).map { index in
            guard let byte = UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16) else {
                throw TodexError.invalid("invalid hex")
            }
            return byte
        })
}
