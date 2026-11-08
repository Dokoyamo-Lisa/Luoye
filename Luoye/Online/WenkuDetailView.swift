import SwiftUI
import SwiftData

struct WenkuDetailView: View {
    private struct ReadingSelection: Identifiable {
        let id = UUID()
        let book: Book
        let chapter: (title: String, index: Int)?
    }
    private struct OnlineSelection: Identifiable {
        let id = UUID()
        let index: Int
    }
    let book: WenkuBook
    @Environment(BrowsingHistoryStore.self) private var history
    @Environment(WebsiteShelfStore.self) private var websiteShelf
    @Environment(WenkuService.self) private var service
    @Environment(\.modelContext) private var modelContext
    @Query private var savedBooks: [Book]
    @State private var details: WenkuBook?
    @State private var chapters: [WenkuChapterReference] = []
    @State private var metadata: [String] = []
    @State private var loading = false
    @State private var downloading = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadRequest = UUID()
    @State private var error: String?
    @State private var notice: String?
    @State private var readingSelection: ReadingSelection?
    @State private var onlineSelection: OnlineSelection?
    @State private var login = false

    private var display: WenkuBook { details ?? book }

    private var existingShelfBook: Book? {
        let name = "wenku8-\(book.id).txt"
        let sourceKey = "wenku8:\(book.id)"
        return savedBooks.first { ($0.fileName == name || $0.sourceKey == sourceKey) && BookImportCommit.hasLocalFile($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    LuoyeRemoteCover(title: display.title, coverURLString: display.cover, badge: "TXT")
                        .frame(width: 112, height: 163)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(display.title)
                            .font(.serif(21, medium: true))
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        if display.author.isEmpty {
                            Text("轻小说文库")
                                .font(.serif(14))
                                .foregroundStyle(.secondary)
                        } else {
                            NavigationLink {
                                WenkuCollectionView(facet: WenkuFacet(name: display.author, group: "作者作品", path: WenkuService.searchPath(display.author, field: "author", page: 1)))
                            } label: {
                                Label(display.author, systemImage: "person")
                                    .font(.serif(14))
                                    .foregroundStyle(.tint)
                            }
                        }

                        Text("WENKU8 · \(String(book.id))")
                            .font(.system(size: 10, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(.secondary)

                        if !display.info.isEmpty {
                            Text(display.info)
                                .font(.serif(12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                let alreadySaved = existingShelfBook != nil
                HStack(spacing: 12) {
                    Button {
                        startStore(read: true)
                    } label: {
                        HStack(spacing: 8) {
                            if downloading { ProgressView().tint(Color.ink) }
                            else { Image(systemName: alreadySaved ? "book" : "arrow.down.circle") }
                            Text(downloading ? "正在准备…" : (alreadySaved ? "打开阅读" : "开始阅读"))
                                .font(.serif(15, medium: true))
                        }
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(downloading)

                    Button {
                        startStore(read: false)
                    } label: {
                        Image(systemName: alreadySaved ? "checkmark.circle" : "plus")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.ink)
                            .frame(width: 48, height: 48)
                            .background(Color.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(downloading)
                    .accessibilityLabel(alreadySaved ? "已在书斋" : "加入书斋")
                }

                Text("在线阅读按章加载并缓存；加入书斋会下载完整 TXT，供离线阅读。")
                    .font(.serif(12))
                    .foregroundStyle(.secondary)

                if let notice {
                    Label(notice, systemImage: "checkmark.circle")
                        .font(.serif(13))
                        .foregroundStyle(.tint)
                }

                if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error)
                            .font(.serif(13))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button {
                                if service.authenticated { Task { await load() } } else { login = true }
                            } label: {
                                Text(service.authenticated ? "重新加载" : "登录文库")
                                    .font(.serif(13, medium: true))
                                    .foregroundStyle(Color.ink)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                }

                if let tags = display.tags, !tags.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            NavigationLink {
                                WenkuCollectionView(facet: WenkuFacet(name: tag, group: "作品标签", path: WenkuService.searchPath(tag, field: "tag", page: 1)))
                            } label: {
                                Text(tag)
                                    .font(.serif(12))
                                    .foregroundStyle(Color.ink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !metadata.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(metadata, id: \.self) { item in
                            Text(item)
                                .font(.serif(12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                }

                Divider().opacity(0.45)

                VStack(alignment: .leading, spacing: 12) {
                    Text("故事简介")
                        .font(.serif(20, medium: true))
                        .foregroundStyle(Color.ink)
                    Text(display.summary.isEmpty ? "暂无简介" : display.summary)
                        .font(.serif(16))
                        .lineSpacing(8)
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                }

                if loading {
                    ProgressView("正在读取书籍资料…")
                        .font(.serif(13))
                        .frame(maxWidth: .infinity)
                }

                if !chapters.isEmpty {
                    Divider().opacity(0.45)
                    HStack {
                        Text("章节目录")
                            .font(.serif(20, medium: true))
                            .foregroundStyle(Color.ink)
                        Spacer()
                        Text("\(chapters.count) 章")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                            Button {
                                startStore(read: true, startChapter: (chapter.title, index))
                            } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        if index == 0 || chapters[index - 1].volume != chapter.volume {
                                            Text(chapter.volume)
                                                .font(.serif(11))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(chapter.title)
                                            .font(.serif(14))
                                            .foregroundStyle(Color.ink)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(downloading)
                            .padding(.vertical, 12)
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
            .luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle("书籍详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: service.authenticated) { await load() }
        .onDisappear { cancelStore() }
        .onChange(of: service.accountKey) { old, _ in if old != nil { cancelStore() } }
        .sheet(isPresented: $login) { WenkuLoginView() }
        .fullScreenCover(item: $readingSelection) { selection in
            ReaderView(book: selection.book, startChapter: selection.chapter)
        }
        .fullScreenCover(item: $onlineSelection) { selection in
            WenkuOnlineReader(book: display, chapters: chapters, initialIndex: selection.index)
        }
    }

    private func load() async {
        history.record(display)
        loading = true; error = nil
        defer { loading = false }
        do {
            let page = try await service.page("/book/\(book.id).htm")
            if let value = page.books.first(where: { $0.id == book.id }) {
                details = value
                history.updateMetadata(value)
                websiteShelf.update(value)
            }
            metadata = page.text.components(separatedBy: .newlines).filter {
                ["小说状态：", "最后更新：", "全文长度：", "文库分类："].contains(where: $0.contains)
            }.prefix(5).map { $0.trimmingCharacters(in: .whitespaces) }
            if let path = page.catalogue {
                let loaded = try await service.page(path).chapters
                if !loaded.isEmpty { chapters = loaded }
            }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func startStore(read: Bool, startChapter: (title: String, index: Int)? = nil) {
        if read, existingShelfBook == nil, !chapters.isEmpty {
            guard service.authenticated else { login = true; return }
            let savedID = UserDefaults.standard.integer(forKey: "luoye.wenku.online.\(service.accountKey ?? "anonymous").\(book.id).lastChapter")
            let resume = chapters.firstIndex { $0.id == savedID } ?? 0
            onlineSelection = OnlineSelection(index: startChapter?.index ?? resume)
            return
        }
        guard downloadTask == nil else { return }
        let request = UUID(); downloadRequest = request
        downloadTask = Task { await store(read: read, startChapter: startChapter, request: request) }
    }
    private func cancelStore() {
        downloadTask?.cancel(); downloadRequest = UUID(); downloadTask = nil; downloading = false
    }
    private func store(read: Bool, startChapter: (title: String, index: Int)?, request: UUID) async {
        downloading = true; error = nil; notice = nil
        defer { if downloadRequest == request { downloading = false; downloadTask = nil } }
        do {
            let sourceKey = "wenku8:\(book.id)"
            if let saved = existingShelfBook {
                try Task.checkCancellation()
                guard downloadRequest == request else { return }
                if read { readingSelection = ReadingSelection(book: saved, chapter: startChapter) }
                else { notice = "这本书已经在书斋里了。" }
                await saveCover(for: saved)
                return
            }
            await service.refreshSession()
            try Task.checkCancellation()
            guard service.authenticated else { login = true; return }
            let account = service.accountKey
            let download = try await WenkuTextDownload.fetch(aid: book.id)
            try Task.checkCancellation()
            let title = display.title, author = display.author, bookID = book.id
            let cachedCover = if let cover = display.cover { await FanhuaCache.shared.data(for: cover) } else { nil as Data? }
            let prepared = try await Task.detached(priority: .userInitiated) {
                let temp = FileManager.default.temporaryDirectory.appending(path: "wenku-import-" + UUID().uuidString + ".txt")
                defer { try? FileManager.default.removeItem(at: temp) }
                try download.data.write(to: temp, options: .atomic)
                return PreparedBookImport(try BookImporter.importDownloadedBook(from: temp, extensionName: "txt",
                    preferredTitle: title, preferredAuthor: author, preferredCover: cachedCover,
                    fileName: "wenku8-\(bookID)-\(UUID().uuidString).txt", sourceKey: sourceKey, editionNote: "TXT · 轻小说文库"))
            }.value
            guard downloadRequest == request, service.accountKey == account else { prepared.removeFiles(); throw CancellationError() }
            let saved = try BookImportCommit.commit(prepared, context: modelContext, legacyFileName: "wenku8-\(book.id).txt")
            try Task.checkCancellation()
            guard downloadRequest == request, service.accountKey == account else { return }
            notice = "已加入书斋"
            if read { readingSelection = ReadingSelection(book: saved, chapter: startChapter) }
            await saveCover(for: saved)
        } catch {
            if downloadRequest == request && !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    private func saveCover(for saved: Book) async {
        guard saved.coverFileName == nil, let raw = display.cover,
              let url = URL(string: raw), url.scheme == "https" else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("https://www.wenku8.net/", forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await FanhuaNetwork.session.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 3_000_000,
                  UIImage(data: data) != nil else { return }
            let name = "wenku8-\(book.id)-cover.jpg"
            let file = BookStorage.directory.appending(path: name)
            try data.write(to: file, options: .atomic)
            saved.coverFileName = name
            do { try modelContext.save() }
            catch { saved.coverFileName = nil; try? FileManager.default.removeItem(at: file) }
        } catch { /* 封面失败不会阻止已经保存的书籍进入阅读器。 */ }
    }
}
