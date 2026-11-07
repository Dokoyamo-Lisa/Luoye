import Foundation
import Observation

/// Owns one source/query/options list and the exact page to retry.
@MainActor @Observable
final class MangaBrowseModel {
    struct Context: Hashable, Sendable {
        let sourceID: String
        var listingID = ""
        var keyword = ""
        var exploreIndex = 0
        var searchOptions: [String] = []
    }
    private(set) var comics: [MangaOnlineComic] = []
    private(set) var loading = false
    private(set) var ended = false
    private(set) var error: String?
    private(set) var context: Context?
    private var nextPage = 1
    private var failedPage: Int?
    @ObservationIgnored private var generation = UUID()

    func prepare(_ context: Context) {
        guard self.context != context else { return }
        generation = UUID()
        self.context = context
        comics = []; nextPage = 1; failedPage = nil
        loading = false; ended = false; error = nil
    }

    func cancel() {
        generation = UUID()
        loading = false
    }

    func load(context: Context, source: any MangaCatalogSource, reset: Bool = false, singlePage: Bool = false) async {
        await load(context: context, reset: reset) { requestedPage in
            let values = try await (context.keyword.isEmpty ? source.discover(page: requestedPage) : source.search(context.keyword, page: requestedPage))
            return Page(comics: values, isLast: singlePage || (source is MangaDexSource && values.count < 20))
        }
    }

    struct Page: Sendable {
        let comics: [MangaOnlineComic]
        var isLast = false
    }

    func load(context: Context, reset: Bool = false, operation: (Int) async throws -> Page) async {
        prepare(context)
        guard reset || !loading else { return }
        let requestedPage = reset ? 1 : (failedPage ?? nextPage)
        guard reset || failedPage != nil || !ended else { return }
        let token = UUID()
        generation = token
        loading = true; error = nil
        defer { if generation == token { loading = false } }
        do {
            let result = try await operation(requestedPage)
            guard generation == token, !Task.isCancelled else { return }
            let values = result.comics
            var seen = Set(requestedPage == 1 ? [] : comics.map(\.identity))
            let unique = values.filter { seen.insert($0.identity).inserted }
            if requestedPage == 1 { comics = unique }
            else { comics += unique }
            nextPage = requestedPage + 1
            failedPage = nil
            // A source repeating the same page must not leave an endless Load More button.
            ended = result.isLast || unique.isEmpty
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            failedPage = requestedPage
            self.error = "漫画源暂时无法加载：\(error.localizedDescription)"
        }
    }
}
