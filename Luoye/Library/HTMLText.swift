import Foundation

/// 正文段落里的几种特殊记号。段落仍是普通字符串，排版时再换成插图、注音和注释。
/// 用的是 Unicode 私用区字符，正常书里不会出现。
enum InlineMark {
    /// 整段是一张插图：「\u{E000}图片键」
    static let image: Character = "\u{E000}"
    /// 注音：「\u{E001}汉字\u{E002}读音\u{E003}」
    static let rubyStart: Character = "\u{E001}"
    /// 注释：「\u{E004}标号\u{E002}注释全文\u{E003}」
    static let noteStart: Character = "\u{E004}"
    static let separator: Character = "\u{E002}"
    static let end: Character = "\u{E003}"

    static func ruby(_ base: String, _ reading: String) -> String {
        "\(rubyStart)\(base)\(separator)\(reading)\(end)"
    }

    static func note(_ label: String, _ text: String) -> String {
        "\(noteStart)\(label)\(separator)\(text)\(end)"
    }

    /// 去掉记号，只留正文能看到的字：注音留汉字，注释留标号，插图去掉。
    static func plain(_ text: String) -> String {
        guard text.contains(where: { $0 >= image && $0 <= noteStart }) else { return text }
        if text.first == image { return "" }
        var result = "", skipping = false
        for character in text {
            switch character {
            case rubyStart, noteStart: skipping = false
            case separator: skipping = true
            case end: skipping = false
            default: if !skipping { result.append(character) }
            }
        }
        return result
    }
}

/// 从 XHTML 里取出标题和段落，丢掉标签和样式；插图、注音、注释换成 InlineMark 记号。
enum HTMLText {
    /// - Parameters:
    ///   - notes: 全书收集到的注释，键是元素 id
    ///   - resolveImage: 把 <img src> 换成取图用的键（如 EPUB 里的完整路径）
    static func paragraphs(
        fromXHTML html: String,
        notes: [String: String] = [:],
        resolveImage: (String) -> String = { $0 }
    ) -> (title: String?, paragraphs: [String]) {
        let heading = firstMatch("<h[1-3][^>]*>(.*?)</h[1-3]>", in: html)
            .map { stripTags(removeRubyText($0)) }?.trimmed
            ?? firstMatch("<title[^>]*>(.*?)</title>", in: html).map(stripTags)?.trimmed

        var body = html
        if let start = body.range(of: "<body", options: .caseInsensitive),
           let close = body[start.upperBound...].firstIndex(of: ">") {
            body = String(body[body.index(after: close)...])
        }
        body = replace("<(script|style)[^>]*>.*?</\\1>", in: body, with: "")
        // 注释正文已经收进 notes，从章节里拿掉，免得在章末再出现一遍。
        body = replace(noteBlockPattern, in: body, with: "")
        body = replaceNoteLinks(in: body, notes: notes)
        body = replaceRuby(in: body)
        body = replaceImages(in: body, resolve: resolveImage)
        body = replace("<br\\s*/?>", in: body, with: "\n")
        body = replace("</(p|div|h[1-6]|li|blockquote|section|tr|dd|dt)>", in: body, with: "\n")
        let paragraphs = stripTags(body)
            .components(separatedBy: "\n")
            .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{3000}"))).trimmed }
        return (heading, paragraphs)
    }

    // MARK: 注释

    /// 注释正文所在的元素：<aside>，或 class / epub:type 里带 footnote、endnote、note 字样的块。
    private static let noteBlockPattern =
        "<(aside|section|div|ol|ul|li|p|dl)\\b(?:[^>]*?(?:footnote|endnote|rearnote|epub:type=\"note\")[^>]*|[^>]*epub:type=\"[^\"]*note[^\"]*\"[^>]*)>.*?</\\1>|<aside\\b[^>]*>.*?</aside>"

    /// 从一个文件里找出所有注释：id → 注释文字。
    static func collectNotes(in html: String) -> [String: String] {
        let regex = try! NSRegularExpression(
            pattern: "<(aside|section|div|li|p|dd)\\b([^>]*\\bid=\"([^\"]+)\"[^>]*)>(.*?)</\\1>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        var notes: [String: String] = [:]
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let tag = Range(match.range(at: 1), in: html),
                  let attributes = Range(match.range(at: 2), in: html),
                  let id = Range(match.range(at: 3), in: html),
                  let inner = Range(match.range(at: 4), in: html)
            else { continue }
            let attrs = html[attributes].lowercased()
            guard html[tag].lowercased() == "aside" || attrs.contains("note") else { continue }
            // 注释开头常有一个回跳链接「[1]」，去掉它。
            let text = stripTags(replace("^\\s*<a\\b[^>]*>.*?</a>", in: String(html[inner]), with: ""))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmed
            if let text { notes[String(html[id])] = text }
        }
        return notes
    }

    /// 指向注释的链接 <a href="…#n1">1</a> 换成注释记号。
    private static func replaceNoteLinks(in body: String, notes: [String: String]) -> String {
        guard !notes.isEmpty else { return body }
        let regex = try! NSRegularExpression(
            pattern: "<a\\b[^>]*?href=\"[^\"#]*#([^\"]+)\"[^>]*>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        var result = body
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let id = Range(match.range(at: 1), in: result),
                  let inner = Range(match.range(at: 2), in: result),
                  let text = notes[String(result[id])]
            else { continue }
            var label = stripTags(String(result[inner])).trimmed ?? "注"
            label = label.trimmingCharacters(in: CharacterSet(charactersIn: "[]［］〔〕()（）"))
            result.replaceSubrange(whole, with: InlineMark.note(label.isEmpty ? "注" : label, text))
        }
        return result
    }

    // MARK: 注音

    private static func removeRubyText(_ html: String) -> String {
        replace("<(rt|rp)\\b[^>]*>.*?</\\1>", in: html, with: "")
    }

    /// <ruby>漢字<rt>かんじ</rt></ruby> 换成注音记号。
    private static func replaceRuby(in body: String) -> String {
        let regex = try! NSRegularExpression(pattern: "<ruby\\b[^>]*>(.*?)</ruby>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        let rt = try! NSRegularExpression(pattern: "<rt\\b[^>]*>(.*?)</rt>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        var result = body
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
            guard let whole = Range(match.range, in: result), let innerRange = Range(match.range(at: 1), in: result) else { continue }
            let inner = String(result[innerRange])
            let reading = rt.matches(in: inner, range: NSRange(inner.startIndex..., in: inner))
                .compactMap { Range($0.range(at: 1), in: inner).map { stripTags(String(inner[$0])) } }
                .joined()
            let base = stripTags(removeRubyText(inner))
            result.replaceSubrange(whole, with: reading.isEmpty ? base : InlineMark.ruby(base, reading))
        }
        return result
    }

    // MARK: 插图

    /// <img src> 和 SVG 里的 <image href> 换成单独一段插图记号。
    private static func replaceImages(in body: String, resolve: (String) -> String) -> String {
        let regex = try! NSRegularExpression(
            pattern: "<img\\b[^>]*?\\bsrc=\"([^\"]+)\"[^>]*>|<image\\b[^>]*?\\b(?:xlink:)?href=\"([^\"]+)\"[^>]*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        var result = body
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
            guard let whole = Range(match.range, in: result) else { continue }
            let source = [1, 2].lazy.compactMap { Range(match.range(at: $0), in: result) }.first.map { String(result[$0]) }
            guard let source else { continue }
            result.replaceSubrange(whole, with: "\n\(InlineMark.image)\(resolve(source.removingPercentEncoding ?? source))\n")
        }
        return result
    }

    // MARK: 通用

    static func stripTags(_ text: String) -> String {
        decodeEntities(replace("<[^>]+>", in: text, with: ""))
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&hellip;": "…",
                                "&mdash;": "—", "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’"] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        for match in numeric.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let hexFlag = Range(match.range(at: 1), in: result),
                  let digits = Range(match.range(at: 2), in: result),
                  let code = UInt32(result[digits], radix: result[hexFlag].isEmpty ? 10 : 16),
                  let scalar = Unicode.Scalar(code)
            else { continue }
            result.replaceSubrange(whole, with: String(Character(scalar)))
        }
        // &amp; 最后处理，避免把 &amp;lt; 解成 <。
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
