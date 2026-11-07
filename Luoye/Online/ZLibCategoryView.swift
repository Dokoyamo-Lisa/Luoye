import SwiftUI

struct ZLibCategoryView: View {
    @Environment(ZLibService.self) private var service
    @State private var mode = "categories"
    @State private var filterText = ""
    @State private var facets: [ZLibFacet] = []
    @State private var booklists: [ZLibBooklist] = []
    @State private var listOrder = "popular"
    @State private var listPage = 1
    @State private var listEnded = false
    @State private var loading = false
    @State private var error: String?
    @State private var verifying = false

    private let modes: [LuoyeSegmentItem<String>] = [
        .init(value: "categories", title: "学科与分类"),
        .init(value: "booklists", title: "公共书单")
    ]

    private var groupedFacets: [(String, [ZLibFacet])] {
        let keyword = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = keyword.isEmpty
            ? facets
            : facets.filter { $0.name.localizedCaseInsensitiveContains(keyword) || $0.group.localizedCaseInsensitiveContains(keyword) }
        let groups = Dictionary(grouping: filtered, by: \.group)
        return groups.keys.sorted().map { key in
            (key, (groups[key] ?? []).sorted { $0.name < $1.name })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ArchiveHeading(
                    title: mode == "categories" ? "学科与分类" : "精选书单",
                    subtitle: mode == "categories" ? "Z-LIBRARY / CATEGORIES" : "Z-LIBRARY / BOOKLISTS"
                )

                LuoyeSegmentBar(items: modes, selection: $mode)

                if mode == "categories" {
                    LuoyeSearchBar(
                        placeholder: "筛选学科或分类名称…",
                        text: $filterText
                    )

                    if let error {
                        ZLibStatusView(
                            message: error,
                            loading: loading,
                            login: false,
                            onLogin: {},
                            onRetry: { Task { await loadCategories(refresh: true) } },
                            onChallenge: { verifying = true }
                        )
                    }
                    if loading && facets.isEmpty {
                        ProgressView("正在整理分类目录…")
                            .font(.serif(13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 44)
                    }
                    ForEach(groupedFacets, id: \.0) { group, items in
                        VStack(alignment: .leading, spacing: 11) {
                            LuoyeSectionHeader(title: group, trailing: "\(items.count)")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
                                ForEach(items) { item in
                                    NavigationLink(value: item) {
                                        HStack(spacing: 6) {
                                            Text(item.name)
                                                .font(.serif(13))
                                                .foregroundStyle(Color.ink)
                                                .lineLimit(1)
                                            Spacer(minLength: 2)
                                            if let count = item.count {
                                                Text("\(count)")
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 11)
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
                } else {
                    HStack(spacing: 8) {
                        ForEach([("popular", "热门书单"), ("date_created", "最新创建")], id: \.0) { item in
                            LuoyeChip(title: item.1, active: listOrder == item.0) {
                                listOrder = item.0
                            }
                        }
                        Spacer()
                    }

                    if let error {
                        ZLibStatusView(
                            message: error,
                            loading: loading,
                            login: false,
                            onLogin: {},
                            onRetry: { Task { await loadBooklists(reset: true, refresh: true) } },
                            onChallenge: { verifying = true }
                        )
                    }
                    if loading && booklists.isEmpty {
                        ProgressView("正在翻阅书单…")
                            .font(.serif(13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 44)
                    }
                    ZLibBooklistStack(booklists: booklists)
                    if !booklists.isEmpty && !listEnded {
                        Button {
                            Task { await loadBooklists(reset: false) }
                        } label: {
                            Text(loading ? "正在加载…" : "加载更多书单")
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
            }
            .luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle(mode == "categories" ? "Z-Library 分类" : "精选书单")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ZLibFacet.self) { ZLibCollectionView(facet: $0) }
        .navigationDestination(for: ZLibBooklist.self) { ZLibBooklistDetailView(booklist: $0) }
        .navigationDestination(for: ZLibBook.self) { ZLibDetailView(book: $0) }
        .task(id: "\(mode)|\(listOrder)") {
            if mode == "categories" {
                if facets.isEmpty { await loadCategories() }
            } else {
                await loadBooklists(reset: true)
            }
        }
        .refreshable {
            if mode == "categories" {
                await loadCategories(refresh: true)
            } else {
                await loadBooklists(reset: true, refresh: true)
            }
        }
        .sheet(isPresented: $verifying) { ZLibVerificationView() }
    }

    private func loadCategories(refresh: Bool = false) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await service.page("/categories", refresh: refresh)
            facets = page.facets
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadBooklists(reset: Bool, refresh: Bool = false) async {
        guard reset || !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        if reset {
            listPage = 1
            booklists = []
            listEnded = false
        }
        do {
            let path = ZLibService.booklistsPath(order: listOrder, page: listPage)
            let page = try await service.page(path, refresh: refresh)
            let existing = Set(booklists.map(\.id))
            let fresh = page.booklists.filter { !existing.contains($0.id) }
            booklists += fresh
            listEnded = fresh.isEmpty || !page.hasNextPage
            listPage += 1
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ZLibBooklistStack: View {
    let booklists: [ZLibBooklist]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(booklists) { list in
                NavigationLink(value: list) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(list.title)
                                .font(.serif(16, medium: true))
                                .foregroundStyle(Color.ink)
                                .lineLimit(2)
                            Spacer()
                            if list.count > 0 {
                                Text("\(list.count) 本")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !list.description.isEmpty {
                            Text(list.description)
                                .font(.serif(13))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        HStack(spacing: 12) {
                            if !list.author.isEmpty {
                                Label(list.author, systemImage: "person")
                            }
                            if !list.views.isEmpty {
                                Label(list.views, systemImage: "eye")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.ink.opacity(0.06), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ZLibCollectionView: View {
    let facet: ZLibFacet
    @Environment(ZLibService.self) private var service
    @State private var books: [ZLibBook] = []
    @State private var page = 1
    @State private var ended = false
    @State private var loading = false
    @State private var generation = UUID()
    @State private var error: String?
    @State private var login = false
    @State private var verifying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ArchiveHeading(title: facet.name, subtitle: "Z-LIBRARY · \(facet.group)")
                if let error {
                    ZLibStatusView(
                        message: error,
                        loading: loading,
                        login: !service.authenticated,
                        onLogin: { login = true },
                        onRetry: { Task { await load(reset: true) } },
                        onChallenge: { verifying = true }
                    )
                }
                if loading && books.isEmpty {
                    ProgressView("正在翻阅书库…")
                        .font(.serif(13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 52)
                }
                ZLibBookGrid(books: books)
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
                } else if books.isEmpty && !loading && error == nil {
                    LuoyeEmptyState(
                        icon: "books.vertical",
                        title: "暂无相关书籍",
                        message: "该分类下暂无公开书目。"
                    )
                }
            }
            .luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle(facet.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ZLibBook.self) { ZLibDetailView(book: $0) }
        .task(id: facet.path) { await load(reset: true) }
        .refreshable { await load(reset: true, refresh: true) }
        .sheet(isPresented: $login) { ZLibLoginView() }
        .sheet(isPresented: $verifying) { ZLibVerificationView() }
    }

    private func load(reset: Bool, refresh: Bool = false) async {
        guard reset || !loading else { return }
        let token = UUID()
        generation = token
        loading = true
        error = nil
        defer { if generation == token { loading = false } }
        if reset {
            books = []
            page = 1
            ended = false
        }
        do {
            let base = facet.path.replacingOccurrences(of: "[?&]page=\\d+", with: "", options: .regularExpression)
            let route = base + (base.contains("?") ? "&" : "?") + "page=\(page)"
            let result = try await service.page(route, refresh: refresh)
            try Task.checkCancellation()
            guard generation == token else { return }
            let ids = Set(books.map(\.id))
            let fresh = result.books.filter { !ids.contains($0.id) }
            books += fresh
            ended = fresh.isEmpty || !result.hasNextPage
            page += 1
        } catch is CancellationError {
        } catch {
            if generation == token {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ZLibBooklistDetailView: View {
    let booklist: ZLibBooklist
    @Environment(ZLibService.self) private var service
    @State private var books: [ZLibBook] = []
    @State private var page = 1
    @State private var ended = false
    @State private var loading = false
    @State private var generation = UUID()
    @State private var error: String?
    @State private var login = false
    @State private var verifying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ArchiveHeading(
                    title: booklist.title,
                    subtitle: booklist.count > 0 ? "BOOKLIST · \(booklist.count) BOOKS" : "BOOKLIST"
                )
                if !booklist.description.isEmpty {
                    Text(booklist.description)
                        .font(.serif(14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)
                }
                if let error {
                    ZLibStatusView(
                        message: error,
                        loading: loading,
                        login: !service.authenticated,
                        onLogin: { login = true },
                        onRetry: { Task { await load(reset: true) } },
                        onChallenge: { verifying = true }
                    )
                }
                if loading && books.isEmpty {
                    ProgressView("正在展开书单…")
                        .font(.serif(13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 52)
                }
                ZLibBookGrid(books: books)
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
                } else if books.isEmpty && !loading && error == nil {
                    LuoyeEmptyState(
                        icon: "books.vertical",
                        title: "书单内暂无书籍",
                        message: "该书单当前没有可显示的公开条目。"
                    )
                }
            }
            .luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle(booklist.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ZLibBook.self) { ZLibDetailView(book: $0) }
        .task(id: booklist.path) { await load(reset: true) }
        .refreshable { await load(reset: true, refresh: true) }
        .sheet(isPresented: $login) { ZLibLoginView() }
        .sheet(isPresented: $verifying) { ZLibVerificationView() }
    }

    private func load(reset: Bool, refresh: Bool = false) async {
        guard reset || !loading else { return }
        let token = UUID()
        generation = token
        loading = true
        error = nil
        defer { if generation == token { loading = false } }
        if reset {
            books = []
            page = 1
            ended = false
        }
        do {
            if page == 1 {
                let result = try await service.page(booklist.path, refresh: refresh)
                try Task.checkCancellation()
                guard generation == token else { return }
                books = result.books
                ended = result.books.isEmpty || (!result.hasNextPage && result.books.count >= max(1, booklist.count))
                page = 2
            } else {
                let more = try await service.fetchBooklistMorePage(booklistId: booklist.id, page: page)
                try Task.checkCancellation()
                guard generation == token else { return }
                let existing = Set(books.map(\.id))
                let fresh = more.books.filter { !existing.contains($0.id) }
                books += fresh
                ended = fresh.isEmpty || !more.hasNext
                page += 1
            }
        } catch is CancellationError {
        } catch {
            if generation == token {
                self.error = error.localizedDescription
            }
        }
    }
}
