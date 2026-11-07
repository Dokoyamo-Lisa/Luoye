import Foundation
import Observation

/// Chapter pagination keeps every language, so a filtered reader can still detect repeated source pages.
@MainActor @Observable
final class MangaChapterCatalog {
    private(set) var chapters: [MangaOnlineChapter]
    private(set) var nextPage: Int
    private(set) var ended: Bool
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored private var context: MangaOnlineComic.Identity?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var failedPage: Int?

    init(comic: MangaOnlineComic? = nil, chapters: [MangaOnlineChapter] = [], nextPage: Int = 1, ended: Bool = false) {
        self.context = comic?.identity
        var ids = Set<String>()
        self.chapters = chapters.filter { ids.insert($0.id).inserted }
        self.nextPage = nextPage
        self.ended = ended
    }

    func shown(language: String) -> [MangaOnlineChapter] {
        language == "all" ? chapters : chapters.filter { $0.language == language }
    }

    func cancel() { generation = UUID(); loading = false }

    @discardableResult
    func load(for comic: MangaOnlineComic, from source: any MangaCatalogSource, reset: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        if context != comic.identity {
            generation = UUID(); context = comic.identity
            chapters = []; nextPage = 1; failedPage = nil; ended = false; loading = false; error = nil
        }
        guard reset || (!loading && (!ended || failedPage != nil)) else { return false }
        let token = UUID(), requested = reset ? 1 : (failedPage ?? nextPage)
        generation = token
        loading = true; error = nil
        defer { if generation == token { loading = false } }
        do {
            let values = try await (reset ? source.refreshChapters(for: comic) : source.chapters(for: comic, page: requested))
            guard !Task.isCancelled, generation == token else { return false }
            var ids = Set(requested == 1 ? [] : chapters.map(\.id))
            let unique = values.filter { ids.insert($0.id).inserted }
            if requested == 1 { chapters = unique }
            else { chapters += unique }
            nextPage = requested + 1; failedPage = nil
            ended = source.chapterPageSize.map { values.count < $0 } ?? true
            if unique.isEmpty { ended = true }
            return true
        } catch {
            guard !Task.isCancelled, generation == token else { return false }
            // A failed refresh must retry page1, even when the retained list had reached its end.
            failedPage = requested
            self.error = "章节目录暂时无法加载：\(error.localizedDescription)"
            return false
        }
    }
}
