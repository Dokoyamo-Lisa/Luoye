import SwiftUI

/// Explicit debug-only launch fixture using the production discovery view and a private offline session.
struct TomatoOfflineVerificationHost: ViewModifier {
    #if DEBUG
    @State private var presented = false
    func body(content: Content) -> some View {
        content.sheet(isPresented: $presented) { TomatoOfflineFixtureView() }
            .task { if ProcessInfo.processInfo.arguments.contains("--show-tomato-offline-fixture") { presented = true } }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
#if DEBUG
private final class TomatoOfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
private struct TomatoOfflineFixtureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store: TomatoStore?
    @State private var directory: URL?
    @State private var session: URLSession?
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                if let store { TomatoDiscoverContent().environment(store).padding(20) }
                else if let failure { Text(failure) }
                else { ProgressView() }
            }.background(Color.paper).navigationTitle("断网推荐缓存验证").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task {
            do {
                let root = FileManager.default.temporaryDirectory.appending(path: "tomato-offline-ui-fixture-" + UUID().uuidString)
                directory = root
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let books = [TomatoBook(id: "7654593151348247614", title: "断网仍可见的缓存推荐", author: "十二小时前缓存")]
                let file = root.appending(path: "home-home.json")
                try JSONEncoder().encode(books).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-43200)], ofItemAtPath: file.path)
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TomatoOfflineProtocol.self]
                let offline = URLSession(configuration: config); session = offline
                store = TomatoStore(catalog: TomatoPublicCatalog(session: offline, directory: root), favoritesFile: root.appending(path: "favorites.json"))
            } catch { failure = error.localizedDescription }
        }
        .onDisappear {
            session?.invalidateAndCancel()
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
#endif
