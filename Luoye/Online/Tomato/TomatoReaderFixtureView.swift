import SwiftUI

struct TomatoReaderVerificationHost: ViewModifier {
    #if DEBUG
    @State private var presented = false
    func body(content: Content) -> some View {
        content.sheet(isPresented: $presented) { TomatoReaderFixtureView() }
            .task { if ProcessInfo.processInfo.arguments.contains("--show-tomato-reader-fixture") { presented = true } }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
#if DEBUG
import SwiftData

private final class TomatoReaderProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    private static var failSecond = false
    private static var longContent = false
    static func setFailure(_ value: Bool) { lock.withLock { failSecond = value } }
    static func setLong(_ value: Bool) { lock.withLock { longContent = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, second = url.path.hasSuffix("9000000000000000002")
        if second && Self.lock.withLock({ Self.failSecond }) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let chapter = second ? 2 : url.path.hasSuffix("9000000000000000003") ? 3 : 1
        let base = "这是第\(chapter)章自写正文，用于验证原生阅读器跨章，不含真实小说内容。"
        let body = Self.lock.withLock { Self.longContent } ? String(repeating: base, count: 15) : base
        let data = Data("<h1 class='muye-reader-title'>第\(chapter)章 连续阅读测试</h1><div class='muye-reader-content'><p>\(body)</p><p>当前章结束后，应继续下一章；第三章是全书末尾。</p></div>".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private enum TomatoReaderFixtureMode: String, Identifiable {
    case manual, longManual, pages, scroll, failure
    var id: String { rawValue }
    var autoMode: AutoMode? { self == .pages || self == .failure ? .pages : self == .scroll ? .scroll : nil }
}
private struct TomatoReaderFixtureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store: TomatoStore?
    @State private var container: ModelContainer?
    @State private var session: URLSession?
    @State private var directory: URL?
    @State private var suite: String?
    @State private var defaults: UserDefaults?
    @State private var mode: TomatoReaderFixtureMode?
    @State private var failure: String?
    private let book = TomatoBook(id: "9000000000000000000", title: "连续阅读自写测试")
    private var chapters: [TomatoChapter] {
        (1...3).map { .init(id: "900000000000000000\($0)", title: "第\($0)章 连续阅读测试") }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                if store != nil, container != nil {
                    Button("手动末页跨章") { open(.manual) }
                    Button("多页章末手势验证") { open(.longManual) }
                    Button("自动翻页跨三章") { open(.pages) }
                    Button("自动滚动跨三章") { open(.scroll) }
                    Button("跨章断网与重试") { open(.failure) }
                } else if let failure { Text(failure) }
                else { ProgressView() }
            }.font(.serif(16)).navigationTitle("番茄跨章验证").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .fullScreenCover(item: $mode) { selected in
            if let store, let container {
                TomatoOnlineReader(book: book, chapters: chapters, initialChapter: chapters[0], initialAutoMode: selected.autoMode)
                    .environment(store).modelContainer(container)
                    .defaultAppStorage(defaults ?? .standard)
                    .overlay(alignment: .top) {
                        Text(store.progress.lastChapter(bookID: book.id) ?? "")
                            .font(.system(size: 9)).accessibilityIdentifier("fixture.tomato.chapter").allowsHitTesting(false)
                    }
                    .overlay(alignment: .topLeading) {
                        if selected == .failure {
                            Button("恢复测试网络") { TomatoReaderProtocol.setFailure(false) }
                                .font(.serif(11)).padding(8).background(Color.paper).padding(.top, 54)
                        }
                    }
                    .task {
                        var observations: [[String: Any]] = []
                        while !Task.isCancelled {
                            observations.append(["time": Date().timeIntervalSince1970,
                                                 "chapter": store.progress.lastChapter(bookID: book.id) ?? "",
                                                 "offset": store.progress.offset(chapterID: store.progress.lastChapter(bookID: book.id) ?? ""),
                                                 "idleDisabled": UIApplication.shared.isIdleTimerDisabled])
                            let report: [String: Any] = ["mode": selected.rawValue, "observations": observations]
                            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                                try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeTomatoReader-\(selected.rawValue).json"), options: .atomic)
                            }
                            do { try await Task.sleep(for: .seconds(1)) } catch { break }
                        }
                    }
            }
        }
        .task {
            do {
                let root = FileManager.default.temporaryDirectory.appending(path: "tomato-reader-ui-fixture-" + UUID().uuidString)
                directory = root
                let name = "luoye-tomato-reader-fixture-" + UUID().uuidString; suite = name
                let defaults = UserDefaults(suiteName: name)!
                self.defaults = defaults
                defaults.set(3.0, forKey: "reader.pageSeconds")
                defaults.set(180.0, forKey: "reader.scrollLines")
                defaults.set("paged", forKey: "reader.pageMode")
                defaults.set("paper", forKey: "reader.theme")
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TomatoReaderProtocol.self]
                let fixtureSession = URLSession(configuration: config); session = fixtureSession
                store = TomatoStore(catalog: TomatoPublicCatalog(session: fixtureSession, directory: root), progress: TomatoReadingProgress(defaults: defaults), favoritesFile: root.appending(path: "favorites.json"))
                container = try ModelContainer(for: Book.self, Bookmark.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            } catch { failure = error.localizedDescription }
        }
        .onDisappear {
            guard mode == nil else { return }
            session?.invalidateAndCancel()
            if let directory { try? FileManager.default.removeItem(at: directory) }
            if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        }
    }
    private func open(_ next: TomatoReaderFixtureMode) {
        guard let store else { return }
        for chapter in chapters { store.progress.save(bookID: book.id, chapterID: chapter.id, offset: chapter.id == chapters[1].id ? 300 : 0) }
        store.progress.save(bookID: book.id, chapterID: chapters[0].id, offset: 0)
        if let directory {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: file) }
        }
        TomatoReaderProtocol.setFailure(next == .failure)
        TomatoReaderProtocol.setLong(next == .longManual)
        mode = next
    }
}
#endif
