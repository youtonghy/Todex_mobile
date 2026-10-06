import CryptoKit
import Foundation

/// Authorizes another recipient to read existing history (§3.3): enumerate
/// key ids (`history.keys.list`), fetch the source recipient's wraps
/// (`history.keys.wraps`), unwrap locally, wrap again for the target public
/// key and upload in batches (`history.grant.fulfill`). The backend only
/// stores the new wraps; it never sees a DEK.
///
/// Work commits page by page. `Progress.cursor` is the `keys.list` cursor
/// after the last fully uploaded page, so an interrupted run resumes there
/// (re-uploading a wrap the backend already has is harmless).
public enum HistoryGrant {
    public struct Progress: Sendable, Equatable, Codable {
        /// Keys re-wrapped and uploaded.
        public var processed = 0
        /// Keys the source cannot read (no wrap for it, or unwrap failed).
        public var skipped = 0
        /// Wraps the backend reported as new.
        public var added = 0
        /// Resume point: nil before the first page.
        public var cursor: String?
        public var finished = false
        public init(cursor: String? = nil) { self.cursor = cursor }
    }

    /// - Parameters:
    ///   - grantId: The pending request being fulfilled; nil for a self-grant
    ///     after importing the recovery key.
    ///   - target: The recipient receiving access; its key must match its rid.
    ///   - source: The private key whose wraps are re-wrapped.
    ///   - sourceRid: Sent as `rid` to `history.keys.wraps`; nil means the
    ///     calling device's own recipient.
    ///   - resume: A previous run's progress to continue from.
    public static func fulfill(
        api: HistoryAPI, grantId: String?, target: HistoryRecipient, source: XWingMLKEM768X25519.PrivateKey,
        sourceRid: Data?, resume: Progress? = nil, progress report: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Progress {
        let targetKey = try target.verifiedPublicKey()
        var progress = resume ?? Progress()
        progress.finished = false
        for _ in 0..<1_000_000 {
            try Task.checkCancellation()
            let page = try await api.keys(cursor: progress.cursor, limit: HistoryEncryption.batchLimit)
            var uploads: [HistoryGrantWrap] = []
            var skipped = 0
            let byConversation = Dictionary(grouping: page.items, by: \.conversationId)
            for conversationId in byConversation.keys.sorted() {
                var kids: [Data] = []
                for item in byConversation[conversationId] ?? [] {
                    if let kid = try? CryptoEncoding.decode(item.kid, count: HistoryCrypto.kidLength) {
                        kids.append(kid)
                    } else {
                        skipped += 1
                    }
                }
                for start in stride(from: 0, to: kids.count, by: HistoryEncryption.batchLimit) {
                    let batch = Array(kids[start..<min(start + HistoryEncryption.batchLimit, kids.count)])
                    let wraps = try await api.wraps(conversationId: conversationId, kids: batch, rid: sourceRid)
                    for kid in batch {
                        guard let wrapped = wraps[kid], let key = try? HistoryCrypto.unwrap(wrapped, kid: kid, with: source)
                        else {
                            skipped += 1
                            continue
                        }
                        uploads.append(
                            HistoryGrantWrap(
                                conversationId: conversationId, kid: CryptoEncoding.encode(kid),
                                wrapped: try HistoryCrypto.wrap(key, for: targetKey)))
                    }
                }
            }
            let last = (page.nextCursor ?? "").isEmpty
            // The final batch of a grant carries `complete: true` (an empty one
            // when the last page had nothing to upload); self-grants have no grant.
            let starts = Array(stride(from: 0, to: uploads.count, by: HistoryEncryption.batchLimit))
            for start in (starts.isEmpty && last && grantId != nil ? [0] : starts) {
                try Task.checkCancellation()
                let batch = Array(uploads[start..<min(start + HistoryEncryption.batchLimit, uploads.count)])
                let final = last && grantId != nil && start == (starts.last ?? 0)
                progress.added += try await api.fulfill(grantId: grantId, rid: target.rid, wraps: batch, complete: final)
                progress.processed += batch.count
            }
            progress.skipped += skipped
            guard let next = page.nextCursor, !next.isEmpty else {
                progress.cursor = nil
                progress.finished = true
                await report(progress)
                return progress
            }
            guard next != progress.cursor else {
                throw TodexError.invalid(String(localized: "历史密钥分页没有前进", bundle: .module))
            }
            progress.cursor = next
            await report(progress)
        }
        throw TodexError.invalid(String(localized: "历史密钥分页过多", bundle: .module))
    }
}
