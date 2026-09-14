import JavaScriptCore
import UIKit

/// Syntax highlighting for the workbench file preview. Runs the bundled
/// Chat/highlight.min.js inside JavaScriptCore (no DOM needed for
/// `hljs.highlight`), then converts the emitted `<span class="hljs-*">`
/// markup into an attributed string using the same palette as
/// Chat/timeline.css. Actor isolation serializes JSContext access off the
/// main thread; the result crosses back as a `sending` value.
actor CodeHighlighter {
    static let shared = CodeHighlighter()
    /// Files larger than this keep the plain preview; the backend itself
    /// only returns text for reasonably sized files.
    static let byteLimit = 1_024 * 1_024
    /// `highlightAuto` tries every grammar, so only run it on small files
    /// whose extension hljs does not recognize.
    private static let autoDetectByteLimit = 128 * 1_024

    private var context: JSContext?

    func highlight(_ code: String, fileName: String) -> sending NSAttributedString? {
        guard code.utf8.count <= Self.byteLimit, let context = loadContext() else { return nil }
        let language = language(for: fileName, in: context)
        guard language != nil || code.utf8.count <= Self.autoDetectByteLimit else { return nil }
        let function = context.objectForKeyedSubscript("todexHighlight" as NSString)
        var arguments: [Any] = [code]
        if let language { arguments.append(language) }
        let result = function?.call(withArguments: arguments)
        if context.exception != nil {
            context.exception = nil
            return nil
        }
        guard result?.isString == true, let html = result?.toString(), !html.isEmpty else { return nil }
        return render(html: html)
    }

    private func loadContext() -> JSContext? {
        if let context { return context }
        guard let url = Bundle.main.url(
            forResource: "highlight.min", withExtension: "js", subdirectory: "Chat"),
            let source = try? String(contentsOf: url, encoding: .utf8),
            let context = JSContext()
        else { return nil }
        context.evaluateScript(source)
        context.evaluateScript(
            "function todexHighlight(code, language) {"
                + "  if (language) return hljs.highlight(code, {language: language}).value;"
                + "  return hljs.highlightAuto(code).value;"
                + "}")
        guard context.exception == nil,
            context.objectForKeyedSubscript("hljs" as NSString)?.isObject == true
        else {
            context.exception = nil
            return nil
        }
        self.context = context
        return context
    }

    /// hljs `getLanguage` resolves aliases (yml, ts, html, plist…), so the
    /// tables below only cover names that are not part of the bundled build.
    private static let fileNames: [String: String] = [
        "makefile": "makefile",
        "gnumakefile": "makefile",
        "podfile": "ruby",
        "gemfile": "ruby",
        "rakefile": "ruby",
        "fastfile": "ruby",
        "brewfile": "ruby",
        "podspec": "ruby",
    ]
    private static let extensions: [String: String] = [
        "m": "objectivec",
        "toml": "ini",
        "env": "ini",
        "conf": "ini",
        "cfg": "ini",
        "properties": "ini",
        "xcconfig": "ini",
        "zsh": "bash",
        "ipynb": "json",
        "vue": "xml",
        "svelte": "xml",
        "storyboard": "xml",
        "xib": "xml",
        "entitlements": "xml",
        "gemspec": "ruby",
    ]
    private func language(for fileName: String, in context: JSContext) -> String? {
        let lower = fileName.lowercased()
        if let known = Self.fileNames[lower] { return known }
        let ext = (lower as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        if let known = Self.extensions[ext] { return known }
        let probe = context.objectForKeyedSubscript("hljs" as NSString)?
            .invokeMethod("getLanguage", withArguments: [ext])
        defer { context.exception = nil }
        return context.exception == nil && probe?.isUndefined == false ? ext : nil
    }

    // MARK: - hljs span markup → attributed string

    private static func rgb(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
        }
    }
    private static let keyword = rgb(0x7952A8, 0xC9A5EF)
    private static let string = rgb(0x087D68, 0x80D3B6)
    private static let number = rgb(0xAD5E27, 0xEFB684)
    private static let comment = rgb(0x7C8D96, 0x8E9DA5)
    /// Same class → color mapping as Chat/timeline.css; unmapped classes
    /// inherit the surrounding color.
    private static let colors: [String: UIColor] = [
        "keyword": keyword, "selector-tag": keyword, "type": keyword,
        "string": string, "attr": string, "built_in": string,
        "number": number, "literal": number, "title": number,
        "comment": comment, "quote": comment,
    ]
    /// Classes rendered italic in timeline.css.
    private static let italics: Set<String> = ["comment", "quote"]

    private nonisolated func render(html: String) -> NSAttributedString {
        let plain = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let italic = UIFont(
            descriptor: plain.fontDescriptor.withSymbolicTraits(.traitItalic) ?? plain.fontDescriptor,
            size: plain.pointSize)
        var font = plain
        var color = UIColor.label
        var stack: [(UIColor, UIFont)] = []
        var pending = ""
        let output = NSMutableAttributedString()
        func flush() {
            guard !pending.isEmpty else { return }
            output.append(
                NSAttributedString(
                    string: pending,
                    attributes: [.font: font, .foregroundColor: color]))
            pending = ""
        }
        var cursor = html.startIndex
        while cursor < html.endIndex {
            guard let next = html[cursor...].firstIndex(where: { $0 == "<" || $0 == "&" }) else {
                pending.append(contentsOf: html[cursor...])
                break
            }
            pending.append(contentsOf: html[cursor..<next])
            cursor = next
            if html[cursor] == "&" {
                if let end = html[cursor...].firstIndex(of: ";"),
                    html.distance(from: cursor, to: end) <= 10,
                    let decoded = Self.entity(html[cursor...end])
                {
                    pending.append(decoded)
                    cursor = html.index(after: end)
                } else {
                    pending.append("&")
                    cursor = html.index(after: cursor)
                }
                continue
            }
            guard let end = html[cursor...].firstIndex(of: ">") else {
                pending.append(contentsOf: html[cursor...])
                break
            }
            let tag = html[cursor...end]
            if tag.hasPrefix("<span") {
                flush()
                stack.append((color, font))
                let classes = Self.classes(in: tag)
                if let mapped = classes.lazy.compactMap({ Self.colors[$0] }).first {
                    color = mapped
                }
                if classes.contains(where: { Self.italics.contains($0) }) {
                    font = italic
                }
            } else if tag.hasPrefix("</") {
                flush()
                if let previous = stack.popLast() {
                    (color, font) = previous
                } else {
                    (color, font) = (.label, plain)
                }
            }
            cursor = html.index(after: end)
        }
        flush()
        return output
    }

    private static func classes(in tag: some StringProtocol) -> [String] {
        guard let start = tag.range(of: "class=\""),
            let end = tag[start.upperBound...].firstIndex(of: "\"")
        else { return [] }
        return tag[start.upperBound..<end].split(separator: " ").map {
            let name = $0.dropFirst($0.hasPrefix("hljs-") ? 5 : 0)
            return String(name)
        }
    }

    private static func entity(_ markup: some StringProtocol) -> Character? {
        switch markup {
        case "&amp;": return "&"
        case "&lt;": return "<"
        case "&gt;": return ">"
        case "&quot;": return "\""
        case "&apos;": return "'"
        default:
            guard markup.hasPrefix("&#"), markup.hasSuffix(";") else { return nil }
            let digits = markup.dropFirst(2).dropLast()
            let value =
                digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            return value.flatMap(Unicode.Scalar.init).map(Character.init)
        }
    }
}
