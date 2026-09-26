import Foundation
import Synchronization
import os

/// DEBUG-only diagnostics, mirroring desktop `debugLogger` (enabled only for
/// DEV builds there). Records go to os.Logger (visible in Console.app) and a
/// bounded in-memory ring buffer that About can export. Release builds compile
/// every call to a no-op, and values are redacted before they are stored so a
/// token or secret never reaches the log even in DEBUG.
public enum DebugLog {
    public enum Level: String, Sendable {
        case debug, info, warn, error
    }

    public static let capacity = 500
    static let maxValueLength = 2_048

    #if DEBUG
        public static let isEnabled = true
    #else
        public static let isEnabled = false
    #endif

    private static let logger = Logger(subsystem: "com.todex.mobile", category: "debug")
    private static let buffer = Mutex(Ring())

    private struct Ring: Sendable {
        var lines: [String] = []
        var sequence = 0
    }

    /// `fields` values are redacted; keys that name secrets are masked whole.
    public static func record(_ event: String, _ fields: [String: String] = [:], level: Level = .debug) {
        #if DEBUG
            let body = fields.sorted { $0.key < $1.key }.map { key, value in
                "\(key)=\(sensitiveKey(key) ? "[REDACTED]" : redact(value))"
            }.joined(separator: " ")
            let timestamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
            let line = buffer.withLock { ring -> String in
                ring.sequence += 1
                let head = "\(timestamp) #\(ring.sequence) [\(level.rawValue)] \(event)"
                let line = body.isEmpty ? head : "\(head) \(body)"
                ring.lines.append(line)
                if ring.lines.count > capacity { ring.lines.removeFirst(ring.lines.count - capacity) }
                return line
            }
            switch level {
            case .debug: logger.debug("\(line, privacy: .public)")
            case .info: logger.info("\(line, privacy: .public)")
            case .warn: logger.warning("\(line, privacy: .public)")
            case .error: logger.error("\(line, privacy: .public)")
            }
        #endif
    }

    /// The retained records, oldest first, one per line.
    public static func export() -> String {
        buffer.withLock { $0.lines.joined(separator: "\n") }
    }

    public static func clear() {
        buffer.withLock { $0 = Ring() }
    }

    private static let sensitiveKeyPattern =
        #"(authorization|token|api[_-]?key|password|passwd|secret|private[_-]?key|cookie|signature|proof)"#

    static func sensitiveKey(_ key: String) -> Bool {
        key.range(of: sensitiveKeyPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Masks `key=value` / `key: value` secrets, URL userinfo and query strings
    /// (device signatures travel there), bearer tokens and data URLs.
    public static func redact(_ value: String) -> String {
        if value.range(of: #"^data:[^,]+,"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "[data-url \(value.count) chars]"
        }
        var text = value.count > maxValueLength
            ? "\(value.prefix(maxValueLength))… [truncated \(value.count - maxValueLength) chars]" : value
        let rules: [(String, String)] = [
            // Bearer first: the key rule below would otherwise consume only the
            // word "Bearer" and leave the token itself.
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1[REDACTED]"),
            ("(" + sensitiveKeyPattern + #"\s*["']?\s*[=:]\s*["']?)([^,\s;&"']+)"#, "$1[REDACTED]"),
            (#"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@]+@"#, "$1[REDACTED]@"),
            (#"(?i)\b((?:https?|wss?)://[^\s?#]+)\?[^\s#]*"#, "$1?[REDACTED]"),
        ]
        for (pattern, template) in rules {
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern, options: pattern.hasPrefix("(?i)") ? [] : [.caseInsensitive])
            else { continue }
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return text
    }
}
