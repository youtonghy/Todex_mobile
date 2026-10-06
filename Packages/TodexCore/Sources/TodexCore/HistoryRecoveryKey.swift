import CryptoKit
import Foundation

/// The history recovery key (§3.3): a 32-byte X-Wing seed shown once as 24
/// BIP39 English words and as a QR code `todex-recovery:v1:<base64url seed>`.
/// Only its public key is uploaded (`history.recovery.set`).
public enum HistoryRecoveryKey {
    public static let qrPrefix = "todex-recovery:v1:"
    public static let seedLength = 32
    public static let wordCount = 24
    /// SHA-256 of the official BIP39 English list (bitcoin/bips bip-0039/english.txt).
    static let wordlistSHA256 = "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"

    public static func generateSeed() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// 256-bit entropy + the first 8 bits of its SHA-256 = 24 × 11-bit indexes.
    public static func words(seed: Data) throws -> [String] {
        guard seed.count == seedLength else { throw invalidKey }
        let list = try wordlist()
        var bits = [Bool]()
        bits.reserveCapacity(264)
        for byte in seed + Data(SHA256.hash(data: seed).prefix(1)) {
            for shift in (0..<8).reversed() { bits.append(byte >> UInt8(shift) & 1 == 1) }
        }
        return (0..<wordCount).map { word in
            list[bits[word * 11..<word * 11 + 11].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }]
        }
    }

    /// Parses 24 words (any case and whitespace; a unique prefix of at least
    /// four letters is enough, as BIP39 English guarantees) and checks the checksum.
    public static func seed(words input: String) throws -> Data {
        let list = try wordlist()
        let typed = input.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard typed.count == wordCount else {
            throw TodexError.invalid(String(localized: "恢复密钥需要 24 个单词，当前为 \(typed.count) 个", bundle: .module))
        }
        var bits = [Bool]()
        bits.reserveCapacity(264)
        for (position, word) in typed.enumerated() {
            guard let index = index(of: word, in: list) else {
                throw TodexError.invalid(String(localized: "第 \(position + 1) 个单词“\(word)”不在恢复词表中", bundle: .module))
            }
            for shift in (0..<11).reversed() { bits.append(index >> shift & 1 == 1) }
        }
        var bytes = [UInt8](repeating: 0, count: 33)
        for (offset, bit) in bits.enumerated() where bit { bytes[offset / 8] |= 0x80 >> UInt8(offset % 8) }
        let seed = Data(bytes.prefix(seedLength))
        guard Data(SHA256.hash(data: seed).prefix(1)) == Data([bytes[32]]) else {
            throw TodexError.invalid(String(localized: "恢复密钥校验失败，请检查单词顺序与拼写", bundle: .module))
        }
        return seed
    }

    public static func qrString(seed: Data) throws -> String {
        guard seed.count == seedLength else { throw invalidKey }
        return qrPrefix + CryptoEncoding.encode(seed)
    }

    public static func seed(qrString input: String) throws -> Data {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(qrPrefix), let seed = try? CryptoEncoding.decode(String(text.dropFirst(qrPrefix.count)), count: seedLength)
        else { throw invalidKey }
        return seed
    }

    /// Accepts either the QR text or the 24 words.
    public static func seed(parsing input: String) throws -> Data {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.lowercased().hasPrefix("todex-recovery:") ? try seed(qrString: text) : try seed(words: text)
    }

    private static var invalidKey: TodexError {
        TodexError.invalid(String(localized: "恢复密钥格式无效", bundle: .module))
    }

    private static func index(of word: String, in list: [String]) -> Int? {
        if let exact = wordIndex[word] { return exact }
        guard word.count >= 4 else { return nil }
        let matches = list.indices.filter { list[$0].hasPrefix(word) }
        return matches.count == 1 ? matches[0] : nil
    }

    private static let loaded: Result<[String], TodexError> = {
        let failure = TodexError.invalid(String(localized: "恢复词表损坏，请重新安装应用", bundle: .module))
        guard let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt"),
            let data = try? Data(contentsOf: url),
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == wordlistSHA256
        else { return .failure(failure) }
        let words = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        return words.count == 2048 ? .success(words) : .failure(failure)
    }()

    /// Word → index; empty when the list failed verification (`wordlist()` reports it).
    private static let wordIndex: [String: Int] =
        ((try? loaded.get()) ?? []).enumerated().reduce(into: [:]) { $0[$1.element] = $1.offset }

    /// The verified 2048-word list.
    public static func wordlist() throws -> [String] { try loaded.get() }
}
