import Foundation
import Observation

@MainActor @Observable
final class MangaSearchModel {
    struct Section: Identifiable, Sendable {
        let id: String
        let name: String
        var comics: [MangaOnlineComic] = []
        var page = 1
        var loading = true
        var ended = false
        var error: String?
    }
    private(set) var sections: [Section] = []
    private(set) var searching = false
    private(set) var keyword = ""
    private(set) var history = UserDefaults.standard.stringArray(forKey: "manga.search.history") ?? []
    @ObservationIgnored private var generation = UUID()

    func remember(_ value: String) {
        let clean = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !clean.isEmpty else { return }
        history.removeAll { $0 == clean }; history.insert(clean, at: 0)
        history = Array(history.prefix(30))
        UserDefaults.standard.set(history, forKey: "manga.search.history")
    }
    func clearHistory() {
        history = []; UserDefaults.standard.removeObject(forKey: "manga.search.history")
    }
    func cancel() {
        generation = UUID(); searching = false
        for index in sections.indices { sections[index].loading = false }
    }
    func search(_ query: String, sources: [any MangaCatalogSource]) async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        remember(clean); keyword = clean
        let token = UUID(); generation = token; searching = true
        sections = sources.map { Section(id: $0.id, name: $0.displayName) }
        defer { if generation == token { searching = false } }
        await withTaskGroup(of: Section.self) { group in
            var next = 0
            func enqueue(_ source: any MangaCatalogSource) {
                group.addTask {
                    var section = Section(id: source.id, name: source.displayName)
                    do {
                        let values = try await source.search(clean, page: 1)
                        var ids = Set<String>()
                        section.comics = values.filter { ids.insert($0.id).inserted }
                        section.page = 2; section.ended = section.comics.isEmpty
                    } catch { section.error = error.localizedDescription }
                    section.loading = false
                    return section
                }
            }
            while next < min(4, sources.count) { enqueue(sources[next]); next += 1 }
            for await section in group {
                guard generation == token, !Task.isCancelled else { group.cancelAll(); break }
                if let index = sections.firstIndex(where: { $0.id == section.id }) { sections[index] = section }
                if next < sources.count { enqueue(sources[next]); next += 1 }
            }
        }
    }
    func loadMore(from source: any MangaCatalogSource) async {
        guard let index = sections.firstIndex(where: { $0.id == source.id }), !sections[index].loading else { return }
        let token = generation, page = sections[index].page, query = keyword
        sections[index].loading = true; sections[index].error = nil
        do {
            let values = try await source.search(query, page: page)
            guard generation == token, let index = sections.firstIndex(where: { $0.id == source.id }) else { return }
            var ids = Set(sections[index].comics.map(\.id))
            let unique = values.filter { ids.insert($0.id).inserted }
            sections[index].comics += unique
            sections[index].page = page + 1
            sections[index].ended = unique.isEmpty
        } catch {
            if generation == token, let index = sections.firstIndex(where: { $0.id == source.id }) { sections[index].error = error.localizedDescription }
        }
        if generation == token, let index = sections.firstIndex(where: { $0.id == source.id }) { sections[index].loading = false }
    }
}
