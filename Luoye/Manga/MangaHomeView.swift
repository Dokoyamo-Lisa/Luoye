import SwiftUI

struct MangaHomeView: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(MangaSourceStore.self) private var sources
    @Environment(MangaSyncService.self) private var sync
    @AppStorage("manga.home.tab") private var tab = "discover"

    var body: some View {
        TabView(selection: $tab) {
            Tab("发现", image: "TabDiscover", value: "discover") { MangaDiscoverPage() }
            Tab("书斋", image: "TabStudy", value: "library") { MangaLibraryPage() }
            Tab("历史", image: "TabHistory", value: "history") { MangaHistoryPage() }
            Tab("我的", image: "TabMe", value: "settings") { MangaSettingsPage() }
        }
        .toolbarBackground(.hidden, for: .tabBar)
        .task {
            library.sourceStore = sources
            sync.attach(library)
            await sources.installDefaultsIfNeeded()
        }
    }
}

private struct MangaDiscoverPage: View {
    @Environment(MangaSourceStore.self) private var sources
    @AppStorage("manga.activeSource") private var selectedSource = "mangadex"
    @State private var choosingSource = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        LuoyeModeHeading(caption: "发现漫画")
                        Spacer()
                        NavigationLink { MangaSearchView() } label: { GlassCircleLabel(systemImage: "magnifyingglass") }
                            .buttonStyle(.plain).accessibilityLabel("多源搜索")
                        NavigationLink { MangaCategoriesPage(sourceID: selectedSource) } label: { GlassCircleLabel(systemImage: "square.grid.2x2") }
                            .buttonStyle(.plain).accessibilityLabel("漫画分类")
                        Button { choosingSource = true } label: { GlassCircleLabel(systemImage: "square.stack") }
                            .buttonStyle(.plain).accessibilityLabel("切换漫画源")
                    }
                    if sources.installingDefaults {
                        ProgressView("正在准备漫画源 \(sources.defaultProgress) / \(sources.defaultTotal)", value: Double(sources.defaultProgress), total: Double(max(sources.defaultTotal, 1)))
                            .font(.serif(12))
                    }
                    MangaOnlineView()
                }.luoyeContentMargins()
            }
            .scrollDismissesKeyboard(.immediately)
            .luoyeRootSurface()
            .sheet(isPresented: $choosingSource) { MangaSourcePickerView().presentationDetents([.medium, .large]) }
        }
    }
}

private struct MangaLibraryPage: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("manga.library.scope") private var scope = "local"
    @State private var importing = false
    @State private var openedComic: MangaComic?
    @State private var failedImports: [String] = []
    @State private var comicToRemove: MangaComic?
    private var metrics: ShelfMetrics { .of(sizeClass) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.headerGap) {
                    HStack {
                        PageHeader(title: "书斋", caption: "把喜欢的故事留在手边", titleSize: metrics.titleSize)
                        Spacer()
                        Button { importing = true } label: { GlassCircleLabel(systemImage: "plus") }
                            .buttonStyle(.plain).accessibilityLabel("导入漫画")
                    }
                    ChipBar(options: ["local", "favorites", "later"], selection: $scope, bleed: metrics.margin) {
                        switch $0 { case "favorites": "收藏"; case "later": "稍后阅读"; default: "本地漫画" }
                    }
                    if scope == "local" {
                        if library.comics.isEmpty {
                            LuoyeEmptyState(icon: "photo.on.rectangle.angled", title: "书斋尚空", message: "添一本漫画，留一段闲暇。\n支持 CBZ、ZIP 与 PDF。", actionTitle: "导入漫画", action: { importing = true })
                        } else {
                            SectionTitle(title: "本地漫画", trailing: "\(library.comics.count) 本")
                            LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: metrics.rowGap) {
                                ForEach(library.comics) { comic in
                                    Button { openedComic = comic } label: {
                                        ShelfTile(title: comic.title, author: comic.format.uppercased(), large: sizeClass == .regular,
                                                  progress: comic.lastOpenedAt == nil ? nil : Double(comic.page + 1) / Double(max(comic.pageCount, 1))) {
                                            MangaLocalCover(comic: comic)
                                        }
                                    }.buttonStyle(PressStyle())
                                        .contextMenu { Button("移出漫画书斋", systemImage: "trash", role: .destructive) { comicToRemove = comic } }
                                }
                            }
                        }
                    } else {
                        if scope == "favorites" {
                            NavigationLink { MangaRemoteFavoriteSourcesView() } label: {
                                LuoyeSettingsRow(title: "源站收藏", icon: "heart.text.clipboard", detail: "按漫画源查看")
                            }.buttonStyle(.plain).background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
                        }
                        let comics = scope == "favorites" ? library.favorites : library.readLater
                        if comics.isEmpty {
                            LuoyeEmptyState(icon: scope == "favorites" ? "heart" : "bookmark", title: scope == "favorites" ? "还没有收藏" : "留一些故事，慢慢读", message: "在漫画详情页收藏或加入稍后阅读，就会出现在这里。")
                        } else { MangaBookGrid(comics: comics) }
                    }
                }.luoyeContentMargins()
            }
            .luoyeRootSurface()
            .fileImporter(isPresented: $importing, allowedContentTypes: MangaLibrary.supportedTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task {
                        var failures: [String] = []
                        for url in urls {
                            do { try await library.importComic(from: url) }
                            catch { failures.append(url.lastPathComponent + "：" + error.localizedDescription) }
                        }
                        failedImports = failures
                    }
                }
            }
            .fullScreenCover(item: $openedComic) { ComicReaderView(comic: $0).eyeCareFilter() }
            .alert("部分漫画未能导入", isPresented: Binding(get: { !failedImports.isEmpty }, set: { if !$0 { failedImports = [] } })) {
                Button("知道了") { failedImports = [] }
            } message: { Text(failedImports.joined(separator: "\n")) }
            .confirmationDialog("将《\(comicToRemove?.title ?? "")》移出书斋？", isPresented: Binding(get: { comicToRemove != nil }, set: { if !$0 { comicToRemove = nil } }), titleVisibility: .visible) {
                Button("移出书斋", role: .destructive) { if let comicToRemove { library.remove(comicToRemove.id) }; comicToRemove = nil }
            } message: { Text("原文件不受影响。") }
        }
    }
}

private struct MangaHistoryPage: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var openedComic: MangaComic?
    @State private var scope = "all"
    private var localHistory: [MangaComic] {
        library.comics.filter { $0.lastOpenedAt != nil }.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(title: "历史", caption: "翻过的每一页，都有迹可循", titleSize: ShelfMetrics.of(sizeClass).titleSize)
                    ChipBar(options: ["all", "local", "online"], selection: $scope) {
                        switch $0 { case "local": "本地阅读"; case "online": "在线浏览"; default: "全部足迹" }
                    }
                    if localHistory.isEmpty && library.recent.isEmpty {
                        LuoyeEmptyState(icon: "clock", title: "还没有阅读足迹", message: "打开漫画后，就会在这里留下记录。")
                    } else {
                        if scope != "online" && !localHistory.isEmpty {
                            SectionTitle(title: "本地阅读", trailing: "\(localHistory.count) 本")
                            LazyVGrid(columns: ShelfMetrics.of(sizeClass).columns, alignment: .leading, spacing: 20) {
                                ForEach(localHistory) { comic in
                                    Button { openedComic = comic } label: {
                                        ShelfTile(title: comic.title, author: "第 \(comic.page + 1) 页", progress: Double(comic.page + 1) / Double(max(comic.pageCount, 1))) { MangaLocalCover(comic: comic) }
                                    }.buttonStyle(PressStyle())
                                }
                            }
                        }
                        if scope != "local" && !library.recent.isEmpty {
                            SectionTitle(title: "在线浏览", trailing: "\(library.recent.count) 部")
                            MangaBookGrid(comics: library.recent, history: true)
                        }
                    }
                }.luoyeContentMargins()
            }.luoyeRootSurface()
                .fullScreenCover(item: $openedComic) { ComicReaderView(comic: $0).eyeCareFilter() }
        }
    }
}

private struct MangaSettingsPage: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(MangaSourceStore.self) private var sources
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("app.appearance") private var appearance = AppAppearance.system
    @AppStorage("app.eyeCare") private var eyeCare = false
    private var activeDownloads: Int { library.downloads.filter { $0.status != .completed }.count }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack { PageHeader(title: "我的", titleSize: ShelfMetrics.of(sizeClass).titleSize); Spacer(); LuoyeModeHeading(caption: "漫画空间", compact: true) }
                    LuoyePanel {
                        HStack(spacing: 16) {
                            Image(systemName: "leaf").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(.tint)
                                .frame(width: 60, height: 60).background(Color.accent.opacity(0.09), in: Circle())
                            VStack(alignment: .leading, spacing: 6) {
                                Text("故事，自成一隅").font(.serif(19))
                                Text("\(library.comics.count) 本漫画 · \(library.favorites.count) 部收藏 · \(sources.sources.filter(\.enabled).count) 个漫画源")
                                    .font(.serif(11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(20)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "漫画与阅读")
                        LuoyePanel {
                            NavigationLink { LuoyeSettingsPage(title: "下载管理") { MangaDownloadsView() } } label: {
                                LuoyeSettingsRow(title: "下载管理", icon: "arrow.down.circle", detail: activeDownloads == 0 ? "离线阅读" : "\(activeDownloads) 个任务")
                            }
                            LuoyePanelDivider()
                            NavigationLink { MangaReaderSettingsView(inNavigationStack: true) } label: { LuoyeSettingsRow(title: "阅读设置", icon: "textformat.size") }
                            LuoyePanelDivider()
                            NavigationLink { MangaDataSettingsView() } label: { LuoyeSettingsRow(title: "备份与同步", icon: "icloud", detail: "WebDAV") }
                        }.buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "漫画源", trailing: "已缓存 \(sources.sources.count) 个")
                        LuoyePanel {
                            NavigationLink { MangaSourcesView() } label: { LuoyeSettingsRow(title: "漫画源管理", icon: "square.grid.2x2") }
                            LuoyePanelDivider()
                            Button { Task { await sources.refreshAllSources() } } label: {
                                HStack {
                                    LuoyeSettingsRow(title: sources.refreshingSources ? "正在刷新漫画源…" : "刷新漫画源", icon: "arrow.clockwise", arrow: false)
                                    if sources.refreshingSources { ProgressView().padding(.trailing, 17) }
                                }
                            }.disabled(sources.refreshingSources || sources.installingDefaults)
                            LuoyePanelDivider()
                            NavigationLink { MangaRemoteFavoriteSourcesView() } label: { LuoyeSettingsRow(title: "源站账户与收藏", icon: "heart") }
                        }.buttonStyle(.plain)
                        Text("启动时直接读取本地漫画源，手动刷新才检查更新。刷新失败会保留已有配置。")
                            .font(.serif(12)).foregroundStyle(.secondary)
                        if sources.refreshingSources { ProgressView(value: Double(sources.refreshProgress), total: Double(max(sources.refreshTotal, 1))) }
                        if let date = sources.lastRefresh { Text("上次刷新 · " + date.formatted(date: .abbreviated, time: .shortened)).font(.serif(11)).foregroundStyle(.tertiary) }
                        if let message = sources.refreshMessage { LuoyeNotice(message: message) }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "外观")
                        LuoyePanel {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("界面外观").font(.serif(15))
                                ChoiceRow(options: AppAppearance.allCases, selection: $appearance) { $0.label }
                            }.padding(17)
                            LuoyePanelDivider()
                            Toggle("护眼模式", isOn: $eyeCare).font(.serif(15)).padding(17)
                        }
                    }
                    Text("落叶 · 把故事留在手边").font(.serif(12)).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 8)
                }.luoyeContentMargins(maximumWidth: 820)
            }.luoyeRootSurface()
        }
    }
}
