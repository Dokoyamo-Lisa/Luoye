import SwiftUI
import CryptoKit

/// Shares Haiku's native typography controls, pagination, auto page and auto scroll implementation.
struct TomatoOnlineReader: View {
    let book: TomatoBook
    let chapters: [TomatoChapter]
    let initialChapter: TomatoChapter
    @Environment(TomatoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var readingBook: Book?
    @State private var fontURL: URL?
    @State private var loadedChapterID: String?
    @State private var forceReload = false
    @State private var readingPage: TomatoReadingPage?
    @State private var failure: String?
    @State private var loading = false
    @State private var showChapters = false
    @State private var showWebsite = false
    @State private var requestID = UUID()
    @State private var readingRevision = UUID()
    @State private var resumeAutoMode: AutoMode?
    @State private var startAtBeginning = false
    init(book: TomatoBook, chapters: [TomatoChapter], initialChapter: TomatoChapter, initialAutoMode: AutoMode? = nil) {
        self.book = book; self.chapters = chapters; self.initialChapter = initialChapter
        _resumeAutoMode = State(initialValue: initialAutoMode)
        _index = State(initialValue: chapters.firstIndex { $0.id == initialChapter.id } ?? 0)
    }
    private var chapter: TomatoChapter? { chapters.indices.contains(index) ? chapters[index] : nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("关闭番茄阅读器")
                Spacer(minLength: 0)
                Button { showChapters = true } label: { Text(chapter?.title ?? book.title).lineLimit(1) }.accessibilityLabel("打开番茄章节目录")
                Spacer(minLength: 0)
                Button { change(index - 1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0 || loading).accessibilityLabel("上一章")
                Button { change(index + 1) } label: { Image(systemName: "chevron.right") }.disabled(index + 1 >= chapters.count || loading).accessibilityLabel("下一章")
            }.font(.serif(12)).foregroundStyle(Color.ink).padding(.horizontal, 20).frame(height: 44).background(Color.paper)
            if let failure, readingBook != nil {
                Text(failure).font(.serif(12)).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity).background(Color.paper)
            }
            ZStack {
                Color.paper
                if let readingBook, let readingPage, let loadedChapterID {
                    let revision = readingRevision
                    ReaderView(book: readingBook, bodyFontURL: fontURL,
                               providedChapter: Chapter(id: 0, title: readingPage.title, paragraphs: readingPage.paragraphs),
                               initialAutoMode: resumeAutoMode, isInteractionSuspended: showChapters || showWebsite || loading, onForwardBoundary: { mode in
                        guard readingRevision == revision, chapter?.id == loadedChapterID, !loading,
                              chapters.indices.contains(index + 1) else { return }
                        change(index + 1, autoMode: mode, fromBoundary: true)
                    }).id(revision)
                }
                else if loading { ProgressView("正在提纯正文…").font(.serif(14)) }
                else if let failure {
                    VStack(spacing: 20) {
                        Text(failure).font(.serif(14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("重试") { requestID = UUID() }
                        Button("官网登录 / 验证") { showWebsite = true }
                    }.padding(28)
                }
            }.clipped()
        }.background(Color.paper)
        .task(id: requestID) { await load() }
        .task(id: readingBook?.id) {
            guard readingBook != nil, chapters.indices.contains(index + 1) else { return }
            _ = try? await store.catalog.chapter(chapters[index + 1].id)
        }
        .onChange(of: readingBook?.readingOffset) { _, _ in saveProgress() }
        .onDisappear { saveProgress(); cleanTemporaryBook() }
        .sheet(isPresented: $showWebsite, onDismiss: { forceReload = true; requestID = UUID() }) { TomatoWebsiteView() }
        .sheet(isPresented: $showChapters) {
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { offset, item in
                            Button { showChapters = false; change(offset) } label: {
                                HStack { Text(item.title).font(.serif(14)); Spacer(); if offset == index { Image(systemName: "book") } }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Divider().opacity(0.3)
                        }
                    }.padding(.horizontal, 12)
                }.background(Color.paper).navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showChapters = false } } }
            }
        }
    }
    private func change(_ next: Int, autoMode: AutoMode? = nil, fromBoundary: Bool = false) {
        guard chapters.indices.contains(next) else { return }
        saveProgress(); cleanTemporaryBook(); index = next; forceReload = false
        resumeAutoMode = autoMode; startAtBeginning = fromBoundary; requestID = UUID()
    }
    private func saveProgress() {
        guard let readingBook, let loadedChapterID else { return }
        store.progress.save(bookID: book.id, chapterID: loadedChapterID, offset: readingBook.readingOffset)
    }
    private func cleanTemporaryBook() {
        readingBook = nil; readingPage = nil; loadedChapterID = nil
    }
    private func load() async {
        guard let chapter else { return }
        let request = requestID
        loading = true; failure = nil
        defer { if requestID == request { loading = false } }
        do {
            await store.website.sync(to: store.catalog)
            let page = try await store.catalog.chapter(chapter.id, refresh: forceReload)
            let pageFontURL = await store.catalog.fontURL(for: page)
            try Task.checkCancellation()
            guard requestID == request else { return }
            saveProgress(); cleanTemporaryBook()
            // Stable chapter identity preserves native reader bookmarks across visits without adding every chapter to the local shelf.
            let bytes = Array(SHA256.hash(data: Data(("tomato-chapter:" + chapter.id).utf8)).prefix(16))
            let uuid = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            // Content is supplied directly to ReaderView; no temporary TXT is needed.
            let local = Book(id: uuid, title: book.title, author: book.author, format: "txt", fileName: "tomato-online-\(uuid.uuidString).txt", coverFileName: nil)
            local.readingOffset = startAtBeginning ? 0 : store.progress.offset(chapterID: chapter.id)
            readingRevision = UUID()
            readingPage = page; fontURL = pageFontURL; loadedChapterID = chapter.id; readingBook = local
            forceReload = false; startAtBeginning = false
            saveProgress()
        } catch {
            guard !Task.isCancelled, requestID == request else { return }
            switch (error as? URLError)?.code {
            case .notConnectedToInternet, .networkConnectionLost: failure = "网络未连接，请恢复网络后点“重试”。"
            case .timedOut: failure = "正文加载超时，请稍后重试。"
            default: failure = error.localizedDescription
            }
        }
    }
}
