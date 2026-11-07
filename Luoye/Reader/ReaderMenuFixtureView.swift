import SwiftUI

struct ReaderMenuVerificationHost: ViewModifier {
    #if DEBUG
    @State private var presented = false
    func body(content: Content) -> some View {
        content.sheet(isPresented: $presented) { ReaderMenuFixtureView() }
            .task { if ProcessInfo.processInfo.arguments.contains("--show-reader-menu-fixture") { presented = true } }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
#if DEBUG
import SwiftData

private struct ReaderMenuFixtureView: View {
    private enum Choice: String, Identifiable { case novel, novelScroll, novelProgress, novelBookmark, manga, mangaMissing; var id: String { rawValue } }
    @Environment(\.dismiss) private var dismiss
    @State private var choice: Choice?
    @State private var prefs: UserDefaults?
    @State private var suite: String?
    @State private var book: Book?
    @State private var container: ModelContainer?
    @State private var comic: MangaComic?
    @State private var library: MangaLibrary?
    @State private var failure: String?
    @State private var offsetChangeCount = 0
    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                if prefs != nil, book != nil, comic != nil {
                    Button("小说菜单测试") { choice = .novel }
                    Button("小说下拉测试") { choice = .novelScroll }
                    Button("表情进度测试") { book?.readingOffset = 500; choice = .novelProgress }
                    Button("表情书签测试") { book?.readingOffset = 500; choice = .novelBookmark }
                    Button("漫画菜单测试") { choice = .manga }
                    Button("缺失漫画文件测试") { choice = .mangaMissing }
                } else if let failure { Text(failure) }
                else { ProgressView() }
            }.font(.serif(16)).navigationTitle("菜单交互验证").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .overlay(alignment: .topLeading) { ReaderIdleVerificationStatus(id: "fixture.host.idle") }
        .fullScreenCover(item: $choice) { selected in
            if let prefs, let container, let book, let library, let comic {
                Group {
                    if selected != .manga && selected != .mangaMissing {
                        ReaderView(book: book, providedChapter: (selected == .novelProgress || selected == .novelBookmark) ? Chapter(id: 0, title: "", paragraphs: [String(repeating: "🐱", count: selected == .novelBookmark ? 300 : 500)]) : Chapter(id: 0, title: "自写菜单测试", paragraphs: [String(repeating: "自写菜单交互正文，打开菜单时自动阅读应暂停，收起后继续，文字位置保持稳定。", count: 150)]), initialAutoMode: (selected == .novelProgress || selected == .novelBookmark) ? nil : selected == .novelScroll ? .scroll : .pages)
                            .overlay(alignment: .top) { Text("\(book.readingOffset)").font(.caption).accessibilityIdentifier("fixture.novel.offset").allowsHitTesting(false).padding(.top, 8) }
                            .overlay(alignment: .topTrailing) { Text(String(format: "%.3f", book.progress)).font(.caption).accessibilityIdentifier("fixture.novel.progress").allowsHitTesting(false).padding(.top, 8) }
                            .overlay(alignment: .topLeading) { Text("\(offsetChangeCount)").font(.system(size: 8)).accessibilityIdentifier("fixture.novel.offsetChanges").allowsHitTesting(false).padding(.top, 18) }
                            .onChange(of: book.readingOffset) { offsetChangeCount += 1 }
                    } else { ComicReaderView(comic: selected == .mangaMissing ? MangaComic(id: comic.id, title: "缺失漫画文件", format: "folder", fileName: "owned-nonexistent-" + comic.id.uuidString, coverFileName: nil, pageCount: 8) : comic).environment(library) }
                }.defaultAppStorage(prefs).modelContainer(container)
                    .overlay(alignment: .topLeading) { ReaderIdleVerificationStatus(id: "fixture.reader.idle") }
            }
        }
        .task {
            do {
                let name = "luoye-reader-menu-fixture-" + UUID().uuidString; suite = name
                let defaults = UserDefaults(suiteName: name)!
                defaults.set(3.0, forKey: "reader.pageSeconds")
                defaults.set(60.0, forKey: "reader.scrollLines")
                defaults.set("paged", forKey: "reader.pageMode"); defaults.set("paper", forKey: "reader.theme")
                defaults.set("capsule", forKey: "reader.menuStyle")
                defaults.set(3.0, forKey: "manga.reader.autoPageSeconds")
                defaults.set("pages", forKey: "manga.reader.autoMode")
                defaults.set(MangaReadingMode.pageLeftToRight.rawValue, forKey: "manga.reader.mode")
                defaults.set("capsule", forKey: "manga.reader.menuStyle")
                defaults.set("paper", forKey: "manga.reader.theme")
                prefs = defaults
                book = Book(id: UUID(), title: "菜单验证", author: "自写测试", format: "txt", fileName: "menu-fixture-unused.txt", coverFileName: nil)
                container = try ModelContainer(for: Book.self, Bookmark.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
                library = MangaLibrary()
                let folder = "reader-menu-fixture-" + UUID().uuidString
                let root = MangaLibrary.directory.appending(path: folder)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                for index in 0..<8 {
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { context in
                        UIColor.systemPink.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
                        ("\(index + 1)" as NSString).draw(at: CGPoint(x: 150, y: 230), withAttributes: [.font: UIFont.systemFont(ofSize: 130), .foregroundColor: UIColor.white])
                    }
                    try image.pngData()!.write(to: root.appending(path: "\(index).png"))
                }
                comic = MangaComic(id: UUID(), title: "自写菜单测试漫画", format: "folder", fileName: folder, coverFileName: nil, pageCount: 8)
            } catch { failure = error.localizedDescription }
        }
        .onDisappear {
            guard choice == nil else { return }
            if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
            if let comic { try? FileManager.default.removeItem(at: comic.fileURL) }
        }
    }
}
#endif
