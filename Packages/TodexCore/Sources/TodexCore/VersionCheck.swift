import Foundation

/// Release builds ship in lockstep across backend and clients, so a real
/// version difference warns about possible incompatibility. Dev builds report
/// "DEV0.0.0" (or a bare "0.0.0") and skip the check entirely.
public enum VersionCheck {
    public static func isDev(_ version: String?) -> Bool {
        let normalized = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return true }
        return normalized.range(of: #"^(?:dev[-.]?)?0\.0\.0$"#, options: .regularExpression) != nil
    }

    public static func mismatch(app: String?, backend: String?) -> Bool {
        guard !isDev(app), !isDev(backend) else { return false }
        return normalize(app) != normalize(backend)
    }

    private static func normalize(_ version: String?) -> String {
        var value = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        return value
    }
}
