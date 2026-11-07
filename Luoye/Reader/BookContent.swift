import Foundation

/// 一章：标题和若干段落。段落里可能夹着插图、注音、注释记号（见 InlineMark）。
struct Chapter: Identifiable {
    let id: Int
    let title: String
    let paragraphs: [String]

    /// 本章正文大约多少字（统计阅读字数用）
    var characterCount: Int { paragraphs.reduce(0) { $0 + $1.count } }
}

/// 一本书的正文，按章节排好。
struct BookContent {
    let chapters: [Chapter]
    /// 按插图记号里的键取出图片数据
    let image: (String) -> Data?

    enum LoadError: Error {
        case unreadableText
        case empty
    }

    /// 读文件比较慢，放在后台调用。
    static func load(fileURL: URL, format: String, title: String) throws -> BookContent {
        var chapters: [(String, [String])]
        var image: (String) -> Data? = { _ in nil }
        switch format {
        case "epub":
            let zip = try ZipReader(url: fileURL)
            chapters = try epubChapters(zip)
            image = { try? zip.read($0) }
        case "mobi":
            let mobi = try MobiReader(data: Data(contentsOf: fileURL, options: .mappedIfSafe))
            chapters = htmlChapters(mobi.documents.map { (nil, $0) }, notes: [:])
            image = mobi.image
        case "fb2":
            let fb2 = try FB2Reader(data: Data(contentsOf: fileURL))
            chapters = htmlChapters(fb2.sections, notes: fb2.notes)
            image = fb2.image
        case "md":
            guard let text = TextDecoding.decode(try Data(contentsOf: fileURL)) else { throw LoadError.unreadableText }
            chapters = MarkdownText.chapters(text, bookTitle: title)
        default:
            guard let text = TextDecoding.decode(try Data(contentsOf: fileURL)) else { throw LoadError.unreadableText }
            chapters = textChapters(text, bookTitle: title)
        }

        // 整本书只切出一章（没有分页符的 MOBI 之类），按 TXT 的办法再认一次章节标题。
        if chapters.count == 1, format != "txt" {
            chapters = textChapters(chapters[0].1.joined(separator: "\n"), bookTitle: chapters[0].0)
        }

        let result = chapters.enumerated().map { index, chapter in
            // 正文第一段就是章名时去掉，避免标题出现两遍。
            let (title, paragraphs) = chapter
            let body = paragraphs.first.map(InlineMark.plain) == title ? Array(paragraphs.dropFirst()) : paragraphs
            return Chapter(id: index, title: title, paragraphs: body)
        }
        guard !result.isEmpty else { throw LoadError.empty }
        return BookContent(chapters: result, image: image)
    }

    // MARK: TXT

    /// 没有章节标题的长文，每这么多字切成一节，翻页排版不至于太慢。
    private static let sectionLength = 6000

    static func textChapters(_ text: String, bookTitle: String) -> [(String, [String])] {
        let custom = ChapterRules.customPattern
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\u{3000}"))) }
            .filter { !$0.isEmpty }

        var chapters: [(String, [String])] = []
        var title: String?
        var paragraphs: [String] = []
        func flush() {
            if !paragraphs.isEmpty || title != nil {
                chapters.append((title ?? "", paragraphs))
            }
            paragraphs = []
        }
        for line in lines {
            if ChapterRules.isHeading(InlineMark.plain(line), custom: custom) {
                flush()
                title = InlineMark.plain(line)
            } else {
                paragraphs.append(line)
            }
        }
        flush()

        // 一个章节标题都没找到：短文整篇算一章，长文按字数切成几节。
        if chapters.count == 1, chapters[0].0.isEmpty {
            return splitIntoSections(chapters[0].1, bookTitle: bookTitle)
        }
        // 第一个标题之前若只是一行书名、作者之类，直接略过；有实际内容（如简介）才单独成一章「前言」。
        if let first = chapters.first, first.0.isEmpty, first.1.joined().count <= 30 {
            chapters.removeFirst()
        }
        return chapters.map { ($0.0.isEmpty ? "前言" : $0.0, $0.1) }
    }

    private static func splitIntoSections(_ paragraphs: [String], bookTitle: String) -> [(String, [String])] {
        var sections: [[String]] = [[]]
        var length = 0
        for paragraph in paragraphs {
            if length > sectionLength {
                sections.append([])
                length = 0
            }
            sections[sections.count - 1].append(paragraph)
            length += paragraph.count
        }
        if sections.count == 1 { return [(bookTitle, sections[0])] }
        return sections.enumerated().map { ("第\($0.offset + 1)节", $0.element) }
    }

    // MARK: EPUB、MOBI、FB2

    private static func epubChapters(_ zip: ZipReader) throws -> [(String, [String])] {
        let package = try EPUBPackage(zip: zip)
        // 解压和 XHTML 解析都耗 CPU。限制并发数，避免长书同时展开过多章节占满内存。
        let documents = parallelMap(package.spine) { path in
            (try? zip.read(path)).map { (path, String(decoding: $0, as: UTF8.self)) }
        }.compactMap { $0 }
        // 注释常常集中在书末的单独文件里，先把全书的注释收齐。
        let notes = documents.reduce(into: [String: String]()) { all, document in
            all.merge(HTMLText.collectNotes(in: document.1)) { first, _ in first }
        }

        let parsed = parallelMap(documents) { path, html in
            let directory = (path as NSString).deletingLastPathComponent
            return HTMLText.paragraphs(fromXHTML: html, notes: notes) { source in
                let joined = directory.isEmpty ? source : directory + "/" + source
                return (joined as NSString).standardizingPath
            }
        }
        var chapters: [(String, [String])] = []
        for (heading, paragraphs) in parsed {
            // 只有一张图的页（封面、彩页）也保留；什么都没有的页跳过。
            guard !paragraphs.isEmpty else { continue }
            let onlyImages = paragraphs.allSatisfy { $0.first == InlineMark.image }
            chapters.append((heading ?? (onlyImages ? "插图" : "第\(chapters.count + 1)节"), paragraphs))
        }
        return chapters
    }

    /// 按输入顺序返回结果；最多四个 worker，避免每章各起一个线程。
    private static func parallelMap<Input, Output>(
        _ inputs: [Input],
        transform: @escaping (Input) -> Output
    ) -> [Output] {
        guard inputs.count > 1 else { return inputs.map(transform) }
        let lock = NSLock()
        var nextIndex = 0
        var results = Array<Output?>(repeating: nil, count: inputs.count)
        let workers = min(4, ProcessInfo.processInfo.activeProcessorCount, inputs.count)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                lock.lock()
                let index = nextIndex
                nextIndex += 1
                lock.unlock()
                guard index < inputs.count else { break }
                let result = transform(inputs[index])
                lock.lock()
                results[index] = .some(result)
                lock.unlock()
            }
        }
        return results.map { $0! }
    }

    private static func htmlChapters(_ documents: [(String?, String)], notes: [String: String]) -> [(String, [String])] {
        let parsed = parallelMap(documents) { title, html in
            (title, HTMLText.paragraphs(fromXHTML: html, notes: notes))
        }
        var chapters: [(String, [String])] = []
        for (title, (heading, paragraphs)) in parsed {
            guard !paragraphs.isEmpty else { continue }
            // 没有标题时，看第一段是不是像章名。
            let first = paragraphs.first.map(InlineMark.plain)
            let guess = first.flatMap { ChapterRules.isHeading($0, custom: nil) ? $0 : nil }
            chapters.append((title ?? heading ?? guess ?? "第\(chapters.count + 1)节", paragraphs))
        }
        return chapters
    }
}
