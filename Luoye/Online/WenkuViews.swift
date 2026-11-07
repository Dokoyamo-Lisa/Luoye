import SwiftUI
import SwiftData
import WebKit

struct FanhuaRootView: View {
    @AppStorage("luoye.mode") private var mode = "haiku"
    @AppStorage("haiku.home.tab") private var haikuTab = "discover"
    @State private var mangaLibrary = MangaLibrary()
    @State private var mangaSources = MangaSourceStore()
    @State private var mangaSync = MangaSyncService()
    @State private var service = WenkuService()
    @State private var zlibService = ZLibService()
    @State private var tomatoStore = TomatoStore()
    @State private var history = BrowsingHistoryStore()
    @State private var websiteShelf = WebsiteShelfStore()
    @State private var zlibAccount = ZLibAccountStore()
    @State private var sessionReady = UserDefaults.standard.string(forKey: "fanhua.activeSource") == "tomato"

    var body: some View {
        Group {
            if mode == "manga" {
                MangaHomeView()
                    .environment(mangaLibrary)
                    .environment(mangaSources)
                    .environment(mangaSync)
                    .modifier(MangaScriptPromptHost())
            } else if sessionReady {
                TabView(selection: $haikuTab) {
                    Tab("发现", image: "TabDiscover", value: "discover") { WenkuDiscoverView() }
                    Tab("书斋", image: "TabStudy", value: "library") { BookshelfView() }
                    Tab("历史", image: "TabHistory", value: "history") { BrowsingHistoryView() }
                    Tab("我的", image: "TabMe", value: "settings") { WenkuAccountView() }
                }
                .toolbarBackground(.hidden, for: .tabBar)
            } else {
                Color.paper
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 14) {
                            Image(systemName: "leaf")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(Color.accentColor)
                            ProgressView()
                                .tint(.accentColor)
                            Text("正在整理书斋…")
                                .font(.serif(14))
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .environment(service)
        .environment(zlibService)
        .environment(tomatoStore)
        .modifier(MangaImageVerificationHost())
        .modifier(TomatoOfflineVerificationHost())
        .modifier(TomatoReaderVerificationHost())
        .modifier(ReaderMotionVerificationHost())
        .modifier(ReaderMenuVerificationHost())
        .modifier(MangaOnlineReaderVerificationHost())
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--verify-tomato-import") { await TomatoImportVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-book-import-collision") { BookImportCollisionVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-book-import-commit") { await BookImportCommitVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-zlib-transport") { await ZLibTransportVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-manga-page-image") { await MangaPageImageVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-reader-font") { ReaderFontVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-reader-boundaries") { await ReaderBoundaryVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-reader-wake") { ReaderWakeVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-reader-progress") { await ReaderProgressVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-reader-motion") { await ReaderMotionVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-comic-index") { await ComicIndexVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-manga-zoom") { MangaZoomVerification.run() }
            #endif
        }
        .environment(history)
        .environment(websiteShelf)
        .environment(zlibAccount)
        .task(id: "\(mode)|\(service.accountKey ?? "")") {
            guard mode == "haiku" else { return }
            websiteShelf.activate(service.accountKey)
            if service.authenticated && (UserDefaults.standard.object(forKey: "wenku.autoSyncShelf") as? Bool ?? true) {
                if let last = websiteShelf.syncedAt, Date().timeIntervalSince(last) < 900 { return }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                while websiteShelf.syncing {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return }
                }
                await websiteShelf.sync(using: service)
            }
        }
        .task(id: "\(mode)|\(zlibService.accountKey ?? "")") {
            guard mode == "haiku" else { return }
            zlibAccount.activate(zlibService.accountKey)
            if zlibService.authenticated && (UserDefaults.standard.object(forKey: "wenku.autoSyncShelf") as? Bool ?? true) {
                if let last = zlibAccount.syncedAt, Date().timeIntervalSince(last) < 900 { return }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                while zlibAccount.syncing {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return }
                }
                await zlibAccount.sync(using: zlibService)
            }
        }
        .background {
            if mode == "haiku" {
                ZStack {
                    WenkuTransportHost(service: service)
                    WenkuTransportHost(service: service.backgroundService)
                    ZLibTransportHost(service: zlibService)
                    ZLibTransportHost(service: zlibService.backgroundService)
                }
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .task(id: mode) {
            guard mode == "haiku" else { return }
            let coldStart = Date()
            await service.refreshSession()
            await zlibService.refreshSession()
            await FanhuaCache.shared.trim()
            sessionReady = true
            #if DEBUG
            print("FANHUA_COLD_START seconds=\(String(format: "%.4f", Date().timeIntervalSince(coldStart)))")
            if ProcessInfo.processInfo.arguments.contains("--perf-check") { await service.performanceProbe() }
            if ProcessInfo.processInfo.arguments.contains("--verify-wenku") || ProcessInfo.processInfo.arguments.contains("--verify-extra") { await service.validateFacets() }
            if ProcessInfo.processInfo.arguments.contains("--verify-zlib") {
                await ZLibVerificationSuite.run(
                    zlibService: zlibService,
                    zlibAccount: zlibAccount,
                    history: history
                )
            }
            #endif
        }
    }
}

private struct WenkuTransportHost: UIViewRepresentable {
    let service: WenkuService
    func makeUIView(context: Context) -> WKWebView { service.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct ZLibTransportHost: UIViewRepresentable {
    let service: ZLibService
    func makeUIView(context: Context) -> WKWebView { service.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ArchiveHeading: View {
    let title: String
    let subtitle: String
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var caption: String? {
        guard subtitle.contains("·") else { return nil }
        let last = subtitle.components(separatedBy: "·").last?.trimmingCharacters(in: .whitespaces) ?? ""
        return last.range(of: "[a-zA-Z]", options: .regularExpression) == nil ? last : nil
    }
    var body: some View {
        PageHeader(title: title, caption: caption, titleSize: ShelfMetrics.of(sizeClass).titleSize)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WenkuDiscoverView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(WenkuService.self) private var service
    @Environment(ZLibService.self) private var zlibService
    @Environment(TomatoStore.self) private var tomatoStore
    @AppStorage("fanhua.activeSource") private var activeSourceRaw = BookSource.wenku8.rawValue

    @State private var sort = "lastupdate"
    @State private var query = ""
    @State private var submitted = ""
    @State private var field = "articlename"
    @State private var pageNumber = 1
    @State private var ended = false
    @State private var books: [WenkuBook] = []
    @State private var loading = false
    @State private var generation = UUID()
    @State private var failure: String?
    @State private var loginSheet = false
    @State private var challengeSheet = false
    @State private var zlibLoginSheet = false
    @State private var zlibChallengeSheet = false
    @State private var zlibReloadTrigger = UUID()

    private let ranks = [
        ("lastupdate", "最近更新"),
        ("allvisit", "人气榜"),
        ("allvote", "推荐榜"),
        ("postdate", "新书入库"),
        ("done", "完结作品")
    ]

    private let searchFields: [LuoyeSegmentItem<String>] = [
        .init(value: "articlename", title: "按书名"),
        .init(value: "author", title: "按作者"),
        .init(value: "tag", title: "按标签")
    ]

    private var activeSource: BookSource {
        BookSource(rawValue: activeSourceRaw) ?? .wenku8
    }

    private var key: String { "\(sort)|\(submitted)|\(field)|\(service.authenticated)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        LuoyeModeHeading(caption: "发现好书")
                        Spacer()
                        if activeSource == .wenku8 {
                            NavigationLink { WenkuCategoryView() } label: { GlassCircleLabel(systemImage: "square.grid.2x2") }
                                .buttonStyle(.plain).accessibilityLabel("文库分类")
                        } else if activeSource == .zlib {
                            NavigationLink { ZLibCategoryView() } label: { GlassCircleLabel(systemImage: "square.grid.2x2") }
                                .buttonStyle(.plain).accessibilityLabel("分类与书单")
                        } else {
                            NavigationLink { TomatoSettingsView() } label: { GlassCircleLabel(systemImage: "slider.horizontal.3") }.buttonStyle(.plain).accessibilityLabel("番茄小说设置")
                        }
                    }
                    LuoyeSegmentBar(
                        items: BookSource.allCases.map { LuoyeSegmentItem(value: $0.rawValue, title: $0.displayName) },
                        selection: $activeSourceRaw
                    )

                    if activeSource == .wenku8 {
                        wenkuContent
                    } else if activeSource == .tomato {
                        TomatoDiscoverContent()
                    } else {
                        ZLibDiscoverContent(
                            loginSheet: $zlibLoginSheet,
                            challengeSheet: $zlibChallengeSheet
                        )
                        .id(zlibReloadTrigger)
                    }
                }
                .luoyeContentMargins()
            }
            .scrollDismissesKeyboard(.immediately)
            .luoyeRootSurface()
            .navigationDestination(for: WenkuBook.self) { WenkuDetailView(book: $0) }
            .navigationDestination(for: TomatoBook.self) { TomatoDetailView(book: $0) }
            .navigationDestination(for: ZLibBook.self) { ZLibDetailView(book: $0) }
            .navigationDestination(for: ZLibBooklist.self) { ZLibBooklistDetailView(booklist: $0) }
            .navigationDestination(for: ZLibFacet.self) { ZLibCollectionView(facet: $0) }
            .task(id: key) {
                if activeSource == .wenku8 {
                    await load(reset: true)
                }
            }
            .onChange(of: activeSourceRaw) { _, newValue in
                if newValue == BookSource.wenku8.rawValue, books.isEmpty {
                    Task { await load(reset: true) }
                }
            }
            .refreshable {
                if activeSource == .wenku8 {
                    await Task { await load(reset: true, refresh: true) }.value
                } else if activeSource == .zlib {
                    zlibService.clearResponseMemory()
                    zlibReloadTrigger = UUID()
                } else {
                    tomatoStore.homeRefresh += 1
                }
            }
            .sheet(isPresented: $loginSheet) {
                if service.authenticated { NavigationStack { WenkuAccountSettingsView() } }
                else { WenkuLoginView() }
            }
            .sheet(isPresented: $challengeSheet, onDismiss: { Task { await service.refreshSession(); await load(reset: true) } }) {
                WenkuVerificationView()
            }
            .sheet(isPresented: $zlibLoginSheet) {
                if zlibService.authenticated { NavigationStack { ZLibAccountSettingsView() } }
                else { ZLibLoginView() }
            }
            .sheet(isPresented: $zlibChallengeSheet, onDismiss: {
                Task {
                    await zlibService.refreshSession()
                    zlibReloadTrigger = UUID()
                }
            }) {
                ZLibVerificationView()
            }
        }
    }

    @ViewBuilder
    private var wenkuContent: some View {
        VStack(spacing: 12) {
            LuoyeSearchBar(
                placeholder: "搜索文库书名、作者或标签…",
                text: $query,
                onSubmit: { submitted = query.trimmingCharacters(in: .whitespacesAndNewlines) },
                onClear: { submitted = "" }
            )

            if !query.isEmpty {
                HStack(spacing: 10) {
                    LuoyeSegmentBar(items: searchFields, selection: $field)
                    Button {
                        submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    } label: {
                        Text("搜索")
                            .font(.serif(13, medium: true))
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if submitted.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ranks, id: \.0) { item in
                        LuoyeChip(title: item.1, active: sort == item.0) {
                            sort = item.0
                        }
                    }
                }
            }
        } else {
            HStack {
                Text("搜索「\(submitted)」")
                    .font(.serif(14, medium: true))
                    .foregroundStyle(Color.ink)
                Spacer()
                Button("返回榜单") {
                    query = ""
                    submitted = ""
                }
                .font(.serif(12))
                .foregroundStyle(.tint)
            }
        }

        if let failure {
            WenkuStatusView(
                message: failure,
                loading: loading,
                login: !service.authenticated,
                onLogin: { loginSheet = true },
                onRetry: { Task { await load(reset: true) } },
                onChallenge: { challengeSheet = true }
            )
        }

        if loading && books.isEmpty {
            ProgressView("正在翻阅文库…")
                .font(.serif(13))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 55)
        }

        WenkuBookGrid(books: books)

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
        } else if books.isEmpty && !loading && failure == nil {
            LuoyeEmptyState(
                icon: "text.book.closed",
                title: "暂未找到相关书籍",
                message: "试试其他关键词，或切换上方榜单。"
            )
        }
    }

    private func load(reset: Bool, refresh: Bool = false) async {
        guard reset || !loading else { return }
        let token = UUID()
        generation = token
        loading = true
        defer { if generation == token { loading = false } }
        failure = nil
        do {
            let requestedPage = reset ? 1 : pageNumber
            let path: String
            if !submitted.isEmpty { path = WenkuService.searchPath(submitted, field: field, page: requestedPage) }
            else if sort == "done" { path = "/modules/article/articlelist.php?fullflag=1&page=\(requestedPage)" }
            else { path = "/modules/article/toplist.php?sort=\(sort)&page=\(requestedPage)" }
            let result = try await service.page(path, refresh: refresh)
            try Task.checkCancellation()
            guard generation == token else { return }
            if refresh && result.books.isEmpty && !books.isEmpty { throw WenkuFailure.invalid }
            if reset {
                books = result.books
                ended = result.books.isEmpty
                pageNumber = 2
                return
            }
            let ids = Set(books.map(\.id))
            let fresh = result.books.filter { !ids.contains($0.id) }
            ended = fresh.isEmpty
            books += fresh
            pageNumber = requestedPage + 1
        } catch is CancellationError {} catch { if generation == token { failure = error.localizedDescription } }
    }
}

struct WenkuBookGrid: View {
    let books: [WenkuBook]
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        let metrics = ShelfMetrics.of(sizeClass)
        LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: metrics.rowGap) {
            ForEach(books) { book in
                NavigationLink(value: book) {
                    ShelfTile(title: book.title, author: book.author.isEmpty ? "轻小说文库" : book.author, large: sizeClass == .regular) {
                        LuoyeRemoteCover(title: book.title, coverURLString: book.cover).aspectRatio(0.69, contentMode: .fit)
                    }
                }.buttonStyle(PressStyle())
            }
        }
    }
}

struct WenkuStatusView: View {
    let message: String
    let loading: Bool
    let login: Bool
    var onLogin: () -> Void
    var onRetry: () -> Void
    var onChallenge: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.11))
                    .frame(width: 52, height: 52)
                Image(systemName: login ? "person.crop.circle.badge.exclamationmark" : "wifi.exclamationmark")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            }
            Text(message)
                .font(.serif(14))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if login {
                    Button(action: onLogin) {
                        Text("登录文库")
                            .font(.serif(13, medium: true))
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onRetry) {
                    Text("重试")
                        .font(.serif(13, medium: true))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Color.ink.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
            Button("完成网站安全验证", action: onChallenge)
                .font(.serif(12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.ink.opacity(0.06), lineWidth: 0.5)
        }
    }
}

struct WenkuLoginView: View {
    @Environment(WenkuService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var verifying = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ArchiveHeading(title: "与文库相连", subtitle: "WENKU8 / ACCOUNT")
                    Text("登录你的轻小说文库账号，同步云端收藏书架，继续下一段故事。")
                        .font(.serif(14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)

                    LuoyePanel {
                        TextField("用户名", text: $username)
                            .font(.serif(15))
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(18)
                        LuoyePanelDivider(leadingInset: 18)
                        SecureField("密码", text: $password)
                            .font(.serif(15))
                            .textContentType(.password)
                            .padding(18)
                            .onSubmit { signIn() }
                    }

                    if let error {
                        Text(error)
                            .font(.serif(13))
                            .foregroundStyle(.red)
                    }

                    Button(action: signIn) {
                        HStack(spacing: 8) {
                            Spacer()
                            if service.checking { ProgressView().tint(Color.ink) }
                            Text(service.checking ? "正在登录…" : "登录轻小说文库")
                                .font(.serif(15, medium: true))
                            Spacer()
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.vertical, 13)
                        .background(
                            (username.isEmpty || password.isEmpty || service.checking)
                                ? Color.accentColor.opacity(0.45)
                                : Color.accentColor,
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(username.isEmpty || password.isEmpty || service.checking)

                    Text("密码仅用于向轻小说文库提交登录，落叶不会保存或记录密码。网站登录会话保存在本机，退出账号时清除。")
                        .font(.serif(12))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)

                    Button("网站要求安全验证？") { verifying = true }
                        .font(.serif(13))
                        .foregroundStyle(.tint)
                }
                .padding(24)
                .padding(.top, 16)
            }
            .background(Color.paper)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .navigationTitle("文库账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(service.checking) } }
            .onAppear { username = service.username; if service.authenticated { dismiss() } }
            .onChange(of: service.authenticated) { _, signedIn in if signedIn { password = ""; dismiss() } }
            .sheet(isPresented: $verifying, onDismiss: { Task { await service.refreshSession(); if service.authenticated { dismiss() } } }) { WenkuVerificationView() }
        }
        .interactiveDismissDisabled(service.checking)
    }

    private func signIn() {
        guard !service.checking else { return }
        error = nil
        Task {
            do { try await service.login(username: username.trimmingCharacters(in: .whitespaces), password: password); password = ""; dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct WenkuVerificationView: View {
    @State private var loadError: String?
    @Environment(WenkuService.self) private var service
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let loadError { Text(loadError).font(.footnote).foregroundStyle(.secondary).padding() }
                VerificationWebView(service: service, error: $loadError)
            }
            .navigationTitle("文库安全验证").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("验证完成") { Task { await service.refreshSession(); dismiss() } } } }
        }
    }
}

private struct VerificationWebView: UIViewRepresentable {
    let service: WenkuService
    @Binding var error: String?
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            guard WenkuService.allowed(url) || (action.targetFrame?.isMainFrame == false && url.host == "challenges.cloudflare.com") else { return .cancel }
            if url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                components.scheme = "https"
                var request = action.request; request.url = components.url
                webView.load(request)
                return .cancel
            }
            return url.scheme == "https" ? .allow : .cancel
        }
    }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = service.webView.configuration.websiteDataStore
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = context.coordinator
        Task { @MainActor in
            do {
                try await WenkuContentPolicy.install(on: browser, background: false)
                browser.load(URLRequest(url: URL(string: "https://www.wenku8.net/login.php")!))
            } catch { self.error = "广告过滤未能初始化，请关闭后重试。" }
        }
        return browser
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
