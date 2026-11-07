import SwiftUI

struct MangaOnlineReaderVerificationHost: ViewModifier {
    #if DEBUG
    @State private var presented = false
    func body(content: Content) -> some View {
        content.sheet(isPresented: $presented) { MangaOnlineReaderFixtureView() }
            .task { if ProcessInfo.processInfo.arguments.contains("--show-manga-online-fixture") { presented = true } }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
#if DEBUG
private actor MangaFixtureGate {
    var fails = false
    var brokenImage = false
    var scrollFailure = false
    func setScrollFailure() { brokenImage = true; scrollFailure = true }
    func hasScrollFailure() -> Bool { scrollFailure }
    func setBrokenImage(_ value: Bool) { brokenImage = value }
    func hasBrokenImage() -> Bool { brokenImage }
    func setFailure(_ value: Bool) { fails = value }
    func failing() -> Bool { fails }
}
private struct MangaFixtureSource: MangaCatalogSource {
    private let gate = MangaFixtureGate()
    func setFailure(_ value: Bool) async { await gate.setFailure(value) }
    func setBrokenImage(_ value: Bool) async { await gate.setBrokenImage(value) }
    func setScrollFailure() async { await gate.setScrollFailure() }
    let id = "fixture-online"
    let displayName = "自写跨话测试"
    let chapterPageSize: Int? = nil
    func discover(page: Int) async throws -> [MangaOnlineComic] { [] }
    func search(_ query: String, page: Int) async throws -> [MangaOnlineComic] { [] }
    func chapters(for comic: MangaOnlineComic, page: Int) async throws -> [MangaOnlineChapter] { Self.catalogue }
    func pages(for chapter: MangaOnlineChapter) async throws -> [MangaImageRequest] {
        if chapter.id == "two", await gate.failing() { throw URLError(.notConnectedToInternet) }
        if chapter.id == "one", await gate.hasBrokenImage() {
            var requests = [MangaImageRequest(url: URL(string: "http://127.0.0.1:18879/bad/0.png")!)]
            if await gate.hasScrollFailure() { requests.append(MangaImageRequest(url: URL(string: "http://127.0.0.1:18879/tall/0.png")!)) }
            return requests
        }
        return (0..<chapter.pageCount).map { MangaImageRequest(url: URL(string: "http://127.0.0.1:18879/\(chapter.id)/\($0).png")!) }
    }
    static let catalogue = [
        MangaOnlineChapter(id: "one", title: "自写第1话", language: "en", group: "自写", pageCount: 1, externalURL: nil),
        MangaOnlineChapter(id: "two", title: "自写第2话", language: "en", group: "自写", pageCount: 8, externalURL: nil)
    ]
}
private struct MangaOnlineReaderFixtureView: View {
    private enum Selection: String, Identifiable { case normal, failure, imageFailure, scrollFailure; var id: String { rawValue } }
    @Environment(\.dismiss) private var dismiss
    @State private var root: URL?
    @State private var prefs: UserDefaults?
    @State private var suite: String?
    @State private var library: MangaLibrary?
    @State private var selection: Selection?
    @State private var source = MangaFixtureSource()
    @State private var imageRepaired = false
    private let comic = MangaOnlineComic(id: "owned-fixture", title: "在线跨话自写测试", summary: "", coverURL: nil, source: "fixture-online")
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if library != nil {
                    Button("打开跨话测试") { Task { await source.setFailure(false); selection = .normal } }
                    Button("坏图下拉测试") { Task { await source.setFailure(false); await source.setScrollFailure(); selection = .scrollFailure } }
                    Button("坏图自动阅读测试") { Task { await source.setFailure(false); await source.setBrokenImage(true); selection = .imageFailure } }
                    Button("跨话断网测试") { Task { await source.setFailure(true); selection = .failure } }
                }
                else { ProgressView() }
            }.navigationTitle("在线漫画跨话验证")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .fullScreenCover(item: $selection) { selected in
            if let library, let prefs {
                MangaOnlineReaderView(comic: comic, chapter: MangaFixtureSource.catalogue[0], source: source, chapters: MangaFixtureSource.catalogue, nextChapterPage: 2, chapterEnded: true, language: "en")
                    .environment(library).defaultAppStorage(prefs)
                    .overlay(alignment: .topLeading) {
                        if selected == .failure {
                            Button("恢复测试网络") { Task { await source.setFailure(false) } }
                                .font(.caption).padding(8).background(Color.paper).padding(.top, 50)
                        } else if selected == .imageFailure || selected == .scrollFailure {
                            Button(imageRepaired ? "测试图片已修复" : "修复测试图片") {
                                Task {
                                    var request = URLRequest(url: URL(string: "http://127.0.0.1:18879/repair")!); request.httpMethod = "POST"
                                    if (try? await URLSession.shared.data(for: request)) != nil { imageRepaired = true }
                                }
                            }.font(.caption).padding(8).background(Color.paper).padding(.top, 50)
                        }
                    }
            }
        }
        .task {
            let root = FileManager.default.temporaryDirectory.appending(path: "manga-online-reader-fixture-" + UUID().uuidString)
            self.root = root
            let name = "luoye-manga-online-reader-fixture-" + UUID().uuidString; suite = name
            let prefs = UserDefaults(suiteName: name)!; self.prefs = prefs
            prefs.set("pageLeftToRight", forKey: "manga.reader.mode")
            prefs.set("pages", forKey: "manga.reader.autoMode")
            prefs.set(3.0, forKey: "manga.reader.autoPageSeconds")
            prefs.set("capsule", forKey: "manga.reader.menuStyle")
            prefs.set("paper", forKey: "manga.reader.theme")
            let library = MangaLibrary(stateDirectory: root)
            library.recordOnlinePage(5, comic: comic, chapter: MangaFixtureSource.catalogue[1])
            self.library = library
        }
        .onDisappear {
            guard selection == nil else { return }
            if let root { try? FileManager.default.removeItem(at: root) }
            if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        }
    }
}
#endif
