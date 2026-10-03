import Testing

@testable import TodexCore

/// Mirrors TodeX_protocol/tests/unit/reference-menu.test.cjs.
struct ReferenceMenuTests {
    @Test
    func parsesTheMenuStageFromTheTextAfterAt() {
        #expect(ReferenceMenu.state("") == .type(prefix: ""))
        #expect(ReferenceMenu.state("sk") == .type(prefix: "sk"))
        #expect(ReferenceMenu.state("Skill:git") == .item(.skill, query: "git"))
        #expect(ReferenceMenu.state("folder:") == .item(.folder, query: ""))
        #expect(ReferenceMenu.state("chat:a:b") == .item(.chat, query: "a:b"))
        // Unknown prefixes and paths with colons stay a file search.
        #expect(ReferenceMenu.state("foo:bar") == .type(prefix: "foo:bar"))
        #expect(ReferenceMenu.state("src/a:b") == .type(prefix: "src/a:b"))
        #expect(ReferenceMenu.state(":x") == .type(prefix: ":x"))
    }

    @Test
    func listsTypesInAFixedOrderNarrowedByPrefix() {
        #expect(ReferenceMenu.types(matching: "") == [.file, .folder, .chat, .skill, .mcp])
        #expect(ReferenceMenu.types(matching: "F") == [.file, .folder])
        #expect(ReferenceMenu.types(matching: "src/").isEmpty)
    }

    @Test
    func entriesInsertTheProviderFacingPathPerMode() {
        #expect(ReferenceMenu.entryInsert(path: "src/a.ts", isDirectory: false, mode: .file) == "@src/a.ts ")
        #expect(ReferenceMenu.entryInsert(path: "src", isDirectory: true, mode: .any) == "@src")
        #expect(ReferenceMenu.entryInsert(path: "src", isDirectory: true, mode: .file) == "@file:src/")
        #expect(ReferenceMenu.entryInsert(path: "src/", isDirectory: true, mode: .folder) == "@src/ ")
        #expect(ReferenceMenu.entryLabel(path: "src//", isDirectory: true) == "@src/")
        #expect(!ReferenceMenu.shows(isDirectory: false, in: .folder))
        #expect(ReferenceMenu.shows(isDirectory: true, in: .file))
    }
}
