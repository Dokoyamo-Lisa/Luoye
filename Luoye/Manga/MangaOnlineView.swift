import SwiftUI

struct MangaOnlineView: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(MangaSourceStore.self) private var sources
    @AppStorage("manga.activeSource") private var selectedSource = "mangadex"
    @State private var query = ""
    @State private var submitted = ""
    @State private var browse = MangaBrowseModel()
    @State private var sourceMetadata: [String: Any] = [:]
    @State private var exploreIndex = 0
    @State private var searchOptions: [String] = []
    @State private var configuringSource = false
    private var source: any MangaCatalogSource {
        if var script = sources.source(for: selectedSource) as? MangaScriptSource {
            script.exploreIndex = exploreIndex
            script.searchOptions = searchOptions.isEmpty ? nil : searchOptions
            return script
        }
        return sources.source(for: selectedSource) ?? MangaDexSource()
    }

    private var browseContext: MangaBrowseModel.Context {
        .init(sourceID: selectedSource, keyword: submitted, exploreIndex: exploreIndex, searchOptions: searchOptions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LuoyeSearchBar(placeholder: "搜索当前漫画源", text: $query, onSubmit: {
                submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
                MangaSearchModel().remember(submitted)
                Task { await load(reset: true) }
            }, onClear: {
                submitted = ""; Task { await load(reset: true) }
            })
            sourceControls
            HStack {
                SectionTitle(title: submitted.isEmpty ? "精选漫画" : "搜索结果", trailing: source.displayName)
            }
            if let error = browse.error {
                LuoyeNotice(message: error, icon: "wifi.exclamationmark")
                Button("重试") { Task { await load() } }.font(.serif(13))
            }
            if browse.ended && browse.comics.isEmpty && !browse.loading && browse.error == nil {
                LuoyeEmptyState(icon: submitted.isEmpty ? "books.vertical" : "magnifyingglass",
                                title: submitted.isEmpty ? "这个栏目还没有漫画" : "没有找到相关漫画",
                                message: submitted.isEmpty ? "可以切换漫画源，或稍后刷新。" : "试试其他关键词，或切换漫画源。",
                                actionTitle: "刷新", action: { Task { await load(reset: true) } })
            }
            MangaBookGrid(comics: browse.comics)
            if !browse.comics.isEmpty && !browse.ended && browse.error == nil {
                Button(browse.loading ? "加载中…" : "加载更多") { Task { await load() } }
                    .disabled(browse.loading).font(.serif(13)).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            if browse.loading && browse.comics.isEmpty { ProgressView().frame(maxWidth: .infinity) }
        }
        .task(id: selectedSource) {
            configuringSource = true
            defer { configuringSource = false }
            sourceMetadata = [:]; exploreIndex = 0; searchOptions = []
            browse.prepare(browseContext)
            if let script = sources.source(for: selectedSource) as? MangaScriptSource {
                do {
                    let metadata = try JSONSerialization.jsonObject(with: await script.runtime.metadata()) as? [String: Any] ?? [:]
                    guard !Task.isCancelled else { return }
                    sourceMetadata = metadata
                    searchOptions = (metadata["searchOptions"] as? [[String: Any]] ?? []).map { option in
                        option["default"] as? String ?? String((option["options"] as? [String])?.first ?? "").components(separatedBy: "-").first ?? ""
                    }
                } catch { /* Metadata is optional; catalogue errors have a visible retry below. */ }
            }
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
        .onDisappear { browse.cancel() }
        .onChange(of: exploreIndex) { _, _ in if !configuringSource { Task { await load(reset: true) } } }
        .onChange(of: searchOptions) { _, _ in if !configuringSource && !submitted.isEmpty { Task { await load(reset: true) } } }
    }

    @ViewBuilder
    private var sourceControls: some View {
        if source is MangaScriptSource {
            let explore = sourceMetadata["explore"] as? [[String: Any]] ?? []
            if submitted.isEmpty && explore.count > 1 {
                Picker("发现栏目", selection: $exploreIndex) {
                    ForEach(Array(explore.enumerated()), id: \.offset) { index, value in Text(value["title"] as? String ?? "栏目").tag(index) }
                }
            }
            if !submitted.isEmpty {
                let options = sourceMetadata["searchOptions"] as? [[String: Any]] ?? []
                ForEach(Array(options.enumerated()), id: \.offset) { index, config in
                    if searchOptions.indices.contains(index) {
                        Picker(config["label"] as? String ?? "筛选", selection: Binding(get: { searchOptions[index] }, set: { searchOptions[index] = $0 })) {
                            ForEach(config["options"] as? [String] ?? [], id: \.self) { option in
                                let components = option.split(separator: "-", maxSplits: 1).map(String.init)
                                Text(components.count > 1 ? components[1] : option).tag(components.first ?? option)
                            }
                        }
                    }
                }
            }
        }
    }

    private func load(reset: Bool = false) async {
        let explore = sourceMetadata["explore"] as? [[String: Any]] ?? []
        let type = explore.indices.contains(exploreIndex) ? explore[exploreIndex]["type"] as? String : nil
        let singlePage = submitted.isEmpty && ["multiPartPage", "singlePageWithMultiPart"].contains(type ?? "")
        await browse.load(context: browseContext, source: source, reset: reset, singlePage: singlePage)
    }
}

struct MangaOnlineDetailView: View {
    @Environment(MangaLibrary.self) private var library
    let comic: MangaOnlineComic
    let source: any MangaCatalogSource
    @State private var chapterCatalog = MangaChapterCatalog()
    @State private var language = "all"
    @State private var detailsError: String?
    @State private var chapterToRead: MangaOnlineChapter?
    @State private var downloadingID: String?
    @State private var downloadError: String?
    @State private var sourceMetadata: [String: Any] = [:]
    @State private var sourceDetails: [String: Any] = [:]
    @State private var showingRating = false
    @State private var expandedSummary = false

    private var chapters: [MangaOnlineChapter] { chapterCatalog.chapters }
    private var loading: Bool { chapterCatalog.loading }
    private var languages: [String] { ["all"] + Array(Set(chapters.map(\.language))).sorted() }
    private var shown: [MangaOnlineChapter] {
        chapterCatalog.shown(language: language)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    MangaBookCover(comic: comic).frame(width: 112)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(comic.title).font(.serif(20, medium: true))
                        Text(source.displayName).font(.serif(12)).foregroundStyle(.secondary)
                        if !chapters.isEmpty { Text("已载入 \(chapters.count) 话").font(.serif(12)).foregroundStyle(.tertiary) }
                    }
                }
                HStack(spacing: 10) {
                    if let first = shown.first(where: { $0.externalURL == nil }) ?? shown.first {
                        Button {
                            chapterToRead = first
                        } label: { Label("开始阅读", systemImage: "book").frame(maxWidth: .infinity) }
                            .buttonStyle(LuoyeActionStyle(prominent: true))
                    }
                    Button { library.toggleFavorite(comic) } label: {
                        Image(systemName: library.isFavorite(comic) ? "heart.fill" : "heart")
                    }.buttonStyle(LuoyeActionStyle(selected: library.isFavorite(comic)))
                        .accessibilityLabel(library.isFavorite(comic) ? "取消收藏" : "收藏")
                    Button { library.toggleReadLater(comic) } label: {
                        Image(systemName: library.isReadLater(comic) ? "bookmark.fill" : "bookmark")
                    }.buttonStyle(LuoyeActionStyle(selected: library.isReadLater(comic)))
                        .accessibilityLabel(library.isReadLater(comic) ? "移出稍后阅读" : "稍后阅读")
                }
                sourceExtras
                if !comic.summary.isEmpty || sourceDetails["description"] is String {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "简介")
                        Text(sourceDetails["description"] as? String ?? comic.summary)
                            .font(.serif(13)).foregroundStyle(.secondary).lineSpacing(5)
                            .lineLimit(expandedSummary ? nil : 6).textSelection(.enabled)
                        Button(expandedSummary ? "收起" : "展开简介") { withAnimation(.smooth) { expandedSummary.toggle() } }
                            .font(.serif(12))
                    }.padding(.vertical, 8)
                }
                HStack {
                    SectionTitle(title: "章节", trailing: "\(shown.count) 话")
                    Button { Task { await loadChapters(reset: true) } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }.buttonStyle(.plain).disabled(loading).accessibilityLabel("刷新章节目录")
                }
                if loading { ProgressView() }
                if let error = chapterCatalog.error {
                    LuoyeNotice(message: error, icon: "wifi.exclamationmark")
                    Button("重试目录") { Task { await loadChapters() } }.buttonStyle(LuoyeActionStyle())
                }
                if let detailsError, chapterCatalog.error == nil { LuoyeNotice(message: detailsError) }
                if chapterCatalog.ended && shown.isEmpty && !loading && chapterCatalog.error == nil {
                    LuoyeEmptyState(icon: "list.bullet", title: "暂时没有可阅读的章节", message: "可以稍后刷新目录，或查看其他漫画源。")
                }
                if let downloadError { Text(downloadError).font(.serif(12)).foregroundStyle(.secondary) }
                if languages.count > 2 {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(languages, id: \.self) { value in
                                LuoyeChip(title: value == "all" ? "全部" : value, active: language == value) { language = value }
                            }
                        }
                    }
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { chapter in
                        HStack(spacing: 12) {
                            Button {
                                chapterToRead = chapter
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chapter.title).font(.serif(14)).foregroundStyle(Color.ink)
                                    Text(([chapter.language, chapter.group] + (chapter.externalURL == nil ? [] : ["网页解析"]))
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.serif(11)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if chapter.externalURL == nil {
                            Button {
                                downloadingID = chapter.id
                                Task {
                                    library.enqueueDownload(chapter, of: comic)
                                    downloadError = nil
                                    downloadingID = nil
                                }
                            } label: {
                                if downloadingID == chapter.id { ProgressView() }
                                else { Image(systemName: "arrow.down.circle") }
                            }
                            .disabled(downloadingID != nil)
                            .accessibilityLabel("下载\(chapter.title)")
                            .frame(width: 44, height: 44)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        Divider()
                    }
                }
                .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
                if !chapterCatalog.ended && !chapters.isEmpty && chapterCatalog.error == nil {
                    Button(loading ? "正在读取目录…" : "加载更多章节") { Task { await loadChapters() } }
                        .disabled(loading).font(.serif(13))
                }
            }
            .luoyeContentMargins(top: 16, maximumWidth: 900)
        }
        .background(Color.paper)
        .navigationTitle("漫画详情")
        .navigationBarTitleDisplayMode(.inline)
        .scrollBounceBehavior(.always)
        .refreshable { await loadChapters(reset: true) }
        .sheet(isPresented: $showingRating) {
            if let script = source as? MangaScriptSource { MangaRatingView(comic: comic, source: script) }
        }
        .fullScreenCover(item: $chapterToRead) {
            MangaOnlineReaderView(comic: comic, chapter: $0, source: source, chapters: chapters,
                                  nextChapterPage: chapterCatalog.nextPage, chapterEnded: chapterCatalog.ended, language: language).eyeCareFilter()
        }
        .task {
            library.recordViewed(comic)
            if chapters.isEmpty { await loadChapters() }
            guard !Task.isCancelled else { return }
            await loadSourceDetails()
        }
    }
    @ViewBuilder
    private var sourceExtras: some View {
        if let script = source as? MangaScriptSource {
            HStack(spacing: 18) {
                if sourceMetadata["favorites"] as? Bool == true {
                    NavigationLink("源站收藏") { MangaRemoteFavoritesView(source: script, comic: comic) }
                }
                if sourceMetadata["comments"] as? Bool == true {
                    NavigationLink("作品评论") { MangaCommentsView(comic: comic, source: script, subID: sourceDetails["subId"] as? String) }
                }
                if sourceMetadata["rating"] as? Bool == true { Button("评分") { showingRating = true } }
            }.font(.serif(13))
            if let tags = sourceDetails["tags"] as? [String: [String]] {
                ForEach(tags.keys.sorted(), id: \.self) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group).font(.serif(11)).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(tags[group] ?? [], id: \.self) { tag in
                                    NavigationLink {
                                        MangaSourceListingView(title: tag, source: script) { page in
                                            try await script.runtime.call("__tagComics", arguments: [group, tag, page])
                                        }
                                    } label: { Text(tag).font(.serif(12)).padding(8).background(Color.accentColor.opacity(0.08), in: Capsule()) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func loadChapters(reset: Bool = false) async {
        let loaded = await chapterCatalog.load(for: comic, from: source, reset: reset)
        if loaded && (reset || detailsError != nil) { await loadSourceDetails() }
    }
    private func loadSourceDetails() async {
        guard let script = source as? MangaScriptSource else { return }
        do {
            let metadata = try JSONSerialization.jsonObject(with: await script.runtime.metadata()) as? [String: Any] ?? [:]
            let details = try JSONSerialization.jsonObject(with: await script.runtime.call("__details", arguments: [comic.id])) as? [String: Any] ?? [:]
            guard !Task.isCancelled else { return }
            sourceMetadata = metadata; sourceDetails = details; detailsError = nil
        } catch { if !Task.isCancelled { detailsError = error.localizedDescription } }
    }

}

struct MangaOnlineReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(MangaLibrary.self) private var library
    @Environment(\.systemColorScheme) private var systemScheme
    @AppStorage("manga.reader.theme") private var readerTheme = ReaderTheme.paper
    let comic: MangaOnlineComic
    @State private var chapter: MangaOnlineChapter
    let source: any MangaCatalogSource
    let language: String
    @State private var chapterCatalog: MangaChapterCatalog
    private var catalogue: [MangaOnlineChapter] { chapterCatalog.shown(language: language) }
    private var chapterEnded: Bool { chapterCatalog.ended }
    @State private var changingChapter = false
    @State private var readerActive = true
    @State private var navigationID = UUID()
    @State private var autoPlay = false
    @State private var pageShownAt = Date()
    @State private var loadedPageKeys: Set<String> = []
    @AppStorage("manga.reader.autoMode") private var autoKind = AutoMode.pages
    @AppStorage("manga.reader.scrollLines") private var scrollLines = 30.0
    @AppStorage("manga.reader.autoPageSeconds") private var autoPageSeconds = 8.0
    @AppStorage("manga.reader.mode") private var mode = MangaReadingMode.pageLeftToRight
    @AppStorage("manga.reader.showPageNumber") private var showPageNumber = true
    @AppStorage("manga.reader.preloadCount") private var preloadCount = 2
    @AppStorage("manga.reader.twoPage") private var twoPage = false
    @AppStorage("manga.reader.coverAlone") private var coverAlone = true
    @State private var pages: [MangaImageRequest] = []
    @State private var page = 0
    @State private var visiblePage: Int?
    @State private var showsControls = false
    @State private var showsSettings = false
    @State private var showsComments = false
    @State private var supportsComments = false
    @State private var error: String?

    @State private var reloadID = UUID()
    @State private var startAtBeginning = false

    init(comic: MangaOnlineComic, chapter: MangaOnlineChapter, source: any MangaCatalogSource,
         chapters: [MangaOnlineChapter], nextChapterPage: Int, chapterEnded: Bool, language: String) {
        self.comic = comic; self.source = source; self.language = language
        _chapter = State(initialValue: chapter)
        _chapterCatalog = State(initialValue: MangaChapterCatalog(comic: comic, chapters: chapters, nextPage: nextChapterPage, ended: chapterEnded))
    }
    private var chapterIndex: Int? { catalogue.firstIndex { $0.id == chapter.id } }
    private var currentPagesReady: Bool {
        let indexes = MangaReadingNavigation.visiblePages(at: page, count: pages.count, mode: mode, twoPage: twoPage, coverAlone: coverAlone)
        return !indexes.isEmpty && indexes.allSatisfy { loadedPageKeys.contains(MangaPageResource.remote(pages[$0]).key) }
    }

    private var autoPageClock: MangaAutoPageClock {
        MangaAutoPageClock(active: autoPlay && autoKind == .pages && scenePhase == .active,
                           paused: showsControls || showsSettings || showsComments || !currentPagesReady, chapterID: chapter.id,
                           page: page, count: pages.count, mode: mode, twoPage: twoPage, coverAlone: coverAlone, seconds: autoPageSeconds)
    }

    var body: some View {
        let renderedPages = pages
        let renderedChapterID = chapter.id
        ZStack {
            Color.paper.ignoresSafeArea()
            if pages.isEmpty {
                if let error {
                    VStack(spacing: 18) {
                        Text(error).font(.serif(14)).multilineTextAlignment(.center).foregroundStyle(Color.ink)
                        Button("重新加载") { reloadID = UUID() }.buttonStyle(.glass)
                    }.padding(30)
                }
                else { ProgressView().tint(Color.accent) }
            } else if mode == .pageLeftToRight || mode == .pageRightToLeft {
                let rtl = mode == .pageRightToLeft
                let layout = MangaSpreadLayout(imageCount: renderedPages.count, coverAlone: coverAlone)
                let spreads = twoPage ? layout.spreads : Array(renderedPages.indices).map { [$0] }
                let selected = twoPage ? layout.spread(for: page) : page
                TabView(selection: Binding(
                    get: { rtl ? spreads.count - 1 - selected : selected },
                    set: { physical in
                        guard chapter.id == renderedChapterID else { return }
                        let logical = rtl ? spreads.count - 1 - physical : physical
                        if spreads.indices.contains(logical), let first = spreads[logical].first { record(first) }
                    }
                )) {
                    ForEach(Array(spreads.indices).sorted(by: { rtl ? $0 > $1 : $0 < $1 }), id: \.self) { spread in
                        GeometryReader { viewport in
                            HStack(spacing: 0) {
                                ForEach(rtl ? Array(spreads[spread].reversed()) : spreads[spread], id: \.self) { index in
                                    MangaImagePage(resource: .remote(renderedPages[index]), onLoading: {
                                        guard chapter.id == renderedChapterID else { return }
                                        loadedPageKeys.remove(MangaPageResource.remote(renderedPages[index]).key)
                                    }, onLoaded: {
                                        guard chapter.id == renderedChapterID else { return }
                                        loadedPageKeys.insert(MangaPageResource.remote(renderedPages[index]).key)
                                    }) { showsControls.toggle() }
                                        .frame(width: viewport.size.width / CGFloat(spreads[spread].count), height: viewport.size.height)
                                }
                            }
                        }
                        .tag(rtl ? spreads.count - 1 - spread : spread)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else {
                GeometryReader { viewport in
                    let indexes = Array(renderedPages.indices).sorted(by: { mode.isRTL ? $0 > $1 : $0 < $1 })
                    MangaScrollViewport(initialPage: page, mode: mode, visiblePage: $visiblePage) {
                        ScrollView(mode.isVertical ? .vertical : .horizontal) {
                            Group {
                                if mode.isVertical {
                                    LazyVStack(spacing: 0) {
                                        ForEach(indexes, id: \.self) { index in
                                            MangaImagePage(resource: .remote(renderedPages[index]), fitWidth: mode.isContinuous, onLoading: {
                                                guard chapter.id == renderedChapterID else { return }
                                                loadedPageKeys.remove(MangaPageResource.remote(renderedPages[index]).key)
                                            }, onLoaded: {
                                                guard chapter.id == renderedChapterID else { return }
                                                loadedPageKeys.insert(MangaPageResource.remote(renderedPages[index]).key)
                                            }) { showsControls.toggle() }
                                                .frame(height: mode.isContinuous ? nil : viewport.size.height).id(index)
                                                .accessibilityElement(children: .contain)
                                                .accessibilityIdentifier("manga.reader.page.\(index)")
                                        }
                                    }.scrollTargetLayout()
                                } else {
                                    LazyHStack(spacing: 3) {
                                        ForEach(indexes, id: \.self) { index in
                                            MangaImagePage(resource: .remote(renderedPages[index]), onLoading: {
                                                guard chapter.id == renderedChapterID else { return }
                                                loadedPageKeys.remove(MangaPageResource.remote(renderedPages[index]).key)
                                            }, onLoaded: {
                                                guard chapter.id == renderedChapterID else { return }
                                                loadedPageKeys.insert(MangaPageResource.remote(renderedPages[index]).key)
                                            }) { showsControls.toggle() }
                                                .frame(width: viewport.size.width, height: viewport.size.height).id(index)
                                                .accessibilityElement(children: .contain)
                                                .accessibilityIdentifier("manga.reader.page.\(index)")
                                        }
                                    }.scrollTargetLayout()
                                }
                            }
                            .background(MangaAutoScrollDriver(pointsPerSecond: autoPlay && autoKind == .scroll && mode == .continuousTopToBottom && scenePhase == .active && !showsControls && !showsSettings && !showsComments ? scrollLines * 24 / 60 : 0, readyToScroll: currentPagesReady, contentReady: pages.last.map { loadedPageKeys.contains(MangaPageResource.remote($0).key) } ?? false, onReachEnd: {
                                Task {
                                    guard chapter.id == renderedChapterID else { return }
                                    let previous = chapter.id
                                    await moveChapter(1, fromBoundary: true)
                                    if chapter.id == previous { autoPlay = false }
                                }
                            }))
                        }
                        .mangaPageSnapping(!mode.isContinuous)
                        .onChange(of: visiblePage) { _, value in if chapter.id == renderedChapterID, let value { record(value) } }
                    }.id(mode)
                }
            }
            if showPageNumber && !pages.isEmpty {
                VStack { Spacer(); MangaReaderFooter(title: chapter.title, page: page, count: pages.count) }
            }
            if autoPageClock.active && !autoPageClock.paused {
                AutoPageLine(start: pageShownAt, interval: max(3, autoPageSeconds))
            }
            Group {
                if !showsControls && autoPlay {
                    VStack { Spacer(); HStack { MangaAutoReadingControl(kind: autoKind, onShowControls: { showsControls = true }, onStop: { autoPlay = false }); Spacer(minLength: 0) } }
                }
                if showsControls || pages.isEmpty {
                    MangaReaderChrome(title: comic.title, subtitle: chapter.title,
                                      position: Binding(get: { Double(page) }, set: { if readerActive && chapter.id == renderedChapterID { record(Int($0)); visiblePage = page } }),
                                      pageCount: pages.count, showPageNumber: showPageNumber, autoPlay: $autoPlay,
                                      onClose: { readerActive = false; navigationID = UUID(); chapterCatalog.cancel(); dismiss() }, onSettings: { showsSettings = true },
                                      onComments: supportsComments ? { showsComments = true } : nil,
                                      onPrevious: { Task { guard chapter.id == renderedChapterID else { return }; await moveChapter(-1) } },
                                      onNext: { Task { guard chapter.id == renderedChapterID else { return }; await moveChapter(1) } },
                                      previousEnabled: !changingChapter && (chapterIndex ?? 0) > 0,
                                      nextEnabled: !changingChapter && !(chapterEnded && (chapterIndex ?? 0) >= catalogue.count - 1),
                                      message: pages.isEmpty ? nil : error,
                                      readingKey: comic.source + ":" + comic.id + ":" + chapter.id,
                                      chapters: catalogue, chapterID: chapter.id,
                                      onSelectChapter: {
                                          guard readerActive else { return }
                                          navigationID = UUID(); changingChapter = false
                                          startAtBeginning = false; chapter = $0; showsControls = false
                                      },
                                      onStartAuto: { showsControls = false }, onDismiss: { showsControls = false })
                }
            }.animation(.easeInOut(duration: 0.2), value: showsControls)
        }
        .environment(\.colorScheme, readerTheme.scheme(system: systemScheme))
        .tint(Color.accent)
        .modifier(ReaderMotionScope())
        .modifier(ReaderWakeLock(enabled: autoPlay))
        .sheet(isPresented: $showsSettings) { MangaReaderSettingsView() }
        .sheet(isPresented: $showsComments) {
            if let script = source as? MangaScriptSource {
                NavigationStack { MangaCommentsView(comic: comic, source: script, chapterID: chapter.id) }
            }
        }
        .task(id: chapter.id + reloadID.uuidString) {
            guard !Task.isCancelled, readerActive else { return }
            let requestedChapter = chapter
            pages = []; loadedPageKeys = []; page = 0; visiblePage = nil; error = nil
            do {
                if let script = source as? MangaScriptSource {
                    let metadata = try JSONSerialization.jsonObject(with: await script.runtime.metadata()) as? [String: Any] ?? [:]
                    supportsComments = metadata["chapterComments"] as? Bool ?? false
                }
                let loaded: [MangaImageRequest]
                if let url = requestedChapter.externalURL {
                    loaded = try await MangaWebChapterResolver.pages(from: url)
                } else {
                    loaded = try await source.pages(for: requestedChapter)
                }
                guard !Task.isCancelled, chapter.id == requestedChapter.id else { return }
                pages = loaded
                page = startAtBeginning ? 0 : min(library.onlinePage(comic: comic, chapter: requestedChapter), max(0, pages.count - 1))
                visiblePage = page
                if pages.isEmpty { error = "这一话没有可用图片。"; autoPlay = false }
                else {
                    library.recordOnlinePage(page, comic: comic, chapter: chapter)
                    startAtBeginning = false
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; autoPlay = false } }
        }
        .task(id: autoPageClock) {
            let clock = autoPageClock
            guard clock.active, !clock.paused, clock.count > 0 else { return }
            pageShownAt = Date()
            do { try await Task.sleep(for: .seconds(max(3, clock.seconds))); try Task.checkCancellation() }
            catch { return }
            guard autoPageClock == clock, !changingChapter else { return }
            if let next = MangaReadingNavigation.nextPage(after: page, count: pages.count, mode: mode, twoPage: twoPage, coverAlone: coverAlone) {
                record(next); visiblePage = page
            } else {
                let previous = chapter.id
                await moveChapter(1, fromBoundary: true)
                if previous == chapter.id { autoPlay = false }
            }
        }
        .onAppear { readerActive = true }
        .onDisappear { readerActive = false; autoPlay = false; navigationID = UUID(); changingChapter = false; chapterCatalog.cancel() }
        .task(id: chapter.id + ":" + String(page)) {
            guard chapter.id == renderedChapterID else { return }
            let requestedPages = pages, requestedPage = page
            guard !requestedPages.isEmpty else { return }
            let next = (1...max(1, preloadCount)).compactMap { step -> MangaPageResource? in
                let index = requestedPage + step
                return index < requestedPages.count ? .remote(requestedPages[index]) : nil
            }
            await MangaPageCache.shared.prefetch(next)
        }
        .onChange(of: mode) { _, _ in visiblePage = page }
    }

    private func record(_ index: Int) {
        guard index >= 0, index < pages.count, page != index else { return }
        page = index
        visiblePage = index
        library.recordOnlinePage(index, comic: comic, chapter: chapter)
    }
    private func moveChapter(_ direction: Int, fromBoundary: Bool = false) async {
        guard readerActive, !Task.isCancelled, !changingChapter, let index = chapterIndex else { return }
        let token = UUID(), origin = chapter.id
        navigationID = token
        changingChapter = true
        defer { if navigationID == token { changingChapter = false } }
        // Keep unfiltered IDs in the catalog, even when entire pages have another language.
        while direction > 0 && index + 1 >= catalogue.count && !chapterEnded {
            let loaded = await chapterCatalog.load(for: comic, from: source)
            guard !Task.isCancelled, navigationID == token, chapter.id == origin else { return }
            if !loaded {
                if let message = chapterCatalog.error {
                    error = message; autoPlay = false; showsControls = true
                }
                return
            }
        }
        guard readerActive, !Task.isCancelled, navigationID == token, chapter.id == origin else { return }
        let target = index + direction
        guard catalogue.indices.contains(target) else { return }
        startAtBeginning = fromBoundary
        chapter = catalogue[target]
    }
}
