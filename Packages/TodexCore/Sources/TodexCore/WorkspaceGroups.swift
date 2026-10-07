import Foundation

/// Two or more workspaces sharing a `groupId`, shown under one header.
public struct WorkspaceGroup: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var workspaces: [WorkspaceRecord]

    public init(id: String, name: String, workspaces: [WorkspaceRecord]) {
        self.id = id
        self.name = name
        self.workspaces = workspaces
    }
}

/// A top-level workspace list row: a lone workspace or a group.
public enum WorkspaceEntry: Sendable, Equatable {
    case workspace(WorkspaceRecord)
    case group(WorkspaceGroup)

    /// The entry's workspaces in display order.
    public var workspaces: [WorkspaceRecord] {
        switch self {
        case .workspace(let workspace): [workspace]
        case .group(let group): group.workspaces
        }
    }
}

/// Workspace grouping shared with the desktop sidebar. Mirrors
/// `groupWorkspaceEntries`, `workspaceLayoutPatches` and the group menu
/// operations in TodeX_protocol/src/todex.ts.
public enum WorkspaceGroups {
    /// Max length the backend keeps for `groupId` / `groupName`.
    public static let fieldMax = 64

    public static func newGroupID() -> String {
        "wsg_\(UUID().uuidString.lowercased())"
    }

    /// Group name for two workspaces grouped together: their shared
    /// case-insensitive name prefix (trailing separators trimmed, at least two
    /// characters) or `fallback`.
    public static func suggestName(_ left: String, _ right: String, fallback: String) -> String {
        let a = Array(left)
        let b = Array(right)
        var length = 0
        while length < a.count, length < b.count, a[length].lowercased() == b[length].lowercased() {
            length += 1
        }
        var prefix = a[..<length]
        while let last = prefix.last, last.isWhitespace || "_-.".contains(last) {
            prefix.removeLast()
        }
        return prefix.count >= 2 ? String(prefix.prefix(fieldMax)) : fallback
    }

    /// Folds an already ordered workspace list into entries. A group takes the
    /// position of its first member; a `groupId` with a single member renders
    /// as a plain workspace. The group name comes from the most recently
    /// updated member that carries one.
    public static func entries(_ ordered: [WorkspaceRecord]) -> [WorkspaceEntry] {
        var members: [String: [WorkspaceRecord]] = [:]
        for workspace in ordered {
            guard let groupId = groupID(workspace) else { continue }
            members[groupId, default: []].append(workspace)
        }
        var entries: [WorkspaceEntry] = []
        var emitted: Set<String> = []
        for workspace in ordered {
            guard let groupId = groupID(workspace), let group = members[groupId], group.count >= 2 else {
                entries.append(.workspace(workspace))
                continue
            }
            guard emitted.insert(groupId).inserted else { continue }
            var named: WorkspaceRecord?
            for member in group where member.groupName?.isEmpty == false {
                if named == nil || member.updatedAt > named!.updatedAt { named = member }
            }
            entries.append(.group(WorkspaceGroup(id: groupId, name: named?.groupName ?? "", workspaces: group)))
        }
        return entries
    }

    /// Groups two top-level workspaces, `targetID` first, at the target's
    /// position. Returns `entries` unchanged unless both are top-level.
    public static func groupTogether(
        _ entries: [WorkspaceEntry], targetID: String, workspaceID: String, newGroupID: String, fallbackName: String
    ) -> [WorkspaceEntry] {
        guard targetID != workspaceID,
            let moving = topLevel(entries, workspaceID),
            let target = topLevel(entries, targetID)
        else { return entries }
        var rest = without(entries, workspaceID)
        guard let index = rest.firstIndex(of: .workspace(target)) else { return entries }
        rest[index] = .group(
            WorkspaceGroup(
                id: newGroupID, name: suggestName(target.name, moving.name, fallback: fallbackName),
                workspaces: [target, moving]))
        return rest
    }

    /// Moves a workspace to the end of an existing group.
    public static func move(_ entries: [WorkspaceEntry], workspaceID: String, toGroup groupID: String) -> [WorkspaceEntry] {
        guard let moving = find(entries, workspaceID) else { return entries }
        if case .group(let current)? = Self.group(containing: workspaceID, in: entries), current.id == groupID {
            return entries
        }
        var rest = without(entries, workspaceID)
        guard
            let index = rest.firstIndex(where: {
                if case .group(let group) = $0 { group.id == groupID } else { false }
            }), case .group(var group) = rest[index]
        else { return entries }
        group.workspaces.append(moving)
        rest[index] = .group(group)
        return rest
    }

    /// Takes a workspace out of its group and places it right after the group.
    public static func removeFromGroup(_ entries: [WorkspaceEntry], workspaceID: String) -> [WorkspaceEntry] {
        guard
            let index = entries.firstIndex(where: {
                if case .group(let group) = $0 { group.workspaces.contains { $0.id == workspaceID } } else { false }
            }), case .group(var group) = entries[index],
            let moving = group.workspaces.first(where: { $0.id == workspaceID })
        else { return entries }
        group.workspaces.removeAll { $0.id == workspaceID }
        var result = Array(entries[..<index])
        result += groupOrSingles(group)
        result.append(.workspace(moving))
        result += entries[(index + 1)...]
        return result
    }

    /// Dissolves a group, keeping its members in place.
    public static func ungroup(_ entries: [WorkspaceEntry], groupID: String) -> [WorkspaceEntry] {
        entries.flatMap { entry -> [WorkspaceEntry] in
            if case .group(let group) = entry, group.id == groupID { return group.workspaces.map(WorkspaceEntry.workspace) }
            return [entry]
        }
    }

    /// Renames a group; a blank name leaves `entries` unchanged.
    public static func rename(_ entries: [WorkspaceEntry], groupID: String, name: String) -> [WorkspaceEntry] {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(fieldMax))
        guard !trimmed.isEmpty else { return entries }
        return entries.map { entry in
            guard case .group(var group) = entry, group.id == groupID else { return entry }
            group.name = trimmed
            return .group(group)
        }
    }

    /// Flattens `entries` back into per-workspace `sortOrder`, `groupId` and
    /// `groupName` and returns only the records whose stored layout differs,
    /// with `updatedAt` set to `now`.
    public static func layoutUpdates(_ entries: [WorkspaceEntry], now: Int) -> [WorkspaceRecord] {
        var updates: [WorkspaceRecord] = []
        var sortOrder = 0
        func visit(_ workspace: WorkspaceRecord, groupId: String?, groupName: String?) {
            defer { sortOrder += 1 }
            guard workspace.sortOrder != sortOrder || workspace.groupId != groupId || workspace.groupName != groupName
            else { return }
            var updated = workspace
            updated.sortOrder = sortOrder
            updated.groupId = groupId
            updated.groupName = groupName
            updated.updatedAt = now
            updates.append(updated)
        }
        for entry in entries {
            switch entry {
            case .workspace(let workspace):
                visit(workspace, groupId: nil, groupName: nil)
            case .group(let group):
                for workspace in group.workspaces {
                    visit(workspace, groupId: group.id, groupName: group.name.isEmpty ? nil : group.name)
                }
            }
        }
        return updates
    }

    /// The entry holding `workspaceID`: the workspace itself or its group.
    public static func group(containing workspaceID: String, in entries: [WorkspaceEntry]) -> WorkspaceEntry? {
        entries.first { $0.workspaces.contains { $0.id == workspaceID } }
    }

    private static func groupID(_ workspace: WorkspaceRecord) -> String? {
        guard let groupId = workspace.groupId, !groupId.isEmpty else { return nil }
        return groupId
    }

    private static func groupOrSingles(_ group: WorkspaceGroup) -> [WorkspaceEntry] {
        group.workspaces.count < 2 ? group.workspaces.map(WorkspaceEntry.workspace) : [.group(group)]
    }

    private static func without(_ entries: [WorkspaceEntry], _ workspaceID: String) -> [WorkspaceEntry] {
        entries.flatMap { entry -> [WorkspaceEntry] in
            switch entry {
            case .workspace(let workspace):
                return workspace.id == workspaceID ? [] : [entry]
            case .group(var group):
                let count = group.workspaces.count
                group.workspaces.removeAll { $0.id == workspaceID }
                return group.workspaces.count == count ? [entry] : groupOrSingles(group)
            }
        }
    }

    private static func find(_ entries: [WorkspaceEntry], _ workspaceID: String) -> WorkspaceRecord? {
        entries.lazy.flatMap(\.workspaces).first { $0.id == workspaceID }
    }

    private static func topLevel(_ entries: [WorkspaceEntry], _ workspaceID: String) -> WorkspaceRecord? {
        for case .workspace(let workspace) in entries where workspace.id == workspaceID { return workspace }
        return nil
    }
}
