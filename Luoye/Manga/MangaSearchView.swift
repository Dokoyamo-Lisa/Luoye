import SwiftUI

struct MangaSearchView: View {
    @Environment(MangaSourceStore.self) private var sources
    @State private var model = MangaSearchModel()
    @State private var query = ""
    @State private var job: Task<Void, Never>?
    @State private var selected = Set<String>()
    @State private var choosingSources = false
    private var available: [(String, String)] {
        [("mangadex", "MangaDex")] + sources.sources.filter(\.enabled).map { ($0.key, $0.name) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LuoyeSearchBar(placeholder: "搜索多个漫画源", text: $query, onSubmit: { search() }, trailing: {
                    Button("搜索") { search() }.font(.serif(13, medium: true))
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                })
                HStack {
                    Button("选择漫画源（\(selected.count)）") { choosingSources = true }
                    Spacer()
                    if model.searching { Button("停止") { job?.cancel(); model.cancel() } }
                }.font(.serif(13))
                if model.keyword.isEmpty && !model.history.isEmpty {
                    HStack {
                        Text("搜索历史").font(.serif(15, medium: true))
                        Spacer()
                        Button("清除") { model.clearHistory() }.font(.serif(12))
                    }
                    ForEach(model.history, id: \.self) { word in
                        Button(word) { query = word; search() }.font(.serif(14))
                    }
                }
                if model.searching {
                    ProgressView(value: Double(model.sections.filter { !$0.loading }.count), total: Double(max(model.sections.count, 1)))
                }
                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(section.name).font(.serif(16, medium: true))
                            Spacer()
                            Text("\(section.comics.count) 部").font(.serif(11)).foregroundStyle(.secondary)
                            if section.loading { ProgressView() }
                        }
                        if let error = section.error { Text(error).font(.serif(12)).foregroundStyle(.secondary) }
                        if !section.loading && section.comics.isEmpty && section.error == nil {
                            Text("没有找到相关漫画").font(.serif(12)).foregroundStyle(.secondary)
                        }
                        MangaBookGrid(comics: section.comics)
                        if !section.loading && !model.searching && (!section.ended || section.error != nil), let source = sources.source(for: section.id) {
                            Button(section.error == nil ? "加载更多" : "重试") { Task { await model.loadMore(from: source) } }.font(.serif(13))
                        }
                    }.padding(.vertical, 8)
                    Divider()
                }
            }.luoyeContentMargins(top: 16)
        }
        .background(Color.paper).navigationTitle("多源搜索").navigationBarTitleDisplayMode(.inline)
        .task { selected = Set(available.map(\.0)) }
        .onDisappear { job?.cancel(); model.cancel() }
        .sheet(isPresented: $choosingSources) {
            NavigationStack {
                List {
                    Button(selected.count == available.count ? "取消全选" : "全选") {
                        selected = selected.count == available.count ? [] : Set(available.map(\.0))
                    }
                    ForEach(available, id: \.0) { key, name in
                        Toggle(name, isOn: Binding(get: { selected.contains(key) }, set: { if $0 { selected.insert(key) } else { selected.remove(key) } }))
                    }
                }.luoyeFormStyle().navigationTitle("参与搜索的漫画源")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { choosingSources = false } } }
            }
        }
    }
    private func search() {
        job?.cancel(); model.cancel()
        let active = available.filter { selected.contains($0.0) }.compactMap { sources.source(for: $0.0) }
        guard !active.isEmpty else { choosingSources = true; return }
        let keyword = query
        job = Task { await model.search(keyword, sources: active) }
    }
}
