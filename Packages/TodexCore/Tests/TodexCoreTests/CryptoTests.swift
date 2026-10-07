import CryptoKit
import Foundation
import Testing

@testable import TodexCore

/// Shared primitives under transport v2, pairing and history encryption.
/// Protocol vectors live in TransportV2Tests (transport-v2.json).
struct CryptoTests {
    @Test func base64URLIsCanonicalAndUnpadded() throws {
        let bytes = Data((0..<40).map(UInt8.init))
        #expect(try CryptoEncoding.decode(CryptoEncoding.encode(bytes), count: 40) == bytes)
        #expect(throws: (any Error).self) { try CryptoEncoding.decode(CryptoEncoding.encode(bytes), count: 39) }
        for value in ["", "!", "A", "AB", "AA=", "AA==", "A A", "+w", "/w", "AA\n"] {
            #expect(throws: (any Error).self) { try CryptoEncoding.decode(value) }
        }
    }

    @Test func x25519RejectsLowOrderAndMalformedPublicKeys() throws {
        var lowOrder = Data(repeating: 0, count: 32)
        #expect(throws: (any Error).self) { try CryptoEncoding.sharedSecret(privateKey: .init(), publicKey: lowOrder) }
        lowOrder[0] = 1
        #expect(throws: (any Error).self) { try CryptoEncoding.sharedSecret(privateKey: .init(), publicKey: lowOrder) }
        #expect(throws: (any Error).self) {
            try CryptoEncoding.sharedSecret(privateKey: .init(), publicKey: Data(repeating: 9, count: 31))
        }
        let peer = Curve25519.KeyAgreement.PrivateKey()
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let shared = try CryptoEncoding.sharedSecret(privateKey: mine, publicKey: peer.publicKey.rawRepresentation)
        let other = try CryptoEncoding.sharedSecret(privateKey: peer, publicKey: mine.publicKey.rawRepresentation)
        #expect(shared == other)
    }

    @Test func xchachaAuthenticatesCiphertextNonceAndAAD() throws {
        let key = SymmetricKey(size: .bits256)
        let nonce = Data(repeating: 3, count: 24)
        let aad = Data("aad".utf8)
        let sealed = try XChaChaAEAD.seal(Data("message".utf8), key: key, nonce: nonce, aad: aad)
        #expect(sealed.count == 7 + 16)
        #expect(try XChaChaAEAD.open(sealed, key: key, nonce: nonce, aad: aad) == Data("message".utf8))
        var flipped = sealed
        flipped[0] ^= 1
        #expect(throws: (any Error).self) { try XChaChaAEAD.open(flipped, key: key, nonce: nonce, aad: aad) }
        #expect(throws: (any Error).self) { try XChaChaAEAD.open(sealed, key: key, nonce: nonce, aad: Data()) }
        #expect(throws: (any Error).self) {
            try XChaChaAEAD.open(sealed, key: key, nonce: Data(repeating: 4, count: 24), aad: aad)
        }
        #expect(throws: (any Error).self) { try XChaChaAEAD.seal(Data(), key: key, nonce: Data(count: 12), aad: aad) }
    }
}
