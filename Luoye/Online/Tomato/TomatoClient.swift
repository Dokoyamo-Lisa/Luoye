import Foundation

/// Native client for the upstream WebUI's documented HTTP surface; cookies stay in this session.
actor TomatoClient {
    private let session: URLSession
    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral)
    }
    static func serverURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw TomatoError.message("请输入完整的下载器服务地址，例如 https://example.com。")
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = url.scheme?.lowercased(); components.host = host.lowercased()
        if (components.scheme == "http" && components.port == 80) || (components.scheme == "https" && components.port == 443) { components.port = nil }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        guard let normalized = components.url else { throw TomatoError.message("下载器服务地址无效。") }
        return normalized
    }
    private func endpoint(_ base: URL, _ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains(".."), !path.contains("://") else {
            throw TomatoError.message("服务返回了无效路径。")
        }
        let url = base.appending(path: path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }
    private func request(_ base: URL, _ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: try endpoint(base, path, query: query)); request.httpMethod = method; request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard data.count < 16_000_000 else { throw TomatoError.message("服务返回的数据过大。") }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? String, !error.isEmpty {
            throw TomatoError.message(error == "search requires `official-api` feature" ? "这个服务未启用搜索功能，仍可用书号或书籍链接查看。" : error)
        }
        return data
    }
    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw TomatoError.message("服务需要登录，请在番茄设置中连接并登录。")
        case 429: throw TomatoError.message("服务正在处理其他任务，请稍后再试。")
        default: throw TomatoError.message("下载器服务返回错误（\(http.statusCode)）。")
        }
    }
    func connect(_ base: URL, password: String) async throws -> String {
        if !password.isEmpty { _ = try await request(base, "api/login", method: "POST", body: ["password": password]) }
        let data = try await request(base, "api/status")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let version = object["version"] as? String else { throw TomatoError.message("此地址不是兼容的 Tomato-Novel-Downloader 服务。") }
        return version
    }
    func search(_ query: String, base: URL) async throws -> [TomatoBook] {
        let data = try await request(base, "api/search", query: [.init(name: "q", value: query)])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var ids = Set<String>()
        return (object["items"] as? [[String: Any]] ?? []).compactMap { item in
            let id = item["book_id"] as? String ?? (item["book_id"] as? NSNumber)?.stringValue ?? ""
            guard TomatoBookID.valid(id), ids.insert(id).inserted else { return nil }
            return TomatoBook(id: id, title: item["title"] as? String ?? "未命名小说", author: item["author"] as? String ?? "")
        }
    }
    func preview(_ id: String, base: URL) async throws -> TomatoBook {
        guard TomatoBookID.valid(id) else { throw TomatoError.message("书号无效。") }
        let data = try await request(base, "api/preview/" + id)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let title = object["book_name"] as? String, !title.isEmpty else { throw TomatoError.message("服务未返回书目信息。") }
        let cover = (object["cover_url"] as? String).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL.absoluteString }
        return TomatoBook(id: id, title: title, author: object["author"] as? String ?? "", summary: object["description"] as? String ?? "", cover: cover, chapterCount: object["chapter_count"] as? Int ?? 0)
    }
    func createJob(bookID: String, base: URL, range: ClosedRange<Int>? = nil) async throws {
        guard TomatoBookID.valid(bookID) else { throw TomatoError.message("书号无效。") }
        var body: [String: Any] = ["book_id": bookID]
        if let range { body["range_start"] = range.lowerBound; body["range_end"] = range.upperBound }
        _ = try await request(base, "api/jobs", method: "POST", body: body)
    }
    func jobs(base: URL) async throws -> [TomatoJob] {
        struct Response: Decodable { let items: [TomatoJob] }
        return try JSONDecoder().decode(Response.self, from: await request(base, "api/jobs")).items
    }
    func cancel(_ id: UInt64, base: URL) async throws { _ = try await request(base, "api/jobs/\(id)/cancel", method: "POST") }
    func choose(_ value: String, for job: UInt64, kind: String, base: URL) async throws {
        guard ["format", "book_name"].contains(kind) else { return }
        _ = try await request(base, "api/jobs/\(job)/\(kind)", method: "POST", body: ["value": value])
    }
    func library(base: URL, path: String, start: Bool) async throws -> TomatoRemoteLibrary {
        try JSONDecoder().decode(TomatoRemoteLibrary.self, from: await request(base, "api/library", query: [.init(name: "path", value: path), .init(name: "start", value: start ? "true" : "false")]))
    }
    func download(_ file: TomatoRemoteFile, base: URL) async throws -> URL {
        guard file.readable, !file.isDirectory, file.size <= 200_000_000 else { throw TomatoError.message("请选择 200 MB 以内的 TXT 或 EPUB 文件。") }
        var request = URLRequest(url: try endpoint(base, "download/" + file.rel_path)); request.timeoutInterval = 120
        let (temp, response) = try await session.download(for: request)
        try Self.validate(response)
        try TomatoDownloadedFile.validate(temp, extensionName: file.ext, mimeType: response.mimeType)
        try Task.checkCancellation()
        let saved = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + file.ext.lowercased())
        try FileManager.default.moveItem(at: temp, to: saved)
        return saved
    }
}
