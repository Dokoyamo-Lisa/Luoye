import SwiftUI
import WebKit
import Observation

@MainActor @Observable
final class TomatoWebsite: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var status = "尚未打开官网"
    private(set) var loading = false
    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "924E4CC2-3781-4AE5-BA78-38296DAD4249")!)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"
        super.init(); webView.navigationDelegate = self; webView.uiDelegate = self
    }
    func open() {
        if webView.url == nil { webView.load(URLRequest(url: URL(string: "https://fanqienovel.com/")!)) }
    }
    func sync(to catalog: TomatoPublicCatalog) async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        await catalog.useCookies(cookies)
    }
    func logout(catalog: TomatoPublicCatalog) async {
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await catalog.useCookies([]); await catalog.clearSessionReadingCache(); status = "官网会话已清除"; webView.load(URLRequest(url: URL(string: "https://fanqienovel.com/")!))
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; status = "官网会话保存在本机" }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loading = false; status = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false; status = error.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, ["https", "http", "about"].contains(url.scheme ?? "") else { return .cancel }
        return .allow
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }; return nil
    }
}
private struct TomatoWebsiteHost: UIViewRepresentable {
    let website: TomatoWebsite
    func makeUIView(context: Context) -> WKWebView { website.open(); return website.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
struct TomatoWebsiteView: View {
    @Environment(TomatoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在官网页面中登录，完成后点“完成”。账号密码由官网处理，落叶不读取或保存密码。").font(.serif(12)).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity).background(Color.paper)
                if store.website.loading { ProgressView().frame(maxWidth: .infinity).padding(8) }
                TomatoWebsiteHost(website: store.website)
            }.navigationTitle("番茄官网登录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("官网首页") { store.website.webView.load(URLRequest(url: URL(string: "https://fanqienovel.com/")!)) } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { Task { await store.website.sync(to: store.catalog); dismiss() } } }
            }
        }.onDisappear { Task { await store.website.sync(to: store.catalog) } }
    }
}
