import SwiftUI
import SwiftData

struct TomatoBookRow: View {
    let book: TomatoBook
    var body: some View {
        HStack(spacing: 14) {
            LuoyeRemoteCover(title: book.title, coverURLString: book.cover).frame(width: 50, height: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.serif(16, medium: true)).foregroundStyle(Color.ink).lineLimit(2)
                Text(book.author.isEmpty ? "番茄小说" : book.author).font(.serif(12)).foregroundStyle(.secondary)
                if book.chapterCount > 0 { Text("\(book.chapterCount) 章").font(.serif(11)).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TomatoShelfContent: View {
    @Environment(TomatoStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("番茄收藏保存在本机，下载的书籍会加入本地书斋。").font(.serif(12)).foregroundStyle(.secondary)
            if store.favorites.isEmpty {
                LuoyeEmptyState(icon: "bookmark", title: "收藏一部想读的小说", message: "在番茄书籍详情中点亮收藏，就能在这里找到它。")
            }
            LuoyeRowGrid {
                ForEach(store.favorites) { book in
                    NavigationLink(value: book) { LuoyePanel { TomatoBookRow(book: book) } }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct TomatoDiscoverContent: View {
    @Environment(TomatoStore.self) private var store
    @State private var query = ""
    @State private var results: [TomatoBook] = []
    @State private var destination: TomatoBook?
    @State private var failure: String?
    @State private var searching = false
    @State private var homeSection = TomatoHomeSection.home
    @State private var recommendations: [TomatoBook] = []
    @State private var recommending = false
    @State private var homeFailure: String?
    @State private var displayedSection: TomatoHomeSection?
    @State private var homeRequest = UUID()
    @State private var lastHomeRefresh: Int?
    @State private var showWebsite = false
    @State private var searchTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LuoyeSearchBar(placeholder: "书号、书籍链接或书名", text: $query, onSubmit: submit, onClear: {
                searchTask?.cancel(); results = []; failure = nil; searching = false
            }) {
                Button(action: submit) { Image(systemName: "arrow.right") }.disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 16) {
                Button { showWebsite = true } label: { Label("官网登录", systemImage: "person.crop.circle") }
                NavigationLink { TomatoJobsView() } label: { Label("下载任务", systemImage: "arrow.down.circle") }
                NavigationLink { TomatoLibraryView() } label: { Label("下载书库", systemImage: "books.vertical") }
                Spacer(minLength: 0)
            }.font(.serif(13)).buttonStyle(.plain)
            if searching { ProgressView("正在搜索…").font(.serif(13)) }
            if let failure { Text(failure).font(.serif(13)).foregroundStyle(.secondary) }
            if !results.isEmpty { LuoyeRowGrid {
                ForEach(results) { book in
                    NavigationLink(value: book) { LuoyePanel { TomatoBookRow(book: book) } }.buttonStyle(.plain)
                }
            } }
            if results.isEmpty && !searching {
                LuoyeSegmentBar(items: TomatoHomeSection.allCases.map { .init(value: $0, title: $0.title) }, selection: $homeSection)
                HStack {
                    Text(homeSection.title).font(.serif(18, medium: true))
                    Spacer()
                    if recommending { ProgressView() }
                    else { Button { store.homeRefresh += 1 } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新官网推荐") }
                }
                if let homeFailure { Text(homeFailure).font(.serif(12)).foregroundStyle(.secondary) }
                LuoyeRowGrid {
                    ForEach(recommendations) { book in
                        NavigationLink(value: book) { LuoyePanel { TomatoBookRow(book: book) } }.buttonStyle(.plain)
                    }
                }
                LuoyeSettingsSection(title: "从一本小说开始", footnote: "无需配置服务即可查看官网推荐、书目和目录，并提纯当前可访问的网页正文。书名搜索和整书下载可连接兼容的下载器服务。") {
                    Text("粘贴番茄小说书号或完整书籍链接，查看简介、目录并收藏。").font(.serif(14)).lineSpacing(4)
                    NavigationLink { TomatoSettingsView() } label: { Label(store.endpoint == nil ? "配置下载器" : "管理下载器", systemImage: "slider.horizontal.3") }
                }
                if !store.favorites.isEmpty { TomatoShelfContent() }
            }
        }
        .task(id: "\(homeSection.rawValue)|\(store.homeRefresh)") {
            let refresh = lastHomeRefresh != nil && lastHomeRefresh != store.homeRefresh
            lastHomeRefresh = store.homeRefresh
            await loadHome(refresh: refresh)
        }
        .sheet(isPresented: $showWebsite, onDismiss: { store.homeRefresh += 1 }) { TomatoWebsiteView() }
        .navigationDestination(item: $destination) { TomatoDetailView(book: $0) }
        .onDisappear { searchTask?.cancel(); searching = false }
    }
    private func loadHome(refresh: Bool = false) async {
        let section = homeSection
        let request = UUID(); homeRequest = request
        defer { if homeRequest == request { recommending = false } }
        if displayedSection != section { recommendations = []; displayedSection = section }
        recommending = true; homeFailure = nil
        if recommendations.isEmpty, let cached = await store.catalog.cachedRecommendations(section), homeRequest == request { recommendations = cached }
        do {
            await store.website.sync(to: store.catalog)
            let books = try await store.catalog.recommendations(section, refresh: refresh)
            try Task.checkCancellation()
            guard homeRequest == request, homeSection == section else { return }
            recommendations = books
        } catch {
            guard !Task.isCancelled, homeRequest == request else { return }
            let message: String
            switch (error as? URLError)?.code {
            case .notConnectedToInternet, .networkConnectionLost: message = "网络未连接，联网后可再次刷新。"
            case .timedOut: message = "官网响应超时，请稍后刷新。"
            default: message = error.localizedDescription
            }
            homeFailure = (recommendations.isEmpty ? "" : "正在显示缓存推荐。") + message
        }
    }
    private func submit() {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        searchTask?.cancel(); searching = false; failure = nil
        if let id = TomatoBookID.parse(input) { destination = TomatoBook(id: id, title: "番茄小说 · \(id)"); return }
        guard !input.contains("://"), !input.allSatisfy(\.isNumber) else { failure = "请输入有效的番茄书号或完整书籍链接。"; return }
        guard let base = store.endpoint else { failure = "书名搜索需要下载器服务。也可以直接粘贴书号或书籍链接。"; return }
        searching = true
        searchTask = Task {
            defer { if !Task.isCancelled { searching = false } }
            do {
                let books = try await store.client.search(input, base: base)
                try Task.checkCancellation(); results = books
                if books.isEmpty { failure = "没有找到相关小说，试试书号或其他关键词。" }
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

struct TomatoDetailView: View {
    let book: TomatoBook
    @Environment(TomatoStore.self) private var store
    @Environment(BrowsingHistoryStore.self) private var history
    @Query private var localBooks: [Book]
    @State private var detail: TomatoDetail?
    @State private var failure: String?
    @State private var notice: String?
    @State private var loading = false
    @State private var submitting = false
    @State private var chapterLimit = 100
    @State private var reading: Book?
    @State private var showJobs = false
    @State private var onlineChapter: TomatoChapter?
    @State private var showWebsite = false
    @State private var expandedSummary = false
    private var current: TomatoBook { detail?.book ?? book }
    private var localBook: Book? {
        let importedID = store.importer.localBookID(for: book.id)
        return localBooks.first { ($0.sourceKey == "tomato:\(book.id)" || $0.id == importedID) && BookImportCommit.hasLocalFile($0) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LuoyePanel { TomatoBookRow(book: current) }
                HStack {
                    Button { store.toggleFavorite(current) } label: { Label(store.isFavorite(book.id) ? "已收藏" : "收藏", systemImage: store.isFavorite(book.id) ? "bookmark.fill" : "bookmark") }
                    Spacer()
                    Text("书号 \(book.id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }.font(.serif(14))
                if !current.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(current.summary).font(.serif(15)).lineSpacing(6).lineLimit(expandedSummary ? nil : 5)
                        Button(expandedSummary ? "收起简介" : "展开简介") { expandedSummary.toggle() }.font(.serif(12))
                    }
                }
                if let last = store.progress.lastChapter(bookID: book.id), let chapter = detail?.chapters.first(where: { $0.id == last }) {
                    LuoyeSettingsAction(title: "继续在线阅读", icon: "book", prominent: true) { onlineChapter = chapter }
                }
                if let localBook {
                    LuoyeSettingsAction(title: "继续阅读", icon: "book", prominent: true) { reading = localBook }
                }
                if store.endpoint != nil {
                    LuoyeSettingsAction(title: submitting ? "正在创建任务…" : "下载全书", icon: "arrow.down.circle", prominent: localBook == nil) { download() }.disabled(submitting)
                    NavigationLink { TomatoLibraryView(book: current) } label: { Label("从下载书库导入本书", systemImage: "square.and.arrow.down") }.font(.serif(13))
                } else {
                    LuoyeSettingsSection(title: "在落叶里阅读", footnote: "点击下方章节可提纯当前可访问的官网正文，直接在落叶阅读。整书下载可另行连接下载器。") {
                        NavigationLink { TomatoSettingsView() } label: { Label("连接下载器服务", systemImage: "network") }
                    }
                }
                Button { showWebsite = true } label: { Label("官网登录 / 验证", systemImage: "person.crop.circle") }.font(.serif(13))
                if let notice { Text(notice).font(.serif(13)).foregroundStyle(.secondary) }
                HStack {
                    Text("目录 · \(detail?.chapters.count ?? current.chapterCount) 章").font(.serif(18, medium: true))
                    Spacer()
                    if loading { ProgressView() }
                    else { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新番茄目录") }
                }
                if let failure { Text(failure).font(.serif(13)).foregroundStyle(.secondary) }
                if let detail {
                    Text("点击章节，提纯官网可访问正文并进入 Haiku 阅读器。").font(.serif(12)).foregroundStyle(.secondary)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(detail.chapters.prefix(chapterLimit).enumerated()), id: \.element.id) { index, chapter in
                            Button { onlineChapter = chapter } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 32, alignment: .leading)
                                Text(chapter.title).font(.serif(14))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13)
                            }.buttonStyle(.plain)
                            Divider().opacity(0.4)
                        }
                        if detail.chapters.count > chapterLimit { Button("显示更多章节") { chapterLimit += 100 }.font(.serif(13)).padding(.vertical, 16) }
                    }
                }
            }.luoyeContentMargins(top: 20, maximumWidth: 820)
        }.background(Color.paper).navigationTitle("番茄小说").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWebsite) { TomatoWebsiteView() }
        .fullScreenCover(item: $onlineChapter) { chapter in
            TomatoOnlineReader(book: current, chapters: detail?.chapters ?? [chapter], initialChapter: chapter)
        }
        .task(id: book.id) { await load() }
        .refreshable { await load() }
        .navigationDestination(isPresented: $showJobs) { TomatoJobsView() }
        .fullScreenCover(item: $reading) { ReaderView(book: $0) }
    }
    private func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        failure = nil
        if detail == nil { detail = await store.catalog.cached(book.id) }
        do {
            await store.website.sync(to: store.catalog)
            let loaded = try await store.catalog.detail(book.id)
            try Task.checkCancellation(); detail = loaded; history.record(loaded.book)
        } catch {
            guard !Task.isCancelled else { return }
            failure = (detail == nil ? "" : "正在显示已缓存目录。") + error.localizedDescription
            if detail == nil, let base = store.endpoint, let preview = try? await store.client.preview(book.id, base: base), !Task.isCancelled {
                detail = TomatoDetail(book: preview, chapters: []); history.record(preview)
            } else if let detail { history.record(detail.book) }
        }
    }
    private func download() {
        guard !submitting, let base = store.endpoint else { return }; submitting = true
        Task {
            defer { submitting = false }
            do { try await store.client.createJob(bookID: book.id, base: base); notice = "任务已创建，请在下载任务中选择格式。"; showJobs = true }
            catch { notice = error.localizedDescription }
        }
    }
}

struct TomatoSettingsView: View {
    @Environment(TomatoStore.self) private var store
    @State private var address = ""
    @State private var password = ""
    @State private var failure: String?
    @State private var showWebsite = false
    var body: some View {
        LuoyeSettingsPage(title: "番茄小说设置") {
            LuoyeSettingsSection(title: "官网账号", footnote: "官网会话与 Wenku8、Z-Library、漫画空间分别保存。落叶只读取当前可访问的页面正文，正文使用原生阅读器。") {
                Button { showWebsite = true } label: { Label("在番茄官网登录 / 验证", systemImage: "person.crop.circle") }
                Text(store.website.status).font(.serif(12)).foregroundStyle(.secondary)
                Button("清除官网会话", role: .destructive) { Task { await store.website.logout(catalog: store.catalog) } }.font(.serif(13))
            }
            LuoyeSettingsSection(title: "下载器服务", footnote: "填写你自己运行的 Tomato-Novel-Downloader WebUI 地址。密码只用于本次登录，不保存；正文由服务提供，下载后在落叶内阅读。") {
                TextField("https://example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().luoyeSettingsInput()
                SecureField("服务密码（如有）", text: $password).luoyeSettingsInput()
                LuoyeSettingsAction(title: store.connecting ? "正在连接…" : "保存并连接", icon: "network", prominent: true) {
                    do { try store.configure(address); failure = nil; let secret = password; password = ""; Task { await store.connect(password: secret) } }
                    catch { failure = error.localizedDescription }
                }.disabled(store.connecting || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !store.server.isEmpty { Button("断开服务", role: .destructive) { try? store.configure(""); address = ""; password = "" }.font(.serif(13)) }
                if let message = failure ?? store.message { Text(message).font(.serif(12)).foregroundStyle(.secondary) }
            }
            LuoyeSettingsSection(title: "下载与阅读") {
                NavigationLink { TomatoJobsView() } label: { Label("下载任务", systemImage: "arrow.down.circle") }
                NavigationLink { TomatoLibraryView() } label: { Label("下载书库 · 导入 TXT / EPUB", systemImage: "books.vertical") }
                Text("书目、目录缓存与收藏保存在 Haiku 空间。番茄收藏为本机收藏，不同步到官网账号。").font(.serif(12)).foregroundStyle(.secondary)
            }
            LuoyeSettingsSection(title: "开源项目", footnote: "公开书目和目录解析及 WebUI 协议参考 Tomato-Novel-Downloader。服务是否支持搜索，取决于其启用的组件。") {
                Link("Tomato-Novel-Downloader", destination: URL(string: "https://github.com/zhongbai2333/Tomato-Novel-Downloader")!)
                NavigationLink("MIT 开源许可") {
                    ScrollView { Text(license).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(20) }.background(Color.paper).navigationTitle("开源许可")
                }
            }
        }.task { address = store.server }.sheet(isPresented: $showWebsite) { TomatoWebsiteView() }
    }
    private var license: String { Bundle.main.url(forResource: "TomatoDownloader-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "MIT License · Tomato-Novel-Downloader" }
}

struct TomatoJobsView: View {
    @Environment(TomatoStore.self) private var store
    @State private var jobs: [TomatoJob] = []
    @State private var failure: String?
    @State private var busy = false
    @State private var displayedServer: String?
    @State private var reloadRequest = UUID()
    @State private var actionRequest = UUID()
    @State private var actionTask: Task<Void, Never>?
    var body: some View {
        LuoyeSettingsPage(title: "番茄下载任务") {
            if store.endpoint == nil {
                NavigationLink { TomatoSettingsView() } label: { Label("先连接下载器服务", systemImage: "network") }
            } else {
                NavigationLink { TomatoLibraryView() } label: { Label("打开下载书库", systemImage: "books.vertical") }
                if let failure { Text(failure).font(.serif(13)).foregroundStyle(.secondary) }
                if jobs.isEmpty && failure == nil { Text("暂无下载任务，在书籍详情页点击下载全书。").font(.serif(14)).foregroundStyle(.secondary) }
                ForEach(jobs) { job in
                    LuoyeSettingsSection(title: job.title ?? job.book_id, detail: job.stateTitle) {
                        if let progress = job.progress, progress.chapter_total > 0 {
                            ProgressView(value: Double(progress.saved_chapters), total: Double(max(progress.chapter_total, progress.saved_chapters)))
                            Text("\(progress.saved_chapters) / \(progress.chapter_total) 章").font(.serif(12))
                        }
                        if let message = job.message { Text(message).font(.serif(12)).foregroundStyle(.secondary) }
                        if job.active {
                            choices(job.book_name_options, job: job, kind: "book_name", title: "选择书名")
                            choices(job.format_options, job: job, kind: "format", title: "选择下载格式")
                            Button("取消任务", role: .destructive) { action { client, base in try await client.cancel(job.id, base: base) } }.disabled(busy)
                        }
                    }
                }
            }
        }.task(id: store.server) {
            guard store.endpoint != nil else { jobs = []; failure = nil; return }
            repeat {
                await reload()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            } while !Task.isCancelled
        }.refreshable { await reload() }
        .onChange(of: store.server) { _, _ in actionTask?.cancel(); actionRequest = UUID(); busy = false }
        .onDisappear { actionTask?.cancel() }
    }
    @ViewBuilder private func choices(_ options: [TomatoChoice]?, job: TomatoJob, kind: String, title: String) -> some View {
        if let options, !options.isEmpty {
            Menu(title) { ForEach(options) { option in Button(option.label) { action { client, base in try await client.choose(option.value, for: job.id, kind: kind, base: base) } } } }.disabled(busy)
        }
    }
    private func reload() async {
        guard let base = store.endpoint else { jobs = []; failure = nil; return }
        let server = store.server, client = store.client
        let request = UUID(); reloadRequest = request
        if displayedServer != server { jobs = []; failure = nil; displayedServer = server }
        do {
            let items = try await client.jobs(base: base)
            try Task.checkCancellation()
            guard reloadRequest == request, store.server == server else { return }
            jobs = items; failure = nil
        } catch { if !Task.isCancelled && reloadRequest == request && store.server == server { failure = error.localizedDescription } }
    }
    private func action(_ operation: @escaping (TomatoClient, URL) async throws -> Void) {
        guard !busy, displayedServer == store.server, let base = store.endpoint else { return }
        let server = store.server, client = store.client
        let request = UUID(); actionRequest = request; busy = true
        actionTask = Task {
            defer { if actionRequest == request { busy = false; actionTask = nil } }
            do {
                try Task.checkCancellation()
                guard store.server == server else { return }
                try await operation(client, base)
                try Task.checkCancellation()
                guard store.server == server else { return }
                await reload()
            } catch { if !Task.isCancelled && actionRequest == request && store.server == server { failure = error.localizedDescription } }
        }
    }
}

struct TomatoLibraryView: View {
    var path = ""
    var book: TomatoBook? = nil
    var originServer: String? = nil
    @Environment(TomatoStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @State private var files: [TomatoRemoteFile] = []
    @State private var failure: String?
    @State private var scanning = false
    @State private var importRequest: UUID?
    @State private var displayedServer: String?
    @State private var scanRequest = UUID()
    @State private var reading: Book?
    var body: some View {
        LuoyeSettingsPage(title: "番茄下载书库") {
            if let originServer, originServer != store.server {
                Text("下载器服务已更换，请打开当前服务的书库。").font(.serif(13)).foregroundStyle(.secondary)
                NavigationLink { TomatoLibraryView(book: book) } label: { Label("打开当前下载书库", systemImage: "books.vertical") }
            } else if store.endpoint == nil { NavigationLink { TomatoSettingsView() } label: { Label("先连接下载器服务", systemImage: "network") } }
            else {
                Text(book == nil ? "选择 TXT / EPUB，导入本地书斋并打开阅读器。" : "请只选择《\(book!.title)》的正文文件。").font(.serif(13)).foregroundStyle(.secondary)
                if scanning { ProgressView("正在扫描书库…").font(.serif(13)) }
                if let failure { Text(failure).font(.serif(13)).foregroundStyle(.secondary) }
                if files.isEmpty && !scanning && failure == nil { Text("书库暂无文件，请先完成下载任务。").font(.serif(14)).foregroundStyle(.secondary) }
                LuoyePanel {
                    ForEach(files) { file in
                        if file.isDirectory {
                            NavigationLink { TomatoLibraryView(path: file.rel_path, book: book, originServer: store.server) } label: { fileRow(file) }.buttonStyle(.plain)
                        } else {
                            Button { importFile(file) } label: { fileRow(file) }.buttonStyle(.plain).disabled(!file.readable || store.importer.importing != nil)
                        }
                        if file.id != files.last?.id { LuoyePanelDivider() }
                    }
                }
                if store.importer.importing != nil { ProgressView("正在下载并导入…").font(.serif(13)) }
            }
        }.task(id: store.server) { await reload() }.refreshable { await reload() }
        .onDisappear { if let importRequest { store.importer.cancel(id: importRequest) } }
        .fullScreenCover(item: $reading) { ReaderView(book: $0) }
    }
    private func fileRow(_ file: TomatoRemoteFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isDirectory ? "folder" : "doc.text").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).font(.serif(14)).lineLimit(2)
                if !file.isDirectory { Text(file.readable ? "\(file.ext.uppercased()) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file))" : "暂不支持此格式").font(.serif(11)).foregroundStyle(.secondary) }
            }
            Spacer(); Image(systemName: file.isDirectory ? "chevron.right" : "arrow.down.to.line").font(.caption).foregroundStyle(.tertiary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func reload() async {
        let request = UUID(); scanRequest = request
        guard originServer == nil || originServer == store.server, let base = store.endpoint else { files = []; scanning = false; failure = nil; return }
        let client = store.client
        let server = store.server
        if displayedServer != server { files = []; failure = nil; displayedServer = server }
        scanning = true; defer { if scanRequest == request { scanning = false } }
        do {
            var start = true
            repeat {
                let snapshot = try await client.library(base: base, path: path, start: start)
                try Task.checkCancellation()
                guard scanRequest == request, store.server == server else { return }
                files = snapshot.items; failure = snapshot.error
                if !snapshot.running { break }; start = false
                try await Task.sleep(for: .seconds(1))
            } while !Task.isCancelled
        } catch { if !Task.isCancelled && scanRequest == request && store.server == server { failure = error.localizedDescription } }
    }
    private func importFile(_ file: TomatoRemoteFile) {
        guard displayedServer == store.server, let base = store.endpoint, store.importer.importing == nil else { return }
        let server = store.server, client = store.client
        failure = nil
        importRequest = store.importer.start(file: file, base: base, book: book, context: modelContext, download: {
            try await client.download(file, base: base)
        }) { result in
            guard store.server == server else { return }
            switch result {
            case .success(let imported): reading = imported
            case .failure(let error): if !(error is CancellationError) { failure = error.localizedDescription }
            }
        }
    }
}
