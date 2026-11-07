import Foundation

struct MangaImageRequest: Hashable, Sendable {
    let url: URL
    var headers: [String: String] = [:]
    var processor: MangaScriptRuntime? = nil
    var processingKey: String? = nil
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url && lhs.headers == rhs.headers && lhs.processor?.identifier == rhs.processor?.identifier && lhs.processingKey == rhs.processingKey }
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(processor?.identifier)
        hasher.combine(processingKey)
        for key in headers.keys.sorted() { hasher.combine(key); hasher.combine(headers[key]) }
    }
}

struct MangaOnlineComic: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String
    let coverURL: URL?
    let source: String
    var favoriteID: String? = nil

    struct Identity: Hashable, Sendable {
        let source: String
        let id: String
    }
    var identity: Identity { Identity(source: source, id: id) }
}

struct MangaOnlineChapter: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let language: String
    let group: String
    let pageCount: Int
    let externalURL: URL?
    var comicID: String? = nil
}

protocol MangaCatalogSource: Sendable {
    var id: String { get }
    var displayName: String { get }
    var chapterPageSize: Int? { get }
    func discover(page: Int) async throws -> [MangaOnlineComic]
    func search(_ query: String, page: Int) async throws -> [MangaOnlineComic]
    func chapters(for comic: MangaOnlineComic, page: Int) async throws -> [MangaOnlineChapter]
    func refreshChapters(for comic: MangaOnlineComic) async throws -> [MangaOnlineChapter]
    func pages(for chapter: MangaOnlineChapter) async throws -> [MangaImageRequest]
}

extension MangaCatalogSource {
    var chapterPageSize: Int? { 100 }
    func refreshChapters(for comic: MangaOnlineComic) async throws -> [MangaOnlineChapter] { try await chapters(for: comic, page: 1) }
}

/// Native MangaDex adapter. Other manga sources can conform to MangaCatalogSource.
struct MangaDexSource: MangaCatalogSource {
    let id = "mangadex"
    let displayName = "MangaDex"
    private let base = URL(string: "https://api.mangadex.org")!

    func discover(page: Int) async throws -> [MangaOnlineComic] {
        try await mangaList(query: nil, page: page)
    }

    func search(_ query: String, page: Int) async throws -> [MangaOnlineComic] {
        try await mangaList(query: query, page: page)
    }

    struct Category: Identifiable, Sendable {
        let id: String
        let name: String
        let group: String
    }
    func categories() async throws -> [Category] {
        let response = try await request("manga/tag")
        return (response["data"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = value["id"] as? String, let attributes = value["attributes"] as? [String: Any],
                  let names = attributes["name"] as? [String: String],
                  let name = names["zh"] ?? names["zh-hk"] ?? names["en"] ?? names.values.first else { return nil }
            return Category(id: id, name: name, group: attributes["group"] as? String ?? "genre")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func category(_ id: String, page: Int) async throws -> [MangaOnlineComic] {
        try await mangaList(query: nil, page: page, tagID: id)
    }

    func chapters(for comic: MangaOnlineComic, page: Int) async throws -> [MangaOnlineChapter] {
        var result: [MangaOnlineChapter] = []
        let offset = max(0, page - 1) * 100
        do {
            let object = try await request("manga/\(comic.id)/feed", items: [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "offset", value: "\(offset)"),
                URLQueryItem(name: "includeExternalUrl", value: "0"),
                URLQueryItem(name: "order[chapter]", value: "asc"),
                URLQueryItem(name: "includes[]", value: "scanlation_group")
            ])
            let entries = object["data"] as? [[String: Any]] ?? []
            result += entries.compactMap { entry in
                guard let id = entry["id"] as? String,
                      let attributes = entry["attributes"] as? [String: Any] else { return nil }
                let chapter = attributes["chapter"] as? String ?? "?"
                let name = attributes["title"] as? String ?? ""
                let language = attributes["translatedLanguage"] as? String ?? ""
                let relationships = entry["relationships"] as? [[String: Any]] ?? []
                let group = relationships.first { $0["type"] as? String == "scanlation_group" }
                    .flatMap { ($0["attributes"] as? [String: Any])?["name"] as? String } ?? ""
                return MangaOnlineChapter(id: id, title: name.isEmpty ? "第 \(chapter) 话" : "第 \(chapter) 话 · \(name)",
                                          language: language, group: group,
                                          pageCount: attributes["pages"] as? Int ?? 0,
                                          externalURL: (attributes["externalUrl"] as? String).flatMap(URL.init(string:)))
            }
        }
        return result
    }

    func pages(for chapter: MangaOnlineChapter) async throws -> [MangaImageRequest] {
        let object = try await request("at-home/server/\(chapter.id)")
        guard let server = object["baseUrl"] as? String,
              let data = object["chapter"] as? [String: Any],
              let hash = data["hash"] as? String,
              let names = data["data"] as? [String] else { return [] }
        return names.compactMap { name in URL(string: "\(server)/data/\(hash)/\(name)").map { MangaImageRequest(url: $0) } }
    }

    private func mangaList(query: String?, page: Int, tagID: String? = nil) async throws -> [MangaOnlineComic] {
        var items = [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "offset", value: "\(max(0, page - 1) * 20)"),
            URLQueryItem(name: "includes[]", value: "cover_art")
        ]
        if let tagID { items.append(URLQueryItem(name: "includedTags[]", value: tagID)) }
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "title", value: query))
        } else {
            items.append(URLQueryItem(name: "order[followedCount]", value: "desc"))
        }
        let object = try await request("manga", items: items)
        return (object["data"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["id"] as? String,
                  let attributes = entry["attributes"] as? [String: Any] else { return nil }
            let titles = attributes["title"] as? [String: String] ?? [:]
            let title = titles["zh"] ?? titles["zh-hk"] ?? titles["zh-tw"] ?? titles["en"] ?? titles["ja"] ?? titles.values.first ?? "未命名漫画"
            let summaries = attributes["description"] as? [String: String] ?? [:]
            let summary = summaries["zh"] ?? summaries["en"] ?? summaries.values.first ?? ""
            let relationships = entry["relationships"] as? [[String: Any]] ?? []
            let coverName = relationships.first { $0["type"] as? String == "cover_art" }
                .flatMap { ($0["attributes"] as? [String: Any])?["fileName"] as? String }
            let cover = coverName.flatMap { URL(string: "https://uploads.mangadex.org/covers/\(id)/\($0).256.jpg") }
            return MangaOnlineComic(id: id, title: title, summary: summary, coverURL: cover, source: self.id)
        }
    }

    private func request(_ path: String, items: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: components.url!)
        request.setValue("Luoye-Manga/0.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
