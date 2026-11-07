import Foundation
import SwiftSoup
import CoreText
import CoreGraphics
import CryptoKit

/// Public website catalog and readable chapter extraction, with independent local caches.
actor TomatoPublicCatalog {
    private let session: URLSession
    private let directory: URL
    private var lastDirectory = Date.distantPast
    private var readingGeneration = UUID()
    private var websiteCookieSignature: [String]?
    init(session: URLSession = URLSession(configuration: .ephemeral), directory: URL = URL.applicationSupportDirectory.appending(path: "HaikuTomato/Catalog")) {
        self.session = session; self.directory = directory
    }
    func cached(_ id: String) -> TomatoDetail? {
        guard TomatoBookID.valid(id), let data = try? Data(contentsOf: directory.appending(path: id + ".json")) else { return nil }
        return try? JSONDecoder().decode(TomatoDetail.self, from: data)
    }
    func detail(_ id: String) async throws -> TomatoDetail {
        guard TomatoBookID.valid(id) else { throw TomatoError.message("请粘贴番茄小说书号或书籍链接。") }
        let html = try await fetch(URL(string: "https://fanqienovel.com/page/" + id)!)
        var book = try Self.parseBook(html: String(decoding: html, as: UTF8.self), id: id)
        let reserved = max(Date(), lastDirectory.addingTimeInterval(0.8)); lastDirectory = reserved
        if reserved > Date() { try await Task.sleep(for: .seconds(reserved.timeIntervalSinceNow)) }
        var components = URLComponents(string: "https://fanqienovel.com/api/reader/directory/detail")!
        components.queryItems = [.init(name: "bookId", value: id)]
        let data = try await fetch(components.url!)
        let chapters = try Self.parseChapters(data)
        book.chapterCount = chapters.count
        let result = TomatoDetail(book: book, chapters: chapters)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: directory.appending(path: id + ".json"), options: .atomic)
        return result
    }
    func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://fanqienovel.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count < 12_000_000 else {
            throw TomatoError.message("番茄书目暂时无法读取，请稍后重试。")
        }
        return data
    }
    static func parseBook(html: String, id: String) throws -> TomatoBook {
        let doc = try SwiftSoup.parse(html)
        var root: Any?
        if let script = try doc.select("script#__NEXT_DATA__").first() { root = try? JSONSerialization.jsonObject(with: Data(try script.html().utf8)) }
        if root == nil, let range = html.range(of: #"window\.__INITIAL_STATE__\s*=\s*"#, options: .regularExpression),
           let json = jsonObject(in: String(html[range.upperBound...])) {
            root = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        }
        let state = root ?? [:]
        let title = findString(state, keys: ["bookName", "book_name"]) ?? (try? doc.select("h1").first()?.text()) ?? ""
        guard !title.isEmpty else { throw TomatoError.message("没有找到书目信息，书籍可能不可用，或页面需要验证。") }
        let author = findString(state, keys: ["authorName", "author_name", "author"]) ?? (try? doc.select(".author-name-text").first()?.text()) ?? ""
        let summary = findString(state, keys: ["abstract", "description", "intro"]) ?? (try? doc.select(".page-abstract-content").first()?.text()) ?? ""
        let cover = findString(state, keys: ["thumbUrl", "thumbUri", "thumb_url", "cover_url", "cover", "detail_page_thumb_url"]) ?? (try? doc.select(".book-cover img, .page-header-cover img").first()?.attr("src"))
        return TomatoBook(id: id, title: title, author: author, summary: summary, cover: cover)
    }
    static func parseChapters(_ data: Data) throws -> [TomatoChapter] {
        let object = try JSONSerialization.jsonObject(with: data)
        if let dict = object as? [String: Any], let code = dict["code"] as? Int, code != 0 {
            throw TomatoError.message("番茄目录暂时不可用，请稍后刷新。")
        }
        var result: [TomatoChapter] = [], seen = Set<String>()
        func collect(_ value: Any) {
            if let array = value as? [Any] { for item in array { collect(item) } }
            else if let item = value as? [String: Any] {
                let id = ["itemId", "item_id", "chapterId", "chapter_id"].compactMap { string(item[$0]) }.first
                let title = ["title", "chapterTitle", "chapter_name"].compactMap { string(item[$0]) }.first
                if let id, let title, !title.isEmpty, seen.insert(id).inserted { result.append(.init(id: id, title: title)); return }
                for key in ["data", "chapterListWithVolume", "chapterList", "chapter_list", "list", "items", "chapters"] {
                    if let nested = item[key] { collect(nested) }
                }
            }
        }
        collect(object)
        guard !result.isEmpty else { throw TomatoError.message("未取得章节目录。已缓存的目录会继续保留。") }
        return result
    }
    static func findString(_ root: Any, keys: [String]) -> String? {
        if let object = root as? [String: Any] {
            for key in keys { if let value = string(object[key]), !value.isEmpty { return value } }
            for key in object.keys.sorted() { if let found = findString(object[key]!, keys: keys) { return found } }
        } else if let array = root as? [Any] { for item in array { if let found = findString(item, keys: keys) { return found } } }
        return nil
    }
    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    static func jsonObject(in text: String) -> String? {
        var depth = 0, inString = false, escaped = false
        guard text.first == "{" else { return nil }
        for index in text.indices {
            let c = text[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(text[...index]) } }
        }
        return nil
    }
}

extension TomatoPublicCatalog {
    func useCookies(_ cookies: [HTTPCookie]) {
        let signature = cookies.map { "\($0.domain)|\($0.path)|\($0.name)|\($0.value)" }.sorted()
        if let previous = websiteCookieSignature, signature != previous {
            clearSessionReadingCache()
        }
        websiteCookieSignature = signature
        let storage = session.configuration.httpCookieStorage
        for old in storage?.cookies ?? [] { storage?.deleteCookie(old) }
        for cookie in cookies { storage?.setCookie(cookie) }
    }
    func clearSessionReadingCache() {
        readingGeneration = UUID()
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix("chapter-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
    func cachedRecommendations(_ section: TomatoHomeSection) -> [TomatoBook]? {
        let file = directory.appending(path: "home-\(section.rawValue).json")
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([TomatoBook].self, from: data), !saved.isEmpty else { return nil }
        return saved
    }
    func fontURL(for page: TomatoReadingPage) -> URL? {
        guard let name = page.fontFile, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return nil }
        return directory.appending(path: name)
    }
    func recommendations(_ section: TomatoHomeSection, refresh: Bool = false) async throws -> [TomatoBook] {
        let file = directory.appending(path: "home-\(section.rawValue).json")
        if !refresh, let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < 3600, let saved = cachedRecommendations(section) { return saved }
        let html = String(decoding: try await fetch(URL(string: "https://fanqienovel.com/" + section.path)!), as: UTF8.self)
        let ids = try Self.recommendationIDs(html)
        // Book pages expose readable metadata; ranking cards use the website's custom font encoding.
        // Resolve at most three pages at a time and retain the website's order.
        var indexed: [(Int, TomatoBook)] = []
        for start in stride(from: 0, to: min(12, ids.count), by: 3) {
            try Task.checkCancellation()
            let end = min(start + 3, min(12, ids.count))
            let batch = await withTaskGroup(of: (Int, TomatoBook)?.self) { group in
                for index in start..<end {
                    let id = ids[index]
                    group.addTask {
                        do {
                            let data = try await self.fetch(URL(string: "https://fanqienovel.com/page/" + id)!)
                            let book = try Self.parseBook(html: String(decoding: data, as: UTF8.self), id: id)
                            return (index, book)
                        } catch { return nil }
                    }
                }
                var result: [(Int, TomatoBook)] = []
                for await item in group { if let item { result.append(item) } }
                return result
            }
            indexed += batch
        }
        try Task.checkCancellation()
        let books = indexed.sorted { $0.0 < $1.0 }.map(\.1)
        guard !books.isEmpty else { throw TomatoError.message("官网推荐暂时无法读取，请稍后重试，或通过书号打开。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(books).write(to: file, options: .atomic)
        return books
    }
    static func recommendationIDs(_ html: String) throws -> [String] {
        let doc = try SwiftSoup.parse(html)
        var seen = Set<String>()
        return try doc.select("a[href]").array().compactMap { element in
            let href = try element.attr("href")
            guard let url = URL(string: href, relativeTo: URL(string: "https://fanqienovel.com")),
                  let id = TomatoBookID.parse(url.absoluteURL.absoluteString), seen.insert(id).inserted else { return nil }
            return id
        }
    }
    func chapter(_ id: String, refresh: Bool = false) async throws -> TomatoReadingPage {
        guard TomatoBookID.valid(id) else { throw TomatoError.message("章节标识无效。") }
        let generation = readingGeneration
        let file = directory.appending(path: "chapter-\(id).json")
        if !refresh, let data = try? Data(contentsOf: file), let page = try? JSONDecoder().decode(TomatoReadingPage.self, from: data), !page.paragraphs.isEmpty {
            if let name = page.fontFile, !name.contains("/"), !name.contains("\\"),
               let restored = try? Self.registerFont(directory.appending(path: name)) {
                return TomatoReadingPage(title: page.title, paragraphs: page.paragraphs, fontName: restored, fontFile: name)
            }
            if page.fontFile == nil, !Self.needsWebsiteFont(page.paragraphs) { return page }
            // Missing or corrupt font caches must fall through to the network recovery path.
        }
        let html = String(decoding: try await fetch(URL(string: "https://fanqienovel.com/reader/" + id)!), as: UTF8.self)
        let parsed = try Self.cleanChapter(html)
        var fontName: String?, fontFile: String?
        if let fontURL = parsed.fontURL {
            // Preserve the public page's font so encoded glyphs render correctly in native Text.
            let digest = SHA256.hash(data: Data(fontURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            let name = "font-" + digest + ".otf"
            let local = directory.appending(path: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: local.path), let registered = try? Self.registerFont(local) {
                fontName = registered
            } else {
                try? FileManager.default.removeItem(at: local)
                let data = try await fetch(fontURL)
                try Task.checkCancellation()
                try data.write(to: local, options: .atomic)
                do { fontName = try Self.registerFont(local) }
                catch { try? FileManager.default.removeItem(at: local); throw error }
            }
            fontFile = name
        }
        if Self.needsWebsiteFont(parsed.paragraphs), fontName == nil {
            throw TomatoError.message("该章节需要官网字体，暂时无法提纯为可读正文，请重试。")
        }
        let page = TomatoReadingPage(title: parsed.title, paragraphs: parsed.paragraphs, fontName: fontName, fontFile: fontFile)
        try Task.checkCancellation()
        guard readingGeneration == generation else { throw TomatoError.message("官网会话已变更，请重试读取章节。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(page).write(to: file, options: .atomic)
        return page
    }
    private static func needsWebsiteFont(_ paragraphs: [String]) -> Bool {
        paragraphs.contains { $0.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) } }
    }
    static func cleanChapter(_ html: String) throws -> (title: String, paragraphs: [String], fontURL: URL?) {
        if let range = html.range(of: #"window\.__INITIAL_STATE__\s*=\s*"#, options: .regularExpression),
           let json = jsonObject(in: String(html[range.upperBound...])),
           let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let reader = root["reader"] as? [String: Any], let chapter = reader["chapterData"] as? [String: Any] {
            if chapter["isChapterLock"] as? Bool == true || (chapter["needPay"] as? Int ?? 0) != 0 {
                throw TomatoError.message("此章节需要官网授权，请先登录官网；落叶只读取当前可访问的正文。")
            }
        }
        let doc = try SwiftSoup.parse(html)
        let paragraphs = try doc.select(".muye-reader-content p").array().map { try $0.text() }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !paragraphs.isEmpty else { throw TomatoError.message("未找到可阅读正文，请先在官网完成登录或验证，再重试。") }
        let title = try doc.select(".muye-reader-title").first()?.text() ?? "正文"
        var fontURL: URL?
        // Only the known public font CDN and OpenType format are accepted; no site scripts/styles are executed.
        for style in try doc.select("style").array() {
            let css = try style.html()
            if let range = css.range(of: #"https://[a-zA-Z0-9.-]+\.bytetos\.com/[a-zA-Z0-9/_-]+\.otf"#, options: .regularExpression) { fontURL = URL(string: String(css[range])); break }
        }
        return (title, paragraphs, fontURL)
    }
    static func registerFont(_ url: URL) throws -> String {
        guard let provider = CGDataProvider(url: url as CFURL), let font = CGFont(provider), let name = font.postScriptName else { throw TomatoError.message("官网字体暂时不可用，请重试。") }
        // Validate only. ReaderStyle creates a font directly from this file, avoiding global name collisions.
        return name as String
    }
}
