import SwiftData
import SwiftUI

/// 书斋首页：左上角标题，下面是本地书斋与官网书架；没有书时显示空状态。
struct BookshelfView: View {
    @Environment(WenkuService.self) private var service
    @Environment(WebsiteShelfStore.self) private var websiteShelf
    @Environment(ZLibService.self) private var zlibService
    @Environment(ZLibAccountStore.self) private var zlibAccount
    @State private var scope = "local"
    @AppStorage("fanhua.onlineShelfSource") private var onlineSourceRaw = BookSource.wenku8.rawValue
    @State private var zlibSection = "favorites"
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showingImporter = false
    @State private var failedImports: [String] = []
    @State private var bookToRemove: Book?
    @State private var readingBook: Book?
    @State private var wenkuLogin = false
    @State private var zlibLogin = false

    private var onlineSource: BookSource {
        BookSource(rawValue: onlineSourceRaw) ?? .wenku8
    }

    private let scopeItems: [LuoyeSegmentItem<String>] = [
        .init(value: "local", title: "本地书斋"),
        .init(value: "online", title: "官网书架")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paper.ignoresSafeArea()

                if scope == "online" {
                    onlineShelfBody
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: metrics.headerGap) {
                            header
                            if books.isEmpty {
                                LuoyeEmptyState(
                                    icon: "leaf",
                                    title: "案头尚空",
                                    message: "置一卷书于此，闲时展读",
                                    actionTitle: "添一卷书",
                                    action: { showingImporter = true }
                                )
                                .padding(.top, 28)
                            } else {
                                shelf
                            }
                        }
                        .padding(.horizontal, metrics.margin)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                    }
                }
            }
            .scrollEdgeEffectHidden(true, for: .bottom)
            .toolbarBackground(.hidden, for: .tabBar)
            .luoyeRootSurface()
            .navigationDestination(for: WenkuBook.self) { WenkuDetailView(book: $0) }
            .navigationDestination(for: TomatoBook.self) { TomatoDetailView(book: $0) }
            .navigationDestination(for: ZLibBook.self) { ZLibDetailView(book: $0) }
            .fullScreenCover(item: $readingBook) { book in
                ReaderView(book: book)
            }
            .sheet(isPresented: $wenkuLogin) { WenkuLoginView() }
            .sheet(isPresented: $zlibLogin) { ZLibLoginView() }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: BookImporter.supportedTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    importBooks(urls)
                }
            }
            .alert(
                "有 \(failedImports.count) 本书没能放进来",
                isPresented: Binding(get: { !failedImports.isEmpty }, set: { if !$0 { failedImports = [] } })
            ) {
                Button("知道了") {}
            } message: {
                Text(failedImports.joined(separator: "、") + "\n文件可能已损坏，或格式暂不支持。")
            }
            .confirmationDialog(
                "将《\(bookToRemove?.title ?? "")》移出书斋？",
                isPresented: Binding(get: { bookToRemove != nil }, set: { if !$0 { bookToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("移出书斋", role: .destructive) {
                    if let book = bookToRemove { remove(book) }
                }
            } message: {
                Text("只删除书斋里的这一份，不影响你手机里的原文件。")
            }
        }
    }

    @ViewBuilder
    private var onlineShelfBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                HStack(spacing: 8) {
                    ForEach(BookSource.allCases) { item in
                        LuoyeChip(title: item.displayName, active: onlineSource == item) {
                            onlineSourceRaw = item.rawValue
                        }
                    }
                    Spacer()
                }

                if onlineSource == .tomato {
                    TomatoShelfContent()
                } else if onlineSource == .wenku8 {
                    if websiteShelf.syncing {
                        ProgressView("正在同步文库书架…")
                            .font(.serif(13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                    if let error = websiteShelf.error {
                        Text(error)
                            .font(.serif(12))
                            .foregroundStyle(.secondary)
                    }
                    if !service.authenticated {
                        LuoyeEmptyState(
                            icon: "cloud",
                            title: "尚未连接轻小说文库",
                            message: "登录后可将你在文库官网收藏的书目同步至此。",
                            actionTitle: "登录轻小说文库",
                            action: { wenkuLogin = true }
                        )
                    } else if !websiteShelf.syncing && websiteShelf.books.isEmpty && websiteShelf.error == nil {
                        LuoyeEmptyState(
                            icon: "books.vertical",
                            title: "文库书架尚空",
                            message: "下拉可同步最新收藏书目；点击书籍可按需获取正文。",
                            actionTitle: "立即同步",
                            action: { Task { await websiteShelf.sync(using: service) } }
                        )
                    } else {
                        WenkuBookGrid(books: websiteShelf.books)
                    }
                } else {
                    LuoyeSegmentBar(
                        items: [
                            .init(value: "favorites", title: "收藏书库", badge: "\(zlibAccount.favorites.count)"),
                            .init(value: "downloads", title: "下载历史", badge: "\(zlibAccount.downloads.count)")
                        ],
                        selection: $zlibSection
                    )

                    if zlibAccount.syncing {
                        ProgressView("正在同步 Z-Library 书目…")
                            .font(.serif(13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                    if let error = zlibAccount.error {
                        Text(error)
                            .font(.serif(12))
                            .foregroundStyle(.secondary)
                    }
                    if !zlibService.authenticated {
                        LuoyeEmptyState(
                            icon: "books.vertical",
                            title: "尚未连接 Z-Library",
                            message: "登录后可同步个人收藏书库与下载历史，书目先行同步、正文按需获取。",
                            actionTitle: "登录 Z-Library",
                            action: { zlibLogin = true }
                        )
                    } else {
                        let activeBooks = zlibSection == "favorites" ? zlibAccount.favorites : zlibAccount.downloads
                        if !zlibAccount.syncing && activeBooks.isEmpty && zlibAccount.error == nil {
                            LuoyeEmptyState(
                                icon: zlibSection == "favorites" ? "bookmark" : "arrow.down.circle",
                                title: zlibSection == "favorites" ? "收藏书库尚空" : "暂无下载记录",
                                message: zlibSection == "favorites"
                                    ? "在书籍详情页点击收藏，或在官网保存的书籍会同步到这里；点击书籍可按需下载正文。"
                                    : "你在 Z-Library 下载过的书籍会记录在这里，下拉可刷新同步。",
                                actionTitle: "同步书目",
                                action: { Task { await zlibAccount.sync(using: zlibService) } }
                            )
                        } else {
                            ZLibBookGrid(books: activeBooks)
                        }
                    }
                }
            }
            .padding(.horizontal, metrics.margin)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .refreshable {
            if onlineSource == .wenku8 {
                await websiteShelf.sync(using: service)
            } else if onlineSource == .zlib {
                await zlibAccount.sync(using: zlibService)
            }
        }
    }

    private var metrics: ShelfMetrics { sizeClass == .regular ? .pad : .phone }

    private var header: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center) {
                PageHeader(title: "书斋", caption: Self.lunarToday(), titleSize: metrics.titleSize)
                Spacer()
                addMenu
            }
            LuoyeSegmentBar(items: scopeItems, selection: $scope)
        }
    }

    private var addMenu: some View {
                    Menu {
                        Button("同步文库书架", systemImage: "arrow.triangle.2.circlepath") {
                            scope = "online"
                            onlineSourceRaw = BookSource.wenku8.rawValue
                            Task { await websiteShelf.sync(using: service) }
                        }
                        Button("同步 Z-Library 书库", systemImage: "books.vertical") {
                            scope = "online"
                            onlineSourceRaw = BookSource.zlib.rawValue
                            Task { await zlibAccount.sync(using: zlibService) }
                        }
                        Divider()
                        Button("导入本地文件", systemImage: "doc.badge.plus") { showingImporter = true }
                    } label: { GlassCircleLabel(systemImage: "plus") }
        .buttonStyle(.plain).accessibilityLabel("添书")
    }

    private var shelf: some View {
        LazyVGrid(
            columns: [GridItem(
                .adaptive(minimum: metrics.coverWidth.lowerBound, maximum: metrics.coverWidth.upperBound),
                spacing: metrics.columnGap,
                alignment: .top
            )],
            alignment: .leading,
            spacing: metrics.rowGap
        ) {
            ForEach(books) { book in
                Button { readingBook = book } label: {
                    BookTile(book: book, large: sizeClass == .regular)
                }
                .buttonStyle(PressStyle())
                .contextMenu {
                    Button("移出书斋", systemImage: "trash", role: .destructive) {
                        bookToRemove = book
                    }
                }
            }
        }
    }

    private func importBooks(_ urls: [URL]) {
        var failed: [String] = []
        for url in urls {
            do {
                modelContext.insert(try BookImporter.importBook(from: url))
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        failedImports = failed
    }

    private func remove(_ book: Book) {
        BookStorage.removeFiles(of: book)
        let id = book.id
        try? modelContext.delete(model: Bookmark.self, where: #Predicate { $0.bookID == id })
        modelContext.delete(book)
    }

    /// 例如「丙午年九月廿二」。
    private static func lunarToday() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .chinese)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .long
        return String(formatter.string(from: .now).drop(while: \.isNumber))
    }
}

/// 书架上的一格：封面，下面书名、作者及版本说明。
private struct BookTile: View {
    let book: Book
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 10 : 8) {
            BookCover(book: book)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.serif(large ? 15 : 13, medium: true))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.serif(large ? 13 : 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let edition = book.editionNote, !edition.isEmpty {
                    Text(edition)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if book.progress > 0 {
                    ReadingProgress(value: book.progress, large: large)
                        .padding(.top, 4)
                }
            }
        }
    }
}
