import SwiftUI

struct MangaCategoriesPage: View {
    @Environment(MangaSourceStore.self) private var sources
    let sourceID: String
    var body: some View {
        Group {
            if let script = sources.source(for: sourceID) as? MangaScriptSource {
                MangaSourceCategoriesView(source: script)
            } else { MangaDexCategoriesView() }
        }
    }
}

private struct MangaDexCategoriesView: View {
    @State private var categories: [MangaDexSource.Category] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    private let groups = [("genre", "题材"), ("theme", "主题"), ("format", "形式"), ("content", "内容标签")]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "漫画分类", caption: "MangaDex")
                LuoyeSearchBar(placeholder: "查找分类或标签", text: $query)
                if loading { ProgressView().frame(maxWidth: .infinity).padding(30) }
                if let error {
                    LuoyeNotice(message: error, icon: "wifi.exclamationmark")
                    Button("重试") { Task { await load() } }.font(.serif(13))
                }
                ForEach(groups, id: \.0) { key, title in
                    let values = categories.filter { $0.group == key && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
                    if !values.isEmpty {
                        SectionTitle(title: title, trailing: "\(values.count)")
                        FlowLayout(spacing: 8) {
                            ForEach(values) { category in
                                NavigationLink { MangaDexCategoryListing(category: category) } label: { TagLabel(text: category.name) }
                                    .buttonStyle(PressStyle())
                            }
                        }
                    }
                }
                if !loading && error == nil && !categories.isEmpty && !query.isEmpty && !categories.contains(where: { $0.name.localizedCaseInsensitiveContains(query) }) {
                    LuoyeEmptyState(icon: "magnifyingglass", title: "没有找到分类", message: "试试其他关键词。")
                }
            }.luoyeContentMargins(top: 16, maximumWidth: 900)
        }.background(Color.paper).navigationTitle("漫画分类").navigationBarTitleDisplayMode(.inline)
            .task { await load() }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { categories = try await MangaDexSource().categories(); error = nil }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct MangaDexCategoryListing: View {
    let category: MangaDexSource.Category
    @State private var browse = MangaBrowseModel()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: category.name, caption: "MangaDex")
                MangaBookGrid(comics: browse.comics)
                if let error = browse.error { LuoyeNotice(message: error) }
                if browse.loading { ProgressView().frame(maxWidth: .infinity) }
                else if browse.error != nil || !browse.ended {
                    Button(browse.error == nil ? "加载更多" : "重试") { Task { await load() } }
                        .font(.serif(13)).frame(maxWidth: .infinity)
                }
                if browse.ended && browse.comics.isEmpty && browse.error == nil {
                    LuoyeEmptyState(icon: "books.vertical", title: "这个分类还没有漫画", actionTitle: "刷新", action: { Task { await load(reset: true) } })
                }
            }.luoyeContentMargins(top: 16)
        }.background(Color.paper).navigationTitle(category.name).navigationBarTitleDisplayMode(.inline)
            .task { if browse.comics.isEmpty { await load() } }
            .refreshable { await load(reset: true) }
            .onDisappear { browse.cancel() }
    }
    private func load(reset: Bool = false) async {
        await browse.load(context: .init(sourceID: "mangadex", listingID: category.id), reset: reset) { page in
            let values = try await MangaDexSource().category(category.id, page: page)
            return .init(comics: values, isLast: values.count < 20)
        }
    }
}
