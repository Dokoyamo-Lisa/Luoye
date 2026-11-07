import Foundation

struct MangaSyncStamps: Codable, Sendable {
    var favorites: [String: Date] = [:]
    var removedFavorites: [String: Date] = [:]
    var recent: [String: Date] = [:]
    var removedRecent: [String: Date] = [:]
    var readLater: [String: Date] = [:]
    var removedReadLater: [String: Date] = [:]
    var pages: [String: Date] = [:]
    static func key(_ comic: MangaOnlineComic) -> String { comic.source + "|" + comic.id }
    static func merged(_ lhs: [String: Date], _ rhs: [String: Date]) -> [String: Date] {
        lhs.merging(rhs) { max($0,$1) }
    }
}

struct MangaReadingSnapshot: Codable, Sendable {
    var version = 1
    var createdAt = Date()
    var favorites: [MangaOnlineComic]
    var recent: [MangaOnlineComic]
    var readLater: [MangaOnlineComic]
    var pages: [String: Int]
    var stamps: MangaSyncStamps

    func validated() throws -> Self {
        guard version == 1, favorites.count <= 20000, recent.count <= 20000, readLater.count <= 20000,
              pages.count <= 100000, [stamps.favorites,stamps.removedFavorites,stamps.recent,stamps.removedRecent,stamps.readLater,stamps.removedReadLater,stamps.pages].allSatisfy({ $0.count <= 100000 }) else {
            throw MangaScriptRuntime.RuntimeError.message("阅读备份版本或数据规模无效")
        }
        let future = Date().addingTimeInterval(24 * 3600)
        for book in favorites + recent + readLater {
            guard !book.id.isEmpty, book.id.count <= 1000, book.title.count <= 5000, book.summary.count <= 200000,
                  book.source.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil,
                  book.coverURL == nil || ["https","http"].contains(book.coverURL!.scheme?.lowercased() ?? "") else {
                throw MangaScriptRuntime.RuntimeError.message("阅读备份包含无效书目信息")
            }
        }
        guard pages.allSatisfy({ $0.key.count <= 3000 && $0.value >= 0 && $0.value <= 1000000 }),
              [stamps.favorites,stamps.removedFavorites,stamps.recent,stamps.removedRecent,stamps.readLater,stamps.removedReadLater,stamps.pages].allSatisfy({ values in values.allSatisfy { $0.key.count <= 3000 && $0.value <= future } }) else {
            throw MangaScriptRuntime.RuntimeError.message("阅读备份包含无效进度或时间")
        }
        return self
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 20 * 1024 * 1024 else { throw MangaScriptRuntime.RuntimeError.message("阅读备份文件过大") }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
    func merging(_ remote: Self) throws -> Self {
        _ = try remote.validated()
        let local = stamps
        var mergedStamps = MangaSyncStamps()
        mergedStamps.favorites = MangaSyncStamps.merged(local.favorites, remote.stamps.favorites)
        mergedStamps.recent = MangaSyncStamps.merged(local.recent, remote.stamps.recent)
        mergedStamps.readLater = MangaSyncStamps.merged(local.readLater, remote.stamps.readLater)
        mergedStamps.pages = local.pages.filter { pages[$0.key] != nil }
        mergedStamps.removedFavorites = MangaSyncStamps.merged(local.removedFavorites, remote.stamps.removedFavorites)
        mergedStamps.removedRecent = MangaSyncStamps.merged(local.removedRecent, remote.stamps.removedRecent)
        mergedStamps.removedReadLater = MangaSyncStamps.merged(local.removedReadLater, remote.stamps.removedReadLater)
        var mergedPages = pages
        for (key,page) in remote.pages {
            if mergedPages[key] == nil || (remote.stamps.pages[key] ?? .distantPast) > (local.pages[key] ?? .distantPast) {
                mergedPages[key] = page
                mergedStamps.pages[key] = remote.stamps.pages[key]
            }
        }
        return Self(favorites: Self.mergeCollection(local: favorites, remote: remote.favorites, localDates: local.favorites, remoteDates: remote.stamps.favorites, removed: mergedStamps.removedFavorites),
                    recent: Self.mergeCollection(local: recent, remote: remote.recent, localDates: local.recent, remoteDates: remote.stamps.recent, removed: mergedStamps.removedRecent, limit:100),
                    readLater: Self.mergeCollection(local: readLater, remote: remote.readLater, localDates: local.readLater, remoteDates: remote.stamps.readLater, removed: mergedStamps.removedReadLater),
                    pages: mergedPages, stamps: mergedStamps)
    }

    static func mergeCollection(local: [MangaOnlineComic], remote: [MangaOnlineComic], localDates: [String:Date], remoteDates: [String:Date], removed: [String:Date], limit: Int = 20000) -> [MangaOnlineComic] {
        var books = Dictionary(local.map { (MangaSyncStamps.key($0),$0) }, uniquingKeysWith: { first,_ in first })
        for book in remote {
            let key = MangaSyncStamps.key(book)
            if books[key] == nil || (remoteDates[key] ?? .distantPast) > (localDates[key] ?? .distantPast) { books[key] = book }
        }
        let dates = MangaSyncStamps.merged(localDates,remoteDates)
        return Array(books.filter { key,_ in
            guard let deletion = removed[key] else { return true }
            return (dates[key] ?? .distantPast) > deletion
        }.values).sorted {
            let lhs = dates[MangaSyncStamps.key($0)] ?? .distantPast, rhs = dates[MangaSyncStamps.key($1)] ?? .distantPast
            return lhs == rhs ? $0.title < $1.title : lhs > rhs
        }.prefix(limit).map { $0 }
    }
}
