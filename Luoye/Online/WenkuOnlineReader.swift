import CryptoKit
import SwiftUI

/// Reads only the selected Wenku chapter. Cached chapters survive app restarts.
struct WenkuOnlineReader: View {
    let book: WenkuBook
    let chapters: [WenkuChapterReference]
    let initialIndex: Int

    @Environment(WenkuService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var readingBook: Book?
    @State private var loadedChapterID: Int?
    @State private var paragraphs: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showContents = false
    @State private var requestID = UUID()
    @State private var readerID = UUID()
    @State private var startAtBeginning = false
    @State private var resumeAutoMode: AutoMode?

    init(book: WenkuBook, chapters: [WenkuChapterReference], initialIndex: Int) {
        self.book = book
        self.chapters = chapters
        self.initialIndex = initialIndex
        _index = State(initialValue: min(max(initialIndex, 0), max(0, chapters.count - 1)))
    }

    private var chapter: WenkuChapterReference? { chapters.indices.contains(index) ? chapters[index] : nil }
    private var account: String { service.accountKey ?? "anonymous" }
    private func progressKey(_ suffix: String) -> String { "luoye.wenku.online.\(account).\(book.id).\(suffix)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("关闭文库阅读器")
                Spacer(minLength: 0)
                Button { showContents = true } label: { Text(chapter?.title ?? book.title).lineLimit(1) }
                Spacer(minLength: 0)
                Button { change(index - 1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0 || loading)
                Button { change(index + 1) } label: { Image(systemName: "chevron.right") }.disabled(index + 1 >= chapters.count || loading)
            }
            .font(.serif(12)).foregroundStyle(Color.ink).padding(.horizontal, 20)
            .frame(height: 44).background(Color.paper)
            ZStack {
                Color.paper
                if let readingBook, let loadedChapterID, let chapter, loadedChapterID == chapter.id {
                    let revision = readerID
                    ReaderView(book: readingBook,
                               providedChapter: Chapter(id: 0, title: chapter.title, paragraphs: paragraphs),
                               initialAutoMode: resumeAutoMode, isInteractionSuspended: showContents || loading,
                               onForwardBoundary: { mode in
                        guard readerID == revision, self.loadedChapterID == chapter.id, !loading else { return }
                        change(index + 1, mode: mode, fromBoundary: true)
                    }).id(revision)
                } else if loading {
                    ProgressView("正在读取本章…").font(.serif(14))
                } else if let error {
                    VStack(spacing: 16) {
                        Text(error).font(.serif(14)).multilineTextAlignment(.center)
                        Button("重试") { requestID = UUID() }
                    }.padding(24)
                }
            }.clipped()
        }
        .background(Color.paper)
        .task(id: requestID) { await load() }
        .onChange(of: readingBook?.readingOffset) { _, _ in saveProgress() }
        .onDisappear { saveProgress() }
        .sheet(isPresented: $showContents) {
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { offset, item in
                            Button {
                                showContents = false
                                change(offset)
                            } label: {
                                HStack { Text(item.title); Spacer(); if offset == index { Image(systemName: "book") } }
                                    .font(.serif(14)).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Divider().opacity(0.3)
                        }
                    }.padding(.horizontal, 12)
                }.background(Color.paper).navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showContents = false } } }
            }
        }
    }

    private func change(_ next: Int, mode: AutoMode? = nil, fromBoundary: Bool = false) {
        guard chapters.indices.contains(next), next != index else { return }
        saveProgress()
        readingBook = nil; loadedChapterID = nil; paragraphs = []
        index = next; resumeAutoMode = mode; startAtBeginning = fromBoundary
        requestID = UUID()
    }

    private func saveProgress() {
        guard let readingBook, let loadedChapterID else { return }
        UserDefaults.standard.set(loadedChapterID, forKey: progressKey("lastChapter"))
        UserDefaults.standard.set(max(0, readingBook.readingOffset), forKey: progressKey("offset.\(loadedChapterID)"))
    }

    private func load() async {
        guard let chapter else { return }
        let request = requestID, owner = account
        loading = true; error = nil
        defer { if requestID == request { loading = false } }
        do {
            let key = "wenku-chapter-v1|\(owner)|\(book.id)|\(chapter.id)"
            let body: [String]
            if let data = await FanhuaCache.shared.data(for: key),
               let cached = try? JSONDecoder().decode([String].self, from: data), !cached.isEmpty {
                body = cached
            } else {
                let page = try await service.page(chapter.url)
                let parsed = page.content.filter { $0.kind == "text" }.map(\.value)
                guard !parsed.isEmpty else { throw WenkuFailure.invalid }
                body = parsed
                if let data = try? JSONEncoder().encode(parsed) { await FanhuaCache.shared.store(data, for: key) }
            }
            try Task.checkCancellation()
            guard requestID == request, account == owner, self.chapter?.id == chapter.id else { return }
            saveProgress()
            let bytes = Array(SHA256.hash(data: Data("wenku-online:\(book.id):\(chapter.id)".utf8)).prefix(16))
            let uuid = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            let local = Book(id: uuid, title: book.title, author: book.author, format: "txt", fileName: "wenku-online-\(uuid.uuidString).txt", coverFileName: nil)
            local.readingOffset = startAtBeginning ? 0 : max(0, UserDefaults.standard.integer(forKey: progressKey("offset.\(chapter.id)")))
            readerID = UUID(); paragraphs = body; loadedChapterID = chapter.id; readingBook = local
            startAtBeginning = false
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
