import Foundation
import Observation
import CryptoKit

struct BrowsingEntry: Codable, Identifiable, Hashable {
    var id: String {
        if let tomatoBook { return "tomato:\(tomatoBook.id)" }
        if let zlibBook { return "zlib:\(zlibBook.id)" }
        if let wenkuBook { return "wenku8:\(wenkuBook.id)" }
        return legacyId
    }

    var source: BookSource {
        tomatoBook != nil ? .tomato : (zlibBook != nil ? .zlib : .wenku8)
    }

    var title: String {
        tomatoBook?.title ?? zlibBook?.title ?? wenkuBook?.title ?? ""
    }

    var author: String {
        if let tomatoBook { return tomatoBook.author.isEmpty ? "番茄小说" : tomatoBook.author }
        if let zlibBook {
            return zlibBook.author.isEmpty ? "Z-Library" : zlibBook.author
        }
        if let wenkuBook {
            return wenkuBook.author.isEmpty ? "轻小说文库" : wenkuBook.author
        }
        return ""
    }

    var cover: String? {
        tomatoBook?.cover ?? zlibBook?.cover ?? wenkuBook?.cover
    }

    var tomatoBook: TomatoBook?
    var wenkuBook: WenkuBook?
    var zlibBook: ZLibBook?
    var viewedAt: Date
    private var legacyId: String = UUID().uuidString

    init(wenkuBook: WenkuBook, viewedAt: Date = .now) {
        self.wenkuBook = wenkuBook
        self.zlibBook = nil
        self.viewedAt = viewedAt
    }

    init(zlibBook: ZLibBook, viewedAt: Date = .now) {
        self.wenkuBook = nil
        self.zlibBook = zlibBook
        self.viewedAt = viewedAt
    }

    init(tomatoBook: TomatoBook, viewedAt: Date = .now) { self.tomatoBook = tomatoBook; self.viewedAt = viewedAt }

    private enum CodingKeys: String, CodingKey {
        case book
        case tomatoBook
        case wenkuBook
        case zlibBook
        case viewedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.viewedAt = (try? container.decode(Date.self, forKey: .viewedAt)) ?? .now
        if let tomato = try? container.decodeIfPresent(TomatoBook.self, forKey: .tomatoBook) {
            self.tomatoBook = tomato
        } else if let zlib = try? container.decodeIfPresent(ZLibBook.self, forKey: .zlibBook) {
            self.zlibBook = zlib
            self.wenkuBook = nil
        } else if let wenku = try? container.decodeIfPresent(WenkuBook.self, forKey: .wenkuBook) {
            self.wenkuBook = wenku
            self.zlibBook = nil
        } else if let legacyWenku = try? container.decode(WenkuBook.self, forKey: .book) {
            self.wenkuBook = legacyWenku
            self.zlibBook = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tomatoBook, forKey: .tomatoBook)
        try container.encodeIfPresent(wenkuBook, forKey: .wenkuBook)
        try container.encodeIfPresent(zlibBook, forKey: .zlibBook)
        try container.encode(viewedAt, forKey: .viewedAt)
    }
}

@MainActor @Observable
final class BrowsingHistoryStore {
    private(set) var entries: [BrowsingEntry] = []
    private let file: URL

    init(file: URL = URL.applicationSupportDirectory.appending(path: "BrowsingHistory.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([BrowsingEntry].self, from: data) {
            // 按最近浏览时间排序并按复合 ID 去重
            var seen = Set<String>()
            var unique: [BrowsingEntry] = []
            for item in saved.sorted(by: { $0.viewedAt > $1.viewedAt }) {
                if seen.insert(item.id).inserted {
                    unique.append(item)
                }
            }
            entries = unique
        }
    }

    func record(_ book: WenkuBook) {
        let entry = BrowsingEntry(wenkuBook: book, viewedAt: .now)
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(200))
        save()
    }

    func record(_ book: ZLibBook) {
        let entry = BrowsingEntry(zlibBook: book, viewedAt: .now)
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(200))
        save()
    }

    func record(_ book: TomatoBook) {
        let entry = BrowsingEntry(tomatoBook: book)
        entries.removeAll { $0.id == entry.id }; entries.insert(entry, at: 0)
        entries = Array(entries.prefix(200)); save()
    }

    func updateMetadata(_ book: WenkuBook) {
        let targetId = "wenku8:\(book.id)"
        guard let index = entries.firstIndex(where: { $0.id == targetId }) else { return }
        entries[index].wenkuBook = book
        save()
    }

    func updateMetadata(_ book: ZLibBook) {
        let targetId = "zlib:\(book.id)"
        guard let index = entries.firstIndex(where: { $0.id == targetId }) else { return }
        entries[index].zlibBook = book
        save()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func remove(_ wenkuId: Int) {
        remove("wenku8:\(wenkuId)")
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

@MainActor @Observable
final class WebsiteShelfStore {
    private(set) var books: [WenkuBook] = []
    private(set) var syncedAt: Date?
    private(set) var syncing = false
    var error: String?
    private var account: String?
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "WebsiteShelves", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private struct Snapshot: Codable {
        let books: [WenkuBook]
        let syncedAt: Date
    }

    private func file(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".json")
    }

    func activate(_ key: String?) {
        guard account != key else { return }
        account = key; books = []; syncedAt = nil; error = nil
        if let key,
           let data = try? Data(contentsOf: file(key)),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            books = saved.books
            syncedAt = saved.syncedAt
        }
    }

    func sync(using service: WenkuService) async {
        guard !syncing else { return }
        guard let key = service.accountKey, service.authenticated else {
            error = WenkuFailure.login.localizedDescription
            return
        }
        activate(key)
        syncing = true; error = nil
        defer { syncing = false }
        do {
            var result: [WenkuBook] = [], ids = Set<Int>(), visited = Set<String>()
            // 官网默认组及五个分组；合并书籍 ID，分页沿用页面提供的链接。
            var pending = (0...5).map { "/modules/article/bookcase.php?classid=\($0)" }
            while !pending.isEmpty {
                try Task.checkCancellation()
                let path = pending.removeFirst()
                guard visited.insert(path).inserted else { continue }
                guard visited.count <= 100 else { throw WenkuFailure.message("书架分页数量异常，请稍后重试。") }
                let page = try await service.page(path, refresh: true, background: true)
                for var book in page.books where ids.insert(book.id).inserted {
                    if let known = books.first(where: { $0.id == book.id }) {
                        book.cover = known.cover
                        book.summary = known.summary
                        book.tags = known.tags
                    }
                    if book.cover == nil { book.cover = "https://img.wenku8.com/image/\(book.id / 1000)/\(book.id)/\(book.id)s.jpg" }
                    result.append(book)
                }
                pending += (page.shelfPages ?? []).filter { !visited.contains($0) && !pending.contains($0) }
            }
            guard service.accountKey == key, account == key else { return }
            books = result; syncedAt = .now
            save(key)
        } catch is CancellationError {} catch { if account == key { self.error = error.localizedDescription } }
    }

    func update(_ book: WenkuBook) {
        guard let key = account, let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book; save(key)
    }

    private func save(_ key: String) {
        guard let syncedAt else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Snapshot(books: books, syncedAt: syncedAt)) {
            try? data.write(to: file(key), options: .atomic)
        }
    }
}

/// Z-Library 账号级书库、个人书单、下载记录与额度隔离存储，切换账号自动隔离数据。
@MainActor @Observable
final class ZLibAccountStore {
    private(set) var favorites: [ZLibBook] = []
    private(set) var downloads: [ZLibBook] = []
    private(set) var booklists: [ZLibBooklist] = []
    private(set) var quota: ZLibQuota?
    private(set) var syncedAt: Date?
    private(set) var syncing = false
    var error: String?

    private(set) var account: String?
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "ZLibAccounts", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private struct Snapshot: Codable {
        let favorites: [ZLibBook]
        let downloads: [ZLibBook]
        let booklists: [ZLibBooklist]
        let quota: ZLibQuota?
        let syncedAt: Date
    }

    private func file(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".json")
    }

    func activate(_ key: String?) {
        guard account != key else { return }
        account = key
        favorites = []
        downloads = []
        booklists = []
        quota = nil
        syncedAt = nil
        error = nil
        if let key,
           let data = try? Data(contentsOf: file(key)),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            favorites = saved.favorites
            downloads = saved.downloads
            booklists = saved.booklists
            quota = saved.quota
            syncedAt = saved.syncedAt
        }
    }

    func sync(using service: ZLibService) async {
        guard !syncing else { return }
        guard let key = service.accountKey, service.authenticated else {
            error = ZLibFailure.login.localizedDescription
            return
        }
        activate(key)
        syncing = true
        error = nil
        defer { syncing = false }
        do {
            // 1. 同步账号收藏书库（先同步书目，正文按需下载）
            var favBooks: [ZLibBook] = []
            var favIds = Set<String>()
            for pageIndex in 1...5 {
                try Task.checkCancellation()
                let page = try await service.page("/users/favorites?page=\(pageIndex)", refresh: true, background: true)
                if let q = page.quota { quota = q; service.quota = q }
                for book in page.books where favIds.insert(book.id).inserted {
                    favBooks.append(book)
                }
                if !page.hasNextPage || page.books.isEmpty { break }
            }

            // 2. 同步下载历史与今日下载额度
            try Task.checkCancellation()
            let dlPage = try await service.page("/users/downloads", refresh: true, background: true)
            if let q = dlPage.quota {
                quota = q
                service.quota = q
            }
            var dlBooks: [ZLibBook] = []
            var dlIds = Set<String>()
            for book in dlPage.books where dlIds.insert(book.id).inserted {
                dlBooks.append(book)
            }

            // 3. 同步个人书单
            try Task.checkCancellation()
            var myLists: [ZLibBooklist] = []
            if let listPage = try? await service.page("/booklists/my", refresh: true, background: true) {
                myLists = listPage.booklists
            }

            guard service.accountKey == key, account == key else { return }
            favorites = favBooks
            downloads = dlBooks
            booklists = myLists
            syncedAt = .now
            save(key)
        } catch is CancellationError {
        } catch {
            if account == key {
                self.error = error.localizedDescription
            }
        }
    }

    func update(_ book: ZLibBook) {
        guard let key = account else { return }
        var changed = false
        if let idx = favorites.firstIndex(where: { $0.id == book.id }) {
            favorites[idx] = book
            changed = true
        }
        if let idx = downloads.firstIndex(where: { $0.id == book.id }) {
            downloads[idx] = book
            changed = true
        }
        if changed { save(key) }
    }

    func recordLocalDownload(_ book: ZLibBook) {
        guard let key = account else { return }
        downloads.removeAll { $0.id == book.id }
        var item = book
        if item.downloadedAt == nil {
            item.downloadedAt = Date.now.formatted(date: .abbreviated, time: .shortened)
        }
        downloads.insert(item, at: 0)
        if syncedAt == nil { syncedAt = .now }
        save(key)
    }

    func recordFavorite(_ book: ZLibBook, favored: Bool) {
        guard let key = account else { return }
        favorites.removeAll { $0.id == book.id }
        if favored {
            favorites.insert(book, at: 0)
        }
        if syncedAt == nil { syncedAt = .now }
        save(key)
    }

    func clearCurrentAccountData() {
        guard let key = account else { return }
        favorites = []
        downloads = []
        booklists = []
        quota = nil
        syncedAt = nil
        error = nil
        try? FileManager.default.removeItem(at: file(key))
    }

    private func save(_ key: String) {
        guard let syncedAt else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = Snapshot(
            favorites: favorites,
            downloads: downloads,
            booklists: booklists,
            quota: quota,
            syncedAt: syncedAt
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: file(key), options: .atomic)
        }
    }
}
