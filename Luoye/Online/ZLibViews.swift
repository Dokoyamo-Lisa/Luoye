import SwiftUI
import WebKit

struct ZLibDiscoverContent: View {
    @Environment(ZLibService.self) private var service
    @Binding var loginSheet: Bool
    @Binding var challengeSheet: Bool

    @State private var feed = "popular"
    @State private var query = ""
    @State private var submitted = ""
    @State private var filter = ZLibSearchFilter()
    @State private var showFilterPanel = false
    @State private var pageNumber = 1
    @State private var ended = false
    @State private var books: [ZLibBook] = []
    @State private var booklists: [ZLibBooklist] = []
    @State private var loading = false
    @State private var generation = UUID()
    @State private var failure: String?

    private let feeds = [
        ("popular", "热门推荐"),
        ("home", "馆藏精选"),
        ("recommended", "猜你喜欢"),
        ("booklists", "公共书单")
    ]

    private let languages = [
        ("", "全部语言"),
        ("chinese", "中文"),
        ("traditional chinese", "繁体中文"),
        ("english", "英语"),
        ("japanese", "日语"),
        ("french", "法语"),
        ("german", "德语"),
        ("russian", "俄语"),
        ("spanish", "西班牙语"),
        ("korean", "韩语")
    ]

    private let extensions = [
        ("", "全部格式"),
        ("EPUB", "EPUB"),
        ("TXT", "TXT"),
        ("MOBI", "MOBI"),
        ("AZW3", "AZW3"),
        ("FB2", "FB2"),
        ("PDF", "PDF")
    ]

    private let yearPresets: [(label: String, from: Int?, to: Int?)] = [
        ("不限年份", nil, nil),
        ("2024 至今", 2024, nil),
        ("2020 至今", 2020, nil),
        ("2010–2019", 2010, 2019),
        ("2000–2009", 2000, 2009),
        ("2000 以前", nil, 1999)
    ]

    private var requestKey: String {
        "\(feed)|\(submitted)|\(filter.exact)|\(filter.language)|\(filter.extensionName)|\(filter.yearFrom ?? 0)|\(filter.yearTo ?? 0)|\(service.authenticated)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            searchAndFilterBar

            if submitted.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(feeds, id: \.0) { item in
                            LuoyeChip(title: item.1, active: feed == item.0) {
                                feed = item.0
                            }
                        }
                    }
                }
            } else {
                HStack {
                    Text("搜索「\(submitted)」")
                        .font(.serif(14, medium: true))
                        .foregroundStyle(Color.ink)
                    if filter.isActive {
                        Text("· \(filter.summaryLabel)")
                            .font(.serif(12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("返回推荐") {
                        query = ""
                        submitted = ""
                    }
                    .font(.serif(12))
                    .foregroundStyle(.tint)
                }
            }

            if let failure {
                ZLibStatusView(
                    message: failure,
                    loading: loading,
                    login: !service.authenticated,
                    onLogin: { loginSheet = true },
                    onRetry: { Task { await load(reset: true, refresh: true) } },
                    onChallenge: { challengeSheet = true }
                )
            }

            if loading && books.isEmpty && booklists.isEmpty {
                ProgressView("正在翻阅 Z-Library 馆藏…")
                    .font(.serif(13))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 55)
            }

            if submitted.isEmpty && feed == "booklists" {
                ZLibBooklistStack(booklists: booklists)
                if !booklists.isEmpty && !ended {
                    Button {
                        Task { await load(reset: false) }
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
                } else if booklists.isEmpty && !loading && failure == nil {
                    LuoyeEmptyState(
                        icon: "list.bullet.rectangle",
                        title: "暂未找到书单",
                        message: "稍后下拉刷新或切换其他推荐栏目。"
                    )
                }
            } else {
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
                } else if books.isEmpty && !loading && failure == nil {
                    LuoyeEmptyState(
                        icon: "text.book.closed",
                        title: "暂未找到匹配书籍",
                        message: filter.isActive ? "试试放宽语言、年份或格式筛选条件。" : "试试其他关键词、作者或 ISBN。"
                    )
                }
            }
        }
        .task(id: requestKey) {
            await load(reset: true)
        }
    }

    private var searchAndFilterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            LuoyeSearchBar(
                placeholder: "搜索书名、作者、ISBN 或出版社…",
                text: $query,
                onSubmit: { triggerSearch() },
                onClear: { submitted = "" }
            ) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFilterPanel.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 12))
                        Text(filter.isActive ? filter.summaryLabel : "筛选")
                            .font(.serif(12, medium: filter.isActive))
                            .lineLimit(1)
                    }
                    .foregroundStyle(filter.isActive ? Color.ink : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        filter.isActive ? Color.accentColor.opacity(0.20) : Color.ink.opacity(0.05),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }

            if !query.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines) != submitted {
                HStack {
                    Toggle("精确匹配词组", isOn: $filter.exact)
                        .font(.serif(13))
                        .tint(.accentColor)
                    Spacer()
                    Button {
                        triggerSearch()
                    } label: {
                        Text("搜索")
                            .font(.serif(13, medium: true))
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if showFilterPanel {
                filterPanel
            }
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("筛选条件")
                    .font(.serif(14, medium: true))
                    .foregroundStyle(Color.ink)
                Spacer()
                if filter.isActive {
                    Button("重置筛选") {
                        filter = ZLibSearchFilter()
                    }
                    .font(.serif(12))
                    .foregroundStyle(.tint)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("语言")
                    .font(.serif(11))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(languages, id: \.0) { code, label in
                            LuoyeChip(title: label, active: filter.language == code) {
                                filter.language = code
                                ensureSearchSubmittedIfNeeded()
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("文件格式")
                    .font(.serif(11))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(extensions, id: \.0) { ext, label in
                            LuoyeChip(title: label, active: filter.extensionName == ext) {
                                filter.extensionName = ext
                                ensureSearchSubmittedIfNeeded()
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("出版年份")
                    .font(.serif(11))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(yearPresets, id: \.label) { preset in
                            let selected = filter.yearFrom == preset.from && filter.yearTo == preset.to
                            LuoyeChip(title: preset.label, active: selected) {
                                filter.yearFrom = preset.from
                                filter.yearTo = preset.to
                                ensureSearchSubmittedIfNeeded()
                            }
                        }
                    }
                }
            }

            Toggle("精确匹配搜索词", isOn: $filter.exact)
                .font(.serif(13))
                .tint(.accentColor)
        }
        .padding(16)
        .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.ink.opacity(0.06), lineWidth: 0.5)
        }
    }

    private func triggerSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            submitted = trimmed
        }
    }

    private func ensureSearchSubmittedIfNeeded() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            submitted = trimmed
        }
    }

    func reload(refresh: Bool = true) async {
        await load(reset: true, refresh: refresh)
    }

    private func load(reset: Bool, refresh: Bool = false) async {
        guard reset || !loading else { return }
        let token = UUID()
        generation = token
        loading = true
        defer { if generation == token { loading = false } }

        if reset {
            pageNumber = 1
            books = []
            booklists = []
            ended = false
        }
        failure = nil

        do {
            if !submitted.isEmpty {
                let path = ZLibService.searchPath(query: submitted, filter: filter, page: pageNumber)
                let result = try await service.page(path, refresh: refresh)
                try Task.checkCancellation()
                guard generation == token else { return }
                let existing = Set(books.map(\.id))
                let fresh = result.books.filter { !existing.contains($0.id) }
                books += fresh
                ended = fresh.isEmpty || !result.hasNextPage
                pageNumber += 1
            } else if feed == "booklists" {
                let path = ZLibService.booklistsPath(order: "popular", page: pageNumber)
                let result = try await service.page(path, refresh: refresh)
                try Task.checkCancellation()
                guard generation == token else { return }
                let existing = Set(booklists.map(\.id))
                let fresh = result.booklists.filter { !existing.contains($0.id) }
                booklists += fresh
                ended = fresh.isEmpty || !result.hasNextPage
                pageNumber += 1
            } else {
                let path: String
                switch feed {
                case "popular":
                    path = "/popular"
                case "recommended":
                    path = service.authenticated ? "/users/zrecommended" : "/"
                default:
                    path = "/"
                }
                let result = try await service.page(path, refresh: refresh)
                try Task.checkCancellation()
                guard generation == token else { return }
                var list = result.books
                if !filter.language.isEmpty {
                    list = list.filter { $0.language.isEmpty || $0.language.localizedCaseInsensitiveContains(filter.language) }
                }
                if !filter.extensionName.isEmpty {
                    list = list.filter { $0.extensionName.isEmpty || $0.extensionName.localizedCaseInsensitiveContains(filter.extensionName) }
                }
                books = list
                ended = true
            }
        } catch is CancellationError {
        } catch {
            if generation == token {
                failure = error.localizedDescription
            }
        }
    }
}

struct ZLibBookGrid: View {
    let books: [ZLibBook]
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        let metrics = ShelfMetrics.of(sizeClass)
        LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: metrics.rowGap) {
            ForEach(books) { book in
                NavigationLink(value: book) {
                    ShelfTile(title: book.title, author: book.author.isEmpty ? "Z-Library" : book.author, large: sizeClass == .regular) {
                        ZLibCover(book: book).aspectRatio(0.69, contentMode: .fit)
                    }
                }.buttonStyle(PressStyle())
            }
        }
    }
}

struct ZLibCover: View {
    let book: ZLibBook

    var body: some View {
        LuoyeRemoteCover(
            title: book.title,
            coverURLString: book.cover,
            badge: book.extensionName
        )
    }
}

struct ZLibStatusView: View {
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
                        Text("登录 Z-Library")
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

struct ZLibLoginView: View {
    @Environment(ZLibService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var verifying = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ArchiveHeading(title: "连接 Z-Library", subtitle: "Z-LIBRARY / ACCOUNT")
                    Text("登录你的 Z-Library 账号，同步个人书库、书单与下载记录，解锁更多电子书格式。")
                        .font(.serif(14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)

                    LuoyePanel {
                        TextField("邮箱", text: $email)
                            .font(.serif(15))
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
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
                            Text(service.checking ? "正在登录…" : "登录 Z-Library")
                                .font(.serif(15, medium: true))
                            Spacer()
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.vertical, 13)
                        .background(
                            (email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || service.checking)
                                ? Color.accentColor.opacity(0.45)
                                : Color.accentColor,
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || service.checking)

                    Text("密码仅用于向 Z-Library 提交登录，落叶不会保存或记录密码。登录会话独立保存在本机，退出账号时清除。")
                        .font(.serif(12))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)

                    Button("遇到网站安全验证？") { verifying = true }
                        .font(.serif(13))
                        .foregroundStyle(.tint)
                }
                .padding(24)
                .padding(.top, 16)
            }
            .background(Color.paper)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .navigationTitle("Z-Library 账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(service.checking)
                }
            }
            .onAppear {
                email = service.email
                if service.authenticated { dismiss() }
            }
            .onChange(of: service.authenticated) { _, signedIn in
                if signedIn {
                    password = ""
                    dismiss()
                }
            }
            .sheet(isPresented: $verifying, onDismiss: {
                Task {
                    await service.refreshSession()
                    if service.authenticated { dismiss() }
                }
            }) {
                ZLibVerificationView()
            }
        }
        .interactiveDismissDisabled(service.checking)
    }

    private func signIn() {
        guard !service.checking else { return }
        error = nil
        Task {
            do {
                try await service.login(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
                password = ""
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ZLibVerificationView: View {
    @State private var loadError: String?
    @Environment(ZLibService.self) private var service
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                }
                ZLibVerificationWebView(service: service, error: $loadError)
            }
            .navigationTitle("Z-Library 安全验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("验证完成") {
                        Task {
                            await service.refreshSession()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

private struct ZLibVerificationWebView: UIViewRepresentable {
    let service: ZLibService
    @Binding var error: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let host = url.host?.lowercased() ?? ""
            let isVerificationSubframe = action.targetFrame?.isMainFrame == false
                && (host == "challenges.cloudflare.com" || host.hasSuffix(".diamwall.com") || ZLibService.allowed(host: host))
            guard ZLibService.allowed(url) || isVerificationSubframe else { return .cancel }
            if url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                components.scheme = "https"
                var request = action.request
                request.url = components.url
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
        browser.customUserAgent = ZLibService.userAgent
        browser.navigationDelegate = context.coordinator
        Task { @MainActor in
            do {
                try await ZLibContentPolicy.install(on: browser, background: false)
                browser.load(URLRequest(url: service.baseURL))
            } catch {
                self.error = "安全验证页面初始化失败，请关闭后重试。"
            }
        }
        return browser
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
