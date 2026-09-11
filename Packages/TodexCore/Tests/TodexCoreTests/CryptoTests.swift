import CryptoKit
import Foundation
import Testing

@testable import TodexCore

struct CryptoTests {
    @Test func x25519MatchesRustTransportVector() throws {
        let v = try transportVectors()["x25519"]
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: CryptoEncoding.decode(v["clientSecret"].stringValue))
        let material = try TransportKeyMaterial.x25519(
            serverPublicKey: CryptoEncoding.decode(v["serverPublicKey"].stringValue), privateKey: privateKey)
        #expect(
            material.headers == [
                "x-todex-encryption": "x25519", "x-todex-client-key": v["clientPublicKey"].stringValue,
            ])
        #expect(material.key.withUnsafeBytes { CryptoEncoding.encode(Data($0)) } == v["key"].stringValue)
        let session = TransportCryptoSession(encryption: .x25519, key: material.key)
        #expect(try json(session.encrypt(#"{"type":"ping"}"#)) == v["clientFrame"])
        #expect(try session.decrypt(v["serverFrame"].prettyPrinted) == #"{"type":"pong"}"#)
        #expect(try session.decrypt(v["secondServerFrame"].prettyPrinted) == "第二帧 🦦")
        #expect(throws: (any Error).self) { try session.decrypt(v["serverFrame"].prettyPrinted) }
    }

    @Test func mlkemMatchesRustDecapsulationAndTransportVector() throws {
        let v = try transportVectors()["mlkem768"]
        let privateKey = try MLKEM768.PrivateKey(
            seedRepresentation: CryptoEncoding.decode(v["seed"].stringValue), publicKey: nil)
        #expect(CryptoEncoding.encode(privateKey.publicKey.rawRepresentation) == v["publicKey"].stringValue)
        let ciphertext = try CryptoEncoding.decode(v["ciphertext"].stringValue)
        let shared = try privateKey.decapsulate(ciphertext)
        #expect(shared.withUnsafeBytes { CryptoEncoding.encode(Data($0)) } == v["sharedSecret"].stringValue)
        let key = CryptoEncoding.derive(
            ikm: shared, salt: privateKey.publicKey.rawRepresentation + ciphertext, info: "ml-kem-768")
        #expect(key.withUnsafeBytes { CryptoEncoding.encode(Data($0)) } == v["key"].stringValue)
        let session = TransportCryptoSession(encryption: .mlkem768, key: key)
        #expect(try json(session.encrypt(#"{"type":"ping"}"#)) == v["clientFrame"])
        #expect(try session.decrypt(v["serverFrame"].prettyPrinted) == #"{"type":"pong"}"#)
        #expect(try session.decrypt(v["secondServerFrame"].prettyPrinted) == "第二帧 🦦")
    }

    @Test(arguments: [EncryptionProtocol.x25519, .mlkem768])
    func eachConnectionHasFreshHandshakeAndInteroperableClientFrames(_ encryption: EncryptionProtocol) throws {
        let xKey = Curve25519.KeyAgreement.PrivateKey()
        let kemKey = try MLKEM768.PrivateKey()
        let publicKey = encryption == .x25519 ? xKey.publicKey.rawRepresentation : kemKey.publicKey.rawRepresentation
        let connection = BackendConnection(encryption: encryption, publicKey: CryptoEncoding.encode(publicKey))
        let first = try TransportCryptoSession(connection: connection)
        let second = try TransportCryptoSession(connection: connection)
        #expect(first.handshakeHeaders != second.handshakeHeaders)
        #expect(first.handshakeHeaders.count == 2)
        #expect(first.handshakeHeaders["x-todex-encryption"] == encryption.rawValue)
        let shared: SymmetricKey
        let salt: Data
        if encryption == .x25519 {
            let clientPublic = try CryptoEncoding.decode(
                #require(first.handshakeHeaders["x-todex-client-key"]), count: 32)
            shared = try xKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: clientPublic)).withUnsafeBytes
            { SymmetricKey(data: $0) }
            salt = publicKey + clientPublic
        } else {
            let ciphertext = try CryptoEncoding.decode(
                #require(first.handshakeHeaders["x-todex-kem-ciphertext"]), count: 1088)
            shared = try kemKey.decapsulate(ciphertext)
            salt = publicKey + ciphertext
        }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: shared, salt: salt, info: Data(encryption.rawValue.utf8), outputByteCount: 32)
        for plaintext in ["", "中文 🦦", #"{"id":"check","type":"server.ping","payload":{}}"#] {
            let frame = try json(first.encrypt(plaintext))
            let nonce = try CryptoEncoding.decode(frame["nonce"].stringValue)
            #expect(nonce[0] == 2)
            #expect(
                try XChaChaAEAD.open(
                    CryptoEncoding.decode(frame["ciphertext"].stringValue), key: key, nonce: nonce,
                    aad: Data("todex-ws-transport-crypto-v1".utf8)) == Data(plaintext.utf8))
        }
        let serverFrame = try makeFrame(key: key, encryption: encryption)
        #expect(try first.decrypt(serverFrame) == "message")
        #expect(throws: (any Error).self) { try second.decrypt(serverFrame) }
    }

    @Test func forgedFramesNeverAdvanceReceiveCounter() throws {
        let v = try transportVectors()["x25519"]
        let key = SymmetricKey(data: try CryptoEncoding.decode(v["key"].stringValue))
        let valid = v["serverFrame"]
        var frames: [String] = [
            "null", "{}", "not JSON", v["secondServerFrame"].prettyPrinted, v["clientFrame"].prettyPrinted,
        ]
        for (field, value) in [
            ("type", "wrong"), ("protocol", "ml-kem-768"), ("nonce", ""), ("nonce", valid["nonce"].stringValue + "="),
            ("ciphertext", "AA"), ("ciphertext", valid["ciphertext"].stringValue + "="),
        ] {
            var altered = valid
            altered[field] = .string(value)
            frames.append(altered.prettyPrinted)
        }
        for byte in [1, 7, 16, 23] {
            var nonce = TransportCryptoSession.nonce(direction: 1, counter: 0)
            nonce[byte] = 1
            frames.append(try makeFrame(key: key, nonce: nonce))
        }
        var corrupt = try CryptoEncoding.decode(valid["ciphertext"].stringValue)
        corrupt[0] ^= 1
        var altered = valid
        altered["ciphertext"] = .string(CryptoEncoding.encode(corrupt))
        frames.append(altered.prettyPrinted)
        frames.append(try makeFrame(key: key, aad: Data("wrong AAD".utf8)))
        for frame in frames {
            let session = TransportCryptoSession(encryption: .x25519, key: key)
            #expect(throws: (any Error).self) { try session.decrypt(frame) }
            #expect(try session.decrypt(valid.prettyPrinted) == #"{"type":"pong"}"#)
        }
    }

    @Test func counterEndianExhaustionAndAuthenticatedUTF8Failure() throws {
        let key = SymmetricKey(data: Data(repeating: 42, count: 32))
        let sender = TransportCryptoSession(encryption: .x25519, key: key, sendCounter: 0x0807_0605_0403_0201)
        let nonce = try CryptoEncoding.decode(json(sender.encrypt("hello"))["nonce"].stringValue)
        #expect(Array(nonce) == [2, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0, 0, 0, 0, 0])
        let exhausted = TransportCryptoSession(encryption: .x25519, key: key, sendCounter: .max, receiveCounter: .max)
        #expect(throws: (any Error).self) { try exhausted.encrypt("blocked") }
        #expect(throws: (any Error).self) { try exhausted.decrypt(makeFrame(key: key, counter: .max)) }
        let boundary = TransportCryptoSession(
            encryption: .x25519, key: key, sendCounter: .max - 1, receiveCounter: .max - 1)
        _ = try boundary.encrypt("last")
        #expect(throws: (any Error).self) { try boundary.encrypt("overflow") }
        #expect(try boundary.decrypt(makeFrame(key: key, counter: .max - 1)) == "message")
        #expect(throws: (any Error).self) { try boundary.decrypt(makeFrame(key: key, counter: .max)) }
        let receiver = TransportCryptoSession(encryption: .x25519, key: key)
        let invalidUTF8 = try makeFrame(key: key, plaintext: Data([0xff]))
        #expect(throws: (any Error).self) { try receiver.decrypt(invalidUTF8) }
        #expect(throws: (any Error).self) { try receiver.decrypt(makeFrame(key: key)) }
        #expect(try receiver.decrypt(makeFrame(key: key, counter: 1)) == "message")
    }

    @Test func invalidKeysAndNoncanonicalEncodingAreRejected() throws {
        for encryption in [EncryptionProtocol.none, .x25519, .mlkem768] {
            for key in ["", "!", "AA", CryptoEncoding.encode(Data(repeating: 0, count: 32))] {
                #expect(throws: (any Error).self) {
                    try TransportCryptoSession(connection: .init(encryption: encryption, publicKey: key))
                }
            }
        }
        var lowOrder = Data(repeating: 0, count: 32)
        lowOrder[0] = 1
        #expect(throws: (any Error).self) {
            try TransportCryptoSession(
                connection: .init(encryption: .x25519, publicKey: CryptoEncoding.encode(lowOrder)))
        }
        for value in ["A", "AB", "AA=", "AA==", "A A", "+w", "/w", "AA\n"] {
            #expect(throws: (any Error).self) { try CryptoEncoding.decode(value) }
        }
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func makeFrame(
        key: SymmetricKey, encryption: EncryptionProtocol = .x25519, counter: UInt64 = 0, nonce: Data? = nil,
        plaintext: Data = Data("message".utf8), aad: Data = TransportCryptoSession.aad
    ) throws -> String {
        let nonce = nonce ?? TransportCryptoSession.nonce(direction: 1, counter: counter)
        let ciphertext = try XChaChaAEAD.seal(plaintext, key: key, nonce: nonce, aad: aad)
        let frame: JSONValue = [
            "type": "todex.crypto.v1", "protocol": .string(encryption.rawValue),
            "nonce": .string(CryptoEncoding.encode(nonce)), "ciphertext": .string(CryptoEncoding.encode(ciphertext)),
        ]
        return frame.prettyPrinted
    }
}

// Generated and checked with the backend's x25519-dalek 2.0.1, hkdf 0.12.4,
// sha2 0.10.9, chacha20poly1305 0.10.1 and pqcrypto-mlkem 0.1.1.
// X25519 uses the existing device-pairing fixture's [7;32]/[9;32] keys.
// ML-KEM uses seed=[21;64], encapsulation randomness=[23;32] in noble 0.7.1;
// Rust pqcrypto independently decapsulated it before generating these frames.
private func transportVectors() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(transportVectorJSON.utf8))
}

private let transportVectorJSON = #"""
    {
      "mlkem768": {
        "ciphertext": "Iiz34M1yvlQYrCcq1oD218N-6C6pZK72sJ_6i5cWq9Hi7AaQyn7QOKlCEbOhOonEV2BHYOT-5o-g2HTVLzomodXCr6txs4xBpnc_2tgH23QMTROLIQuSave4KjzwTAhfEii_EgYpVR0xurBmuGacUtnWQ4RIuP9SBy2re37JRYY2dwdLobqdvLiKYS1QnwJaYS2aoTNH1CnOcddSjjHanciJ-wOSkoacFCZ06fMSO0PGoI4F0bD1i2hqsSEvGizzjuUJPMWzznsgrttrQk9906taEf5b_M6NlF3Xbuk2KLoX-RCEp_H0NUbQ0KKs9Fv7f-_o4qasqBKMIyrwoKvqBda7QNd9ZNMde4RgJnb0RPYaM4y3qinY218UmdK-aWkxYt4Ze_q8spL9c1fQNeh_aEwqIi9BuRemsh81RYBTjPLz_dPFn4qynBc_9VVdto5tEcYnXErbgYi_4kh7nxeSDxS8O8ma1daNeVQntA9Lsvck7kpfRxB6ugX0o2CjQM6aPNyw_s3n6miJBsuTTfr1fXDKYwJTsgcIrwjG92mMlbhrINBeBsaCgHS4bTOId0brK0dHY6WF4uQ6zd5SyazGCaiJGSPl36xmgIEzy4tbK4_VTgIIBuUoO6dppMMtInA4b39BPyxqBW9QO2_bUz7tmwNeEPsF-0TJY0FDCozrSA7V2xwihPz5boXACGHh4a4FaFVnk67lmojsj60jMa9LA60vGS6_Y5Yvt4VjHqSJeJBSXO1-94hZa7FE4z6Du8Si6CX0zbsPnLQh9JGeajI2L1-W6B6VsT4Q9KTeiF2ALvc_M2CaZcGiIJKlu7s38Sl-xOArO0lkA-YpK5iNTkYkcZxGn__Sa11RevVYkXpHQ3MvTAxut0YutUVt7cyG0uJbkBg-f8VTTw1NV1N3mEKL3RtDJm0fHreX7ys20ZGwsNX4Iwf0_nIKjRctp4hxY6axm83ktX8lgZ_5UYEyQSE4lvs9q3QN9iQfj9CggVpS31J_1V7UNLwmGf-OElpU_Wn-iQrT7qxoZ2iv2u20o3DhQcRrVIM3aVsba1oEovNpOi1wWfrqXZJ3goW-Wut8R-pxVuQ6cubrSopx_6Rl5os8ynAy6qhlWko3-ww-LBXSqoVj_LmhfhfI9FEnz1Xey2TJxpDNqSZra9bEbLYxlvs3PElH89pOkJO_bPA0Po3GzS46sSqYUJny3tBvZAkelERoO6qQtPuJuyvvQTXTdtFkJEOH5UOYX9FF4CcSWNl1RpQXLV3UDrxGNJVyc5jdnNrD-ZlgwKK34gbs43LqAvWWI6Pm5rG8ed82Dfq9Omp-bV1y4ENzqicOw44K-SQGAOqnEjUBn1e6VNd9523S2J4G08oW_OxuyRmX9KHMt8VniQ9GrLW_u_O0vxJ09MGNu9y2LRpkyu_k98WZqhYQ7nR1p0UYUeFXARQy5iFTshBURJA",
        "clientFrame": {
          "ciphertext": "2M12FQxnHT8b5ycnLTWxdODq6IsWQMjJ9PYbhhJKhw",
          "nonce": "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "protocol": "ml-kem-768",
          "type": "todex.crypto.v1"
        },
        "key": "Di-salRRn6EHA5wIatmPvIZnNAPTupoV1O1FlHf9g_I",
        "publicKey": "uYnBf3i9_GKvosCFVHG-l8mih-yrYIuEIUVRJUKGtyuLy2m60Atz3TIvsPKpZxqLexjMYUy_D5kO6PsOfCyOFxEiyhSGUugJ_xQJadcT75GPwrcWfFChwmCp-mmAp3Y5IAwYfXZI8Be-wpKFndV7ORuNS8ai3gybNUwLa2pk8QtekcF0cfdxpnljTFwiKlM91ZVk0AhK65G-QUNqxqYHBdqTNtAuZkIxfIhsceR1CfZnOivLrbh9SqEYdvVhGvl4y4Ua5LFBWwOKeHSz4QovvjCRubZK9RuyBVTG7WvGePkFofG2Ehxiy7rLdMpq-6WU7DhBZrTPHLeGVnhsvVGxxWZN5vNu8mWjMXGEMheau5B7D7WI1udjXvZsYIPEcAVn-OgoFKIruhOXa7mX0PcsATEqgvFcSqpPy_u0vxsr1kDFu_GIE5BttJRgZeFKdxFc2AIW8jgCX3EhE-EA9lsG6zWOU6MwILaYwqEpjzIPepspDOSV7_BBv8lywSPCYJiR6uKBA2U3OzuaQiEHAse1FLIHtXoD63ZDtWYJngqj1SiII7mi_LSp6nuj0myem_aCMwSxk4q3v-I-TyRGnUgg-bFzU4ZDOEYmUMCSK8V7UHyw5dwBSxgGODQysWs0p_MRpVfDkCUUB2OQfYjKyoqSNwgjnGmSA-e6zJCO11tINZQ_zfefDOJIR4a1tyVWDouZlRtJlvR1pcswnje6CJcER_OovGUc4ApKxsxI39Aom4mgDwBumhONXZI7JLtkEfmjO3VqBBmFykxIHXqDjTCC8LeRpEE5wsG35hZq6fN874JGnPp7HdAL0ju98OGsFfwZ0nFVtpCFjuMr6ClSMmdrjOtJxgGupgmHR8bJS8dn0hFB4JQKqyAWw6i-jds0WZdJHrxehkca1YyE0Kaf0KxVzdJc5ghRRPKc45cgNTPD9dnEZqGntxyXOFZ7PNq9OWm9FAh9MWV2XCLPZqA6iXWRJOSFKGMRaEMCEsWGD9h0yNU-YcuR-EOm7eF_6kEBCiF7MtUZ18pS6aEWnnHEzwNt6MY0dqZb0glbwnyBFmIA04fF6su3l8gwA_tWVFuh8XIzpjwl2ITCHjk-zjp_6PB6msLEJsuCoRJ0SnqBdiGQ3XOOc8hU6OANDLV-yfJRBKMwARKD8UCBcuQ9y2NF3oVNruGsj7RHQ2AksVgDshuwsVw1_HGQ6zoCawS2jfqB9EZ_-Qp1wKaqUww5ZoVl0RUnUunBXqwyJ5SknpyJmPYUqcWc4jNfn8dCN3WHhgubIvTCAcyGUYwXgGSMOVCoCXe2vDlrPmVEFTI7hEugCBdiwKE2MiGO2hd8fMCb15GhV7Oo-yG-Ygui--VRAZzNIocN34NAtMZ4F6yQQ3txs4tsJeBU91DDngZmZ1wlb5YbVKSemSWzlhG73etNnFMW6_fLYAyjtqSGxOex3oCYOdY5ReIDARoW0RGCgPckLhSO0hTA5oWIr6k9QsF4E-ZFECgfc8qzRkk8PndAMwpuoglzeBrHOnhmS_gEcfdSYVXJI_cqtlawB0UKEG4unu-sXFZke84xanFkqB8y3-4P0tOXZJ0",
        "secondServerFrame": {
          "ciphertext": "Hd6s_HI5Y5J-pvVvM9yFXAdLzLbN1pJh0qp9la4P",
          "nonce": "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAA",
          "protocol": "ml-kem-768",
          "type": "todex.crypto.v1"
        },
        "seed": "FRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFQ",
        "serverFrame": {
          "ciphertext": "EhluEcT2Z5bP3kc-BPCRsV1D1_VXHDhWIY9CyPInxg",
          "nonce": "AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "protocol": "ml-kem-768",
          "type": "todex.crypto.v1"
        },
        "sharedSecret": "wdiL8B16qzVaeUXqd9owhErxTFp-bu33T71ZtVpjQAw"
      },
      "x25519": {
        "clientFrame": {
          "ciphertext": "ZYepD3X3J6bS8redbS3MHAhVXN8RYqMfkUk-Stc49w",
          "nonce": "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "protocol": "x25519",
          "type": "todex.crypto.v1"
        },
        "clientPublicKey": "E75P6uryBMf9M1j8nAByGIHRdCeBKCJ-xnTzf3_pe20",
        "clientSecret": "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc",
        "key": "MJnD1uex_WsL0sawjop2ET7G1wWXHhcmRXLWcDrAElo",
        "secondServerFrame": {
          "ciphertext": "OSoWt2TqR78Nyss4TmzNbEcpPisK5gkttCTw6O6x",
          "nonce": "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAA",
          "protocol": "x25519",
          "type": "todex.crypto.v1"
        },
        "serverFrame": {
          "ciphertext": "cjSET2djfqSGcrDUSApY8FWs7OABMQQhJGLrhlXQ4A",
          "nonce": "AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "protocol": "x25519",
          "type": "todex.crypto.v1"
        },
        "serverPublicKey": "V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE",
        "sharedSecret": "L_4yWyomYRvxkRMl1KYrM3SbjzUNDoi6keMWrKrmZVQ"
      }
    }
    """#
