import Foundation

/// The composer `@` menu is two-level: `@` lists reference types and
/// `@type:query` searches one type. The type prefix is only menu navigation;
/// picking an item inserts the same text or chip as before (`@path`, a skill
/// chip, `#mcp`, a conversation export), matching
/// `@todex/protocol/referenceMenu` on desktop/web.
public enum ReferenceType: String, CaseIterable, Sendable {
    case file, folder, chat, skill, mcp, ssh, app
}

public enum ReferenceMenuState: Equatable, Sendable {
    /// No type chosen yet: type rows plus the plain `@path` file search.
    case type(prefix: String)
    case item(ReferenceType, query: String)
}

public enum ReferenceMenu {
    public static let suggestionLimit = 8
    /// Entries requested when only one kind is shown; the backend has no kind filter.
    public static let typedEntryFetchLimit = 100

    /// Which workspace entries a list shows and what picking one inserts.
    public enum EntryMode: Sendable {
        /// Untyped `@query`: files and folders, as before the type menu.
        case any
        /// Files; folders browse into themselves.
        case file
        /// Folders as the final reference.
        case folder
    }

    /// Unknown prefixes (`@foo:bar`, `@C:/x`) stay a plain file search: file
    /// names may contain colons.
    public static func state(_ query: String) -> ReferenceMenuState {
        if let colon = query.firstIndex(of: ":"), colon > query.startIndex,
            let type = ReferenceType(rawValue: query[..<colon].lowercased())
        {
            return .item(type, query: String(query[query.index(after: colon)...]))
        }
        return .type(prefix: query)
    }

    public static func types(matching prefix: String) -> [ReferenceType] {
        let lowered = prefix.lowercased()
        return ReferenceType.allCases.filter { $0.rawValue.hasPrefix(lowered) }
    }

    public static func shows(isDirectory: Bool, in mode: EntryMode) -> Bool {
        mode != .folder || isDirectory
    }

    /// Text that replaces the `@` trigger when an entry is picked.
    public static func entryInsert(path: String, isDirectory: Bool, mode: EntryMode) -> String {
        guard isDirectory else { return "@\(path) " }
        let trimmed = trimmingTrailingSlashes(path)
        switch mode {
        case .any: return "@\(path)"
        case .file: return "@file:\(trimmed)/"
        case .folder: return "@\(trimmed)/ "
        }
    }

    public static func entryLabel(path: String, isDirectory: Bool) -> String {
        isDirectory ? "@\(trimmingTrailingSlashes(path))/" : "@\(path)"
    }

    /// `@app:` matches an app's name (spaces ignored) or id, case-insensitively,
    /// mirroring `buildAppReferenceSuggestions` on desktop/web.
    public static func apps(_ apps: [HostApp], matching query: String) -> [HostApp] {
        let needle = query.lowercased()
        return Array(
            apps.filter {
                needle.isEmpty
                    || $0.name.lowercased().filter { !$0.isWhitespace }.contains(needle)
                    || $0.id.lowercased().contains(needle)
            }
            .prefix(suggestionLimit))
    }

    /// The agent passes the id to Computer Use (`open_app`), whose per-app approval still applies.
    public static func appInsert(_ app: HostApp) -> String { "@app:\(app.id) " }

    public static func appLabel(_ app: HostApp) -> String { app.name.isEmpty ? app.id : app.name }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var value = Substring(path)
        while value.hasSuffix("/") { value = value.dropLast() }
        return String(value)
    }
}
