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
        #expect(ReferenceMenu.state("app:text") == .item(.app, query: "text"))
    }

    @Test
    func listsTypesInAFixedOrderNarrowedByPrefix() {
        #expect(ReferenceMenu.types(matching: "") == [.file, .folder, .chat, .skill, .mcp, .ssh, .app])
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

    @Test
    func appSuggestionsMatchNameOrIdAndInsertAnIdMention() throws {
        let apps = [
            HostApp(id: "com.google.Chrome", name: "Google Chrome", running: true),
            HostApp(id: "com.apple.TextEdit", name: "TextEdit", running: false),
        ]
        let chrome = try #require(ReferenceMenu.apps(apps, matching: "googlech").first)
        #expect(ReferenceMenu.apps(apps, matching: "googlech").count == 1)
        #expect(ReferenceMenu.appLabel(chrome) == "Google Chrome")
        #expect(ReferenceMenu.appInsert(chrome) == "@app:com.google.Chrome ")
        #expect(ReferenceMenu.apps(apps, matching: "APPLE").map(\.id) == ["com.apple.TextEdit"])
        #expect(ReferenceMenu.apps(apps, matching: "").map(\.id) == ["com.google.Chrome", "com.apple.TextEdit"])
        #expect(ReferenceMenu.apps(apps, matching: "safari").isEmpty)
        #expect(ReferenceMenu.appLabel(HostApp(id: "x.y", name: "", running: false)) == "x.y")
        let many = (0..<20).map { HostApp(id: "a\($0)", name: "A\($0)", running: false) }
        #expect(ReferenceMenu.apps(many, matching: "").count == ReferenceMenu.suggestionLimit)
    }
}
