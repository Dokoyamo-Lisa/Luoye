import Foundation

/// 读 FB2（FictionBook）：一种 XML 电子书，正文按 <section> 分章，图片以 base64 内嵌在 <binary> 里。
struct FB2Reader {
    enum FB2Error: Error { case notFB2 }

    let title: String
    let author: String
    let coverKey: String?
    /// 各章：标题（可能没有）和改写成普通 HTML 的正文
    let sections: [(title: String?, html: String)]
    /// 注释：id → 文字（FB2 的注释放在 <body name="notes"> 里）
    let notes: [String: String]
    private let binaries: [String: Data]

    init(data: Data) throws {
        let text = Self.decode(data)
        guard text.contains("<FictionBook") else { throw FB2Error.notFB2 }

        let info = HTMLText.firstMatch("<title-info>(.*?)</title-info>", in: text) ?? ""
        title = HTMLText.firstMatch("<book-title>(.*?)</book-title>", in: info).map(HTMLText.stripTags)?.trimmed ?? ""
        let authorXML = HTMLText.firstMatch("<author>(.*?)</author>", in: info) ?? ""
        let nameParts = ["last-name", "first-name", "middle-name"].compactMap {
            HTMLText.firstMatch("<\($0)>(.*?)</\($0)>", in: authorXML).map(HTMLText.stripTags)?.trimmed
        }
        // 中日文名字姓在前、不加空格；西文名字名在前、空格隔开。
        let isCJK = nameParts.joined().unicodeScalars.contains { $0.value >= 0x3040 }
        author = (isCJK ? nameParts.prefix(2).joined() : nameParts.dropFirst().prefix(1).joined() + " " + (nameParts.first ?? ""))
            .trimmingCharacters(in: .whitespaces)
        coverKey = HTMLText.firstMatch("<coverpage>.*?href=\"#([^\"]+)\"", in: info)

        var binaries: [String: Data] = [:]
        let binary = try! NSRegularExpression(pattern: "<binary\\b[^>]*\\bid=\"([^\"]+)\"[^>]*>(.*?)</binary>", options: .dotMatchesLineSeparators)
        for match in binary.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let id = Range(match.range(at: 1), in: text), let content = Range(match.range(at: 2), in: text),
                  let decoded = Data(base64Encoded: String(text[content]), options: .ignoreUnknownCharacters)
            else { continue }
            binaries[String(text[id])] = decoded
        }
        self.binaries = binaries

        // 先找注释（<body name="notes"> 里每个带 id 的 section），再处理正文。
        let notesBody = HTMLText.firstMatch("<body\\b[^>]*name=\"(?:notes|comments)\"[^>]*>(.*?)</body>", in: text) ?? ""
        var notes: [String: String] = [:]
        let noteSection = try! NSRegularExpression(pattern: "<section\\b[^>]*\\bid=\"([^\"]+)\"[^>]*>(.*?)</section>", options: .dotMatchesLineSeparators)
        for match in noteSection.matches(in: notesBody, range: NSRange(notesBody.startIndex..., in: notesBody)) {
            guard let id = Range(match.range(at: 1), in: notesBody), let inner = Range(match.range(at: 2), in: notesBody) else { continue }
            let withoutTitle = HTMLText.replace("<title>.*?</title>", in: String(notesBody[inner]), with: "")
            if let note = HTMLText.stripTags(withoutTitle).replacingOccurrences(of: "\n", with: " ").trimmed {
                notes[String(notesBody[id])] = note
            }
        }
        self.notes = notes

        let mainBody = HTMLText.firstMatch("<body(?![^>]*name=\"(?:notes|comments)\")[^>]*>(.*?)</body>", in: text) ?? ""
        sections = Self.splitSections(Self.toHTML(mainBody))
    }

    func image(_ key: String) -> Data? { binaries[key] }

    /// FB2 的标签改写成 HTMLText 认得的样子：图片、注释链接、空行。
    private static func toHTML(_ xml: String) -> String {
        var html = xml
        html = HTMLText.replace("<image\\b[^>]*href=\"#([^\"]+)\"[^>]*/?>", in: html, with: "<img src=\"$1\"/>")
        html = HTMLText.replace("<a\\b[^>]*href=\"(#[^\"]+)\"[^>]*>", in: html, with: "<a href=\"$1\">")
        html = HTMLText.replace("<empty-line\\s*/>", in: html, with: "<br/>")
        html = HTMLText.replace("</(v|subtitle|text-author)>", in: html, with: "</p>")
        return html
    }

    /// 按 <section> 切章：只取直接装着段落的那一层。
    private static func splitSections(_ html: String) -> [(String?, String)] {
        let chunks = html.components(separatedBy: "<section")
        return chunks.compactMap { chunk in
            let content = chunk.components(separatedBy: "</section>").first ?? chunk
            guard content.contains("<p") || content.contains("<img") else { return nil }
            let title = HTMLText.firstMatch("<title>(.*?)</title>", in: content).map(HTMLText.stripTags)?
                .replacingOccurrences(of: "\n", with: " ").trimmed
            return (title, HTMLText.replace("<title>.*?</title>", in: content, with: ""))
        }
    }

    /// 按文件开头声明的编码解码，声明缺失时交给 TextDecoding 猜。
    private static func decode(_ data: Data) -> String {
        let head = String(decoding: data.prefix(200), as: UTF8.self).lowercased()
        if let name = HTMLText.firstMatch("encoding=\"([^\"]+)\"", in: head) {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return text
            }
        }
        return TextDecoding.decode(data) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Markdown：一级、二级标题分章，空行分段，去掉加粗、链接等标记。
enum MarkdownText {
    static func chapters(_ text: String, bookTitle: String) -> [(String, [String])] {
        var chapters: [(String, [String])] = []
        var title: String?
        var paragraphs: [String] = []
        var current = ""
        var inCode = false

        func endParagraph() {
            if let line = clean(current).trimmed { paragraphs.append(line) }
            current = ""
        }
        func endChapter() {
            endParagraph()
            if !paragraphs.isEmpty || title != nil { chapters.append((title ?? bookTitle, paragraphs)) }
            paragraphs = []
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); endParagraph(); continue }
            if inCode { paragraphs.append(rawLine); continue }
            if let heading = line.wholeMatch(of: /^(#{1,2})\s+(.+?)\s*#*$/) {
                endChapter()
                title = clean(String(heading.2))
            } else if line.isEmpty || line.wholeMatch(of: /^([-*_]\s*){3,}$/) != nil {
                endParagraph()
            } else {
                // 更低级的标题、列表、引用各自成段
                if line.hasPrefix("#") || line.hasPrefix(">") || line.wholeMatch(of: /^([-*+]|\d+\.)\s+.*/) != nil {
                    endParagraph()
                }
                current += current.isEmpty ? line : " " + line
            }
        }
        endChapter()
        return chapters
    }

    private static func clean(_ text: String) -> String {
        var result = text
        result = result.replacing(/^#{1,6}\s+/, with: "")
        result = result.replacing(/^>\s?/, with: "")
        result = result.replacing(/^[-*+]\s+/, with: "· ")
        result = result.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        result = result.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.1) }
        result = result.replacing(/(\*\*|__)(.+?)\1/) { String($0.2) }
        result = result.replacing(/(\*|_)(.+?)\1/) { String($0.2) }
        result = result.replacing(/`([^`]+)`/) { String($0.1) }
        return result
    }
}
