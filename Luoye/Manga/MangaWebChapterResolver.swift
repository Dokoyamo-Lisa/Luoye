import Foundation
import SwiftSoup

/// Public chapter pages are converted into image requests for the native reader.
/// Publisher links never launch another application, and never share Haiku cookies.
enum MangaWebChapterResolver {
    static func pages(from url: URL) async throws -> [MangaImageRequest] {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            throw MangaScriptRuntime.RuntimeError.message("这个章节地址无法在阅读器中加载。")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 8 * 1024 * 1024,
              let html = String(data: data, encoding: .utf8) else {
            throw MangaScriptRuntime.RuntimeError.message("章节网页暂时无法加载，请重试或选择同书的其他漫画源。")
        }
        let base = response.url ?? url
        return try await Task.detached(priority: .userInitiated) { try extract(html: html, baseURL: base) }.value
    }

    static func extract(html: String, baseURL: URL) throws -> [MangaImageRequest] {
        let document = try SwiftSoup.parse(html, baseURL.absoluteString)
        let readerSelector = "#reader img, #chapter-reader img, .reading-content img, .chapter-content img, .chapter-images img, .page-break img, .comic-page img, .reader-page img, img.comic-image"
        let candidates = try document.select(readerSelector).array()
        let images = candidates.isEmpty ? try document.select("img").array() : candidates
        var seen = Set<URL>()
        let result = try images.prefix(2000).compactMap { element -> MangaImageRequest? in
            let label = try (element.attr("class") + " " + element.attr("id")).lowercased()
            guard !["avatar", "logo", "banner", "icon", "advert", "thumbnail"].contains(where: { label.contains($0) }) else { return nil }
            if candidates.isEmpty {
                let width = Int(try element.attr("width")) ?? 0, height = Int(try element.attr("height")) ?? 0
                guard width >= 300 && height >= 300 else { return nil }
            }
            var address = ""
            for attribute in ["data-src", "data-original", "data-lazy-src", "src"] {
                let value = try element.attr(attribute).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !value.hasPrefix("data:") { address = value; break }
            }
            guard let url = URL(string: address, relativeTo: baseURL)?.absoluteURL, !address.isEmpty,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url).inserted else { return nil }
            return MangaImageRequest(url: url, headers: ["Referer": baseURL.absoluteString])
        }
        guard !result.isEmpty else {
            throw MangaScriptRuntime.RuntimeError.message("这个漫画源只返回了官网网页，公开页面中没有可读取的章节图片。请在落叶内切换其他漫画源搜索同书。")
        }
        return result
    }
}
