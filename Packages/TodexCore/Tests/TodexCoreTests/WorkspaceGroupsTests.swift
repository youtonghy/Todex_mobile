import Foundation
import Testing

@testable import TodexCore

/// Mirrors the grouping cases in TodeX_protocol/tests/unit/workspace-sync.test.cjs.
struct WorkspaceGroupsTests {
    private func workspace(
        _ id: String, _ name: String = "", groupId: String? = nil, groupName: String? = nil, sortOrder: Int? = nil,
        updatedAt: Int = 1
    ) -> WorkspaceRecord {
        WorkspaceRecord(
            id: id, name: name, path: "/\(id)", sortOrder: sortOrder, groupId: groupId, groupName: groupName,
            createdAt: 1, updatedAt: updatedAt)
    }

    private func sample() -> [WorkspaceEntry] {
        WorkspaceGroups.entries([
            workspace("a", "TJXY"),
            workspace("b", "Todex", groupId: "g1", groupName: "Old", updatedAt: 10),
            workspace("c", "Other"),
            workspace("d", "Todex_test", groupId: "g1", groupName: "Todex", updatedAt: 50),
            workspace("e", "TJXY_app", groupId: "lonely"),
        ])
    }

    private func layout(_ entries: [WorkspaceEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .workspace(let workspace): workspace.id
            case .group(let group): "\(group.name)[\(group.workspaces.map(\.id).joined(separator: ","))]"
            }
        }
    }

    @Test
    func groupFieldsRoundTripAndOmitNil() throws {
        let grouped = workspace("a", "A", groupId: "wsg_1", groupName: "App")
        let wire = try JSONValue(encoding: grouped)
        #expect(wire["groupId"].optionalString == "wsg_1")
        #expect(wire["groupName"].optionalString == "App")
        #expect(try wire.decoded(WorkspaceRecord.self) == grouped)

        let plain = try JSONValue(encoding: workspace("b"))
        #expect(plain.objectValue["groupId"] == nil)
        #expect(plain.objectValue["groupName"] == nil)
        let decoded = try plain.decoded(WorkspaceRecord.self)
        #expect(decoded.groupId == nil)
        #expect(decoded.groupName == nil)
    }

    @Test
    func foldsGroupsAtTheirFirstMemberAndDissolvesSingletons() {
        #expect(layout(sample()) == ["a", "Todex[b,d]", "c", "e"])
        // An empty groupId is not a group.
        let entries = WorkspaceGroups.entries([workspace("x", groupId: ""), workspace("y", groupId: "")])
        #expect(layout(entries) == ["x", "y"])
    }

    @Test
    func menuOperations() {
        #expect(layout(WorkspaceGroups.removeFromGroup(sample(), workspaceID: "b")) == ["a", "d", "b", "c", "e"])
        #expect(layout(WorkspaceGroups.ungroup(sample(), groupID: "g1")) == ["a", "b", "d", "c", "e"])
        #expect(layout(WorkspaceGroups.move(sample(), workspaceID: "a", toGroup: "g1")) == ["Todex[b,d,a]", "c", "e"])
        // Moving a member of a two-member group elsewhere dissolves the old group.
        let regrouped = WorkspaceGroups.groupTogether(
            sample(), targetID: "a", workspaceID: "e", newGroupID: "g2", fallbackName: "N")
        #expect(layout(WorkspaceGroups.move(regrouped, workspaceID: "e", toGroup: "g1")) == ["a", "Todex[b,d,e]", "c"])
        #expect(
            layout(WorkspaceGroups.groupTogether(sample(), targetID: "c", workspaceID: "a", newGroupID: "g2", fallbackName: "N"))
                == ["Todex[b,d]", "N[c,a]", "e"])
        #expect(layout(regrouped) == ["TJXY[a,e]", "Todex[b,d]", "c"])
        // Grouping needs two distinct top-level workspaces.
        #expect(
            WorkspaceGroups.groupTogether(sample(), targetID: "b", workspaceID: "a", newGroupID: "g2", fallbackName: "N")
                == sample())
        #expect(
            WorkspaceGroups.groupTogether(sample(), targetID: "a", workspaceID: "a", newGroupID: "g2", fallbackName: "N")
                == sample())
        #expect(WorkspaceGroups.rename(sample(), groupID: "g1", name: "  ") == sample())
        #expect(layout(WorkspaceGroups.rename(sample(), groupID: "g1", name: " Core ")) == ["a", "Core[b,d]", "c", "e"])
        let long = WorkspaceGroups.rename(sample(), groupID: "g1", name: String(repeating: "x", count: 80))
        guard case .group(let group) = long[1] else {
            Issue.record("expected a group")
            return
        }
        #expect(group.name.count == WorkspaceGroups.fieldMax)
    }

    @Test
    func layoutUpdatesOnlyChangedRecords() {
        let updates = WorkspaceGroups.layoutUpdates(
            WorkspaceGroups.rename(sample(), groupID: "g1", name: "Core"), now: 99)
        #expect(updates.map(\.id) == ["a", "b", "d", "c", "e"])
        #expect(updates.map(\.sortOrder) == [0, 1, 2, 3, 4])
        #expect(updates.map(\.groupId) == [nil, "g1", "g1", nil, nil])
        #expect(updates.map(\.groupName) == [nil, "Core", "Core", nil, nil])
        #expect(updates.allSatisfy { $0.updatedAt == 99 })

        let settled = WorkspaceGroups.entries([
            workspace("a", sortOrder: 0),
            workspace("b", sortOrder: 1),
            workspace("c", groupId: "g", groupName: "G", sortOrder: 2),
            workspace("d", groupId: "g", groupName: "G", sortOrder: 3),
        ])
        #expect(WorkspaceGroups.layoutUpdates(settled, now: 99).isEmpty)
        let ungrouped = WorkspaceGroups.layoutUpdates(WorkspaceGroups.ungroup(settled, groupID: "g"), now: 99)
        #expect(ungrouped.map(\.id) == ["c", "d"])
        #expect(ungrouped.allSatisfy { $0.groupId == nil && $0.groupName == nil })
    }

    @Test
    func suggestsTheSharedNamePrefix() {
        #expect(WorkspaceGroups.suggestName("TJXY", "TJXY_app", fallback: "N") == "TJXY")
        #expect(WorkspaceGroups.suggestName("todex-web", "Todex-desktop", fallback: "N") == "todex")
        #expect(WorkspaceGroups.suggestName("blog", "notes", fallback: "N") == "N")
        #expect(WorkspaceGroups.suggestName("a_x", "a_y", fallback: "N") == "N")
        let id = WorkspaceGroups.newGroupID()
        #expect(id.hasPrefix("wsg_"))
        #expect(id.count == 40)
        #expect(id == id.lowercased())
    }
}
