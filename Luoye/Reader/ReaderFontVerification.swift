#if DEBUG
import UIKit
import CoreText

/// Opt-in native check; fixture fonts and all output stay in the simulator's temporary directory.
@MainActor enum ReaderFontVerification {
    static func run() {
        var results: [[String: Any]] = []
        func check(_ value: Bool, _ title: String) {
            results.append(["passed": value, "title": title])
            print("READER_FONT \(value ? "PASS" : "FAIL") \(title)")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "font-identity-fixture")
        let a = root.appending(path: "a.otf"), b = root.appending(path: "b.otf")
        func glyph(_ font: CTFont) -> CGGlyph {
            var character: UniChar = 0xE4C2, glyph: CGGlyph = 0
            CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            return glyph
        }
        func fileFont(_ url: URL) -> CTFont? {
            guard let provider = CGDataProvider(url: url as CFURL), let cg = CGFont(provider) else { return nil }
            return CTFontCreateWithGraphicsFont(cg, 20, nil, nil)
        }
        func bodyFont(_ style: ReaderStyle, short: Bool = false) -> UIFont {
            let paragraph = short ? "\u{E4C2}" : "\u{E4C2}。这是一段用于测试字体映射的自写正文。"
            let text = style.attributedText(for: Chapter(id: 0, title: "测试", paragraphs: [paragraph]))
            return text.attribute(.font, at: 3, effectiveRange: nil) as! UIFont
        }
        func shapedGlyph(_ style: ReaderStyle) -> CGGlyph {
            let text = style.attributedText(for: Chapter(id: 0, title: "测试", paragraphs: ["\u{E4C2}。自写正文。"] ))
            let body = text.attributedSubstring(from: NSRange(location: 3, length: text.length - 3))
            let line = CTLineCreateWithAttributedString(body)
            guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first, CTRunGetGlyphCount(run) > 0 else { return 0 }
            var glyph: CGGlyph = 0
            CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
            return glyph
        }
        if let expectedA = fileFont(a), let expectedB = fileFont(b) {
            let ga = glyph(expectedA), gb = glyph(expectedB)
            let nameA = CTFontCopyPostScriptName(expectedA) as String
            let nameB = CTFontCopyPostScriptName(expectedB) as String
            check(nameA == nameB && ga != 0 && gb != 0 && ga != gb, "fixtures share font name but map the same code point differently")
            CTFontManagerRegisterFontsForURL(a as CFURL, .process, nil)
            CTFontManagerRegisterFontsForURL(b as CFURL, .process, nil)
            if let byName = UIFont(name: nameA, size: 20) {
                check(glyph(byName as CTFont) != ga || glyph(byName as CTFont) != gb, "name-only font resolution cannot represent both chapter fonts")
            } else { check(false, "name-only fixture font resolves") }
            var sa = ReaderStyle(fontSize: 20, lineHeight: 1.85, scheme: .light, bodyFontURL: a, recognizesByline: false)
            var sb = ReaderStyle(fontSize: 20, lineHeight: 1.85, scheme: .light, bodyFontURL: b, recognizesByline: false)
            check(glyph(bodyFont(sa) as CTFont) == ga, "chapter A renders with its own font file")
            check(glyph(bodyFont(sb) as CTFont) == gb, "chapter B renders with its own font file despite duplicate name")
            check(glyph(bodyFont(sa) as CTFont) == ga, "returning to chapter A restores its font mapping")
            check(shapedGlyph(sa) == ga, "CoreText shapes chapter A using its file mapping")
            check(shapedGlyph(sb) == gb, "CoreText shapes chapter B using its file mapping")
            sa.fontSize = 28; sb.fontSize = 14
            check(glyph(bodyFont(sa) as CTFont) == ga && bodyFont(sa).pointSize == 28, "chapter A preserves mapping when enlarged")
            check(glyph(bodyFont(sb) as CTFont) == gb && bodyFont(sb).pointSize == 14, "chapter B preserves mapping when reduced")
            check(glyph(bodyFont(sa, short: true) as CTFont) == ga, "short first paragraph preserves the chapter font")
            let regular = ReaderStyle(fontSize: 19, lineHeight: 1.85, scheme: .light)
            check(bodyFont(regular).fontName == "NotoSerifSC-Regular", "local reader still uses bundled body font")
            let byline = regular.attributedText(for: Chapter(id: 0, title: "测试", paragraphs: ["陶渊明", "自写正文。"] ))
            check((byline.attribute(.font, at: 3, effectiveRange: nil) as? UIFont)?.pointSize == 19 * 0.85, "local book byline styling remains available")
            let plain = ReaderStyle(fontSize: 20, lineHeight: 1.85, scheme: .light, recognizesByline: false)
            check(bodyFont(plain, short: true).pointSize == 20, "plain website short paragraph is not reduced or centered as a byline")
        } else { check(false, "font fixtures available") }
        let success = results.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["success": success, "checks": results]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeReaderFontVerification.json"), options: .atomic)
        }
    }
}
#endif
