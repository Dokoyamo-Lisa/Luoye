import SwiftUI

struct MangaSourceCategory: Identifiable {
    let id: Int
    let title: String
    let items: [Item]
    struct Item: Identifiable {
        let id: Int
        let name: String
        let param: String?
        let type: String
    }
}

struct MangaSourceCategoriesView: View {
    let source: MangaScriptSource
    @State private var groups: [MangaSourceCategory] = []
    @State private var error: String?
    @State private var loading = true
    @State private var query = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "漫画分类", caption: source.displayName)
                LuoyeSearchBar(placeholder: "查找分类与标签", text: $query)
                if !loading && groups.isEmpty && error == nil {
                    LuoyeEmptyState(icon: "square.grid.2x2", title: "这个漫画源暂未提供分类", message: "可以返回发现页搜索漫画，或切换其他漫画源。")
                }
                if loading { ProgressView() }
                if let error { Text(error).font(.serif(12)).foregroundStyle(.secondary) }
                ForEach(groups) { group in
                    SectionTitle(title: group.title)
                    FlowLayout(spacing: 8) {
                        ForEach(group.items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { item in
                            NavigationLink {
                                MangaSourceListingView(title: item.name, source: source) { page in
                                    if item.type == "search" { return try await source.runtime.call("__search", arguments: [item.name, page]) }
                                    return try await source.runtime.call("__categoryComics", arguments: [item.name, item.param as Any? ?? NSNull(), page])
                                }
                            } label: {
                                TagLabel(text: item.name)
                            }.buttonStyle(PressStyle())
                        }
                    }
                }
            }.luoyeContentMargins(top: 16)
        }
        .background(Color.paper).navigationTitle("漫画分类").navigationBarTitleDisplayMode(.inline)
        .task {
            defer { loading = false }
            do {
                let data = try await source.runtime.call("__categories")
                let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
                groups = values.enumerated().map { index, value in
                    let items = (value["items"] as? [[String: Any]] ?? []).enumerated().map { itemIndex, item in
                        MangaSourceCategory.Item(id: itemIndex, name: item["name"] as? String ?? "分类", param: item["param"] as? String, type: item["type"] as? String ?? "category")
                    }
                    return MangaSourceCategory(id: index, title: value["name"] as? String ?? "分类", items: items)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MangaSourceListingView: View {
    let title: String
    let source: MangaScriptSource
    let loadPage: @Sendable (Int) async throws -> Data
    @State private var browse = MangaBrowseModel()
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let error = browse.error { LuoyeNotice(message: error) }
                MangaBookGrid(comics: browse.comics)
                if browse.loading { ProgressView().frame(maxWidth: .infinity) }
                else if browse.error != nil || !browse.ended {
                    Button(browse.error == nil ? "加载更多" : "重试") { Task { await load() } }
                        .font(.serif(13)).frame(maxWidth: .infinity)
                }
                if browse.ended && browse.comics.isEmpty && browse.error == nil {
                    LuoyeEmptyState(icon: "books.vertical", title: "这里暂时没有漫画", actionTitle: "刷新", action: { Task { await load(reset: true) } })
                }
            }.luoyeContentMargins(top: 16)
        }
        .background(Color.paper).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task { if browse.comics.isEmpty { await load() } }
        .refreshable { await load(reset: true) }
        .onDisappear { browse.cancel() }
    }
    private func load(reset: Bool = false) async {
        await browse.load(context: .init(sourceID: source.id, listingID: title), reset: reset) { requested in
            let data = try await loadPage(requested)
            let values = try source.parseBooks(data)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return .init(comics: values, isLast: requested >= (object["maxPage"] as? Int ?? Int.max))
        }
    }
}
