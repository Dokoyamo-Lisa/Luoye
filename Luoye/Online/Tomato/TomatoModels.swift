import Foundation

struct TomatoBook: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var title: String
    var author = ""
    var summary = ""
    var cover: String?
    var chapterCount = 0
}
struct TomatoChapter: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
}
struct TomatoDetail: Codable, Sendable {
    var book: TomatoBook
    var chapters: [TomatoChapter]
}
enum TomatoError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum TomatoBookID {
    static func parse(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if valid(value) { return value }
        guard let url = URL(string: value), let host = url.host?.lowercased(),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["fanqienovel.com", "changdunovel.com", "fqnovel.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if ["book_id", "bookId"].contains(item.name), let id = item.value, valid(id) { return id }
        }
        let components = url.pathComponents
        if let page = components.firstIndex(of: "page"), components.indices.contains(page + 1), valid(components[page+1]) { return components[page+1] }
        return nil
    }
    static func valid(_ value: String) -> Bool {
        (10...25).contains(value.count) && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

struct TomatoChoice: Codable, Identifiable, Sendable {
    let label: String
    let value: String
    var id: String { value }
}
struct TomatoJob: Codable, Identifiable, Sendable {
    let id: UInt64
    let book_id: String
    var title: String?
    var author: String?
    var state: String
    var message: String?
    var book_name_options: [TomatoChoice]?
    var format_options: [TomatoChoice]?
    var progress: Progress?
    struct Progress: Codable, Sendable { let saved_chapters: Int; let chapter_total: Int }
    var active: Bool { state == "queued" || state == "running" }
    var stateTitle: String {
        switch state {
        case "queued": "等待下载"
        case "running": "正在下载"
        case "done": "下载完成"
        case "failed": "下载失败"
        case "canceled": "已取消"
        default: state
        }
    }
}
struct TomatoRemoteFile: Codable, Identifiable, Sendable {
    let kind: String
    let name: String
    let rel_path: String
    let ext: String
    let size: UInt64
    var id: String { rel_path }
    var isDirectory: Bool { kind == "dir" }
    var readable: Bool { ["txt", "epub"].contains(ext.lowercased()) }
}
struct TomatoRemoteLibrary: Decodable, Sendable {
    var items: [TomatoRemoteFile]
    var running: Bool
    var error: String?
}

enum TomatoHomeSection: String, CaseIterable, Identifiable {
    case home, popular, fresh
    var id: String { rawValue }
    var title: String { switch self { case .home: "首页推荐"; case .popular: "阅读榜"; case .fresh: "新书榜" } }
    var path: String { switch self { case .home: ""; case .popular: "rank/0"; case .fresh: "rank/0_2" } }
}
struct TomatoReadingPage: Codable, Sendable {
    let title: String
    let paragraphs: [String]
    let fontName: String?
    let fontFile: String?
}
