import SwiftUI

struct WenkuCategoryView: View {
    @Environment(WenkuService.self) private var service
    @State private var facets: [WenkuFacet] = []
    @State private var search = ""
    @State private var loading = false
    @State private var generation = UUID()
    @State private var error: String?
    @State private var login = false
    @State private var verify = false

    private var groups: [String] {
        let order = ["文库分类", "作品筛选", "日常系", "幻想系", "黑深残", "人物属性类", "特殊属性类", "作品标签", "排行榜", "年度榜单"]
        return order.filter { name in
            facets.contains { $0.group == name && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArchiveHeading(title: "文库分类", subtitle: "WENKU8 / CATEGORIES")

                LuoyeSearchBar(
                    placeholder: "查找文库、标签或榜单…",
                    text: $search
                )

                if loading && facets.isEmpty {
                    ProgressView("正在整理文库分类…")
                        .font(.serif(13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                }

                if let error {
                    WenkuStatusView(
                        message: error,
                        loading: loading,
                        login: !service.authenticated,
                        onLogin: { login = true },
                        onRetry: { Task { await load() } },
                        onChallenge: { verify = true }
                    )
                }

                ForEach(groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        LuoyeSectionHeader(title: group)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 10)], spacing: 10) {
                            ForEach(facets.filter { $0.group == group && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { facet in
                                NavigationLink { WenkuCollectionView(facet: facet) } label: {
                                    Text(facet.name)
                                        .font(.serif(13))
                                        .foregroundStyle(Color.ink)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 10)
                                        .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12)
                                                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle("文库分类")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: service.authenticated) { await load() }
        .refreshable { await load(refresh: true) }
        .sheet(isPresented: $login) { WenkuLoginView() }
        .sheet(isPresented: $verify) { WenkuVerificationView() }
    }

    private func load(refresh: Bool = false) async {
        let token = UUID(); generation = token
        loading = true; error = nil
        defer { if generation == token { loading = false } }
        do {
            let source = try await service.page("/modules/article/toplist.php?sort=lastupdate", refresh: refresh)
            try Task.checkCancellation()
            guard generation == token else { return }
            facets = source.facets
            let home = try await service.page("/index.php", refresh: refresh)
            try Task.checkCancellation()
            guard generation == token else { return }
            let ids = Set(facets.map(\.id))
            facets += home.facets.filter { !ids.contains($0.id) }
        } catch is CancellationError {} catch { if generation == token { self.error = error.localizedDescription } }
    }
}

struct WenkuCollectionView: View {
    let facet: WenkuFacet
    @Environment(WenkuService.self) private var service
    @State private var books: [WenkuBook] = []
    @State private var page = 1
    @State private var loading = false
    @State private var generation = UUID()
    @State private var ended = false
    @State private var error: String?
    @State private var login = false
    @State private var verify = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ArchiveHeading(title: facet.name, subtitle: "WENKU8 · \(facet.group)")

                if let error {
                    WenkuStatusView(
                        message: error,
                        loading: loading,
                        login: !service.authenticated,
                        onLogin: { login = true },
                        onRetry: { Task { await load(reset: true) } },
                        onChallenge: { verify = true }
                    )
                }

                if loading && books.isEmpty {
                    ProgressView("正在翻阅…")
                        .font(.serif(13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 52)
                }

                WenkuBookGrid(books: books)

                if !loading && books.isEmpty && error == nil {
                    LuoyeEmptyState(
                        icon: "text.book.closed",
                        title: "这个分类暂时没有书籍",
                        message: "可下拉刷新或返回浏览其他分类。"
                    )
                }

                if !books.isEmpty && !ended {
                    Button {
                        Task { await load(reset: false) }
                    } label: {
                        Text(loading ? "正在加载…" : "继续浏览")
                            .font(.serif(13, medium: true))
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(loading)
                }
            }
            .luoyeContentMargins(top: 16)
            .padding(.bottom, 20)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle(facet.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: WenkuBook.self) { WenkuDetailView(book: $0) }
        .task(id: service.authenticated) { await load(reset: true) }
        .refreshable { await load(reset: true, refresh: true) }
        .sheet(isPresented: $login) { WenkuLoginView() }
        .sheet(isPresented: $verify) { WenkuVerificationView() }
    }

    private func load(reset: Bool, refresh: Bool = false) async {
        guard reset || !loading else { return }
        let token = UUID(); generation = token
        loading = true; error = nil
        defer { if generation == token { loading = false } }
        do {
            let requestedPage = reset ? 1 : page
            let base = facet.path.replacingOccurrences(of: "[?&]page=\\d+", with: "", options: .regularExpression)
            let route = base + (base.contains("?") ? "&" : "?") + "page=\(requestedPage)"
            let result = try await service.page(route, refresh: refresh)
            try Task.checkCancellation()
            guard generation == token else { return }
            if refresh && result.books.isEmpty && !books.isEmpty { throw WenkuFailure.invalid }
            if reset {
                books = result.books
                ended = result.books.isEmpty || facet.group == "年度榜单"
                page = 2
                return
            }
            let ids = Set(books.map(\.id))
            let fresh = result.books.filter { !ids.contains($0.id) }
            books += fresh
            ended = fresh.isEmpty || facet.group == "年度榜单"
            page = requestedPage + 1
        } catch is CancellationError {} catch { if generation == token { self.error = error.localizedDescription } }
    }
}
