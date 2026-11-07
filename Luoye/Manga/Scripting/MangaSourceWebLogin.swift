import SwiftUI
import WebKit

struct MangaSourceWebLogin: View {
    @Environment(\.dismiss) private var dismiss
    let runtime: MangaScriptRuntime
    let url: URL
    let onSuccess: () -> Void
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SourceLoginWebView(runtime: runtime, url: url, onSuccess: { onSuccess(); dismiss() }, onError: { error = $0 })
                if let error { Text(error).font(.serif(12)).padding(10) }
            }
            .navigationTitle("漫画源登录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

private struct SourceLoginWebView: UIViewRepresentable {
    let runtime: MangaScriptRuntime
    let url: URL
    let onSuccess: () -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SourceLoginWebView
        var checking = false
        var complete = false
        init(parent: SourceLoginWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !checking, !complete else { return }
            checking = true
            Task {
                defer { checking = false }
                do {
                    let data = try await parent.runtime.call("__webLoginCheck", arguments: [webView.url?.absoluteString ?? "", webView.title ?? ""])
                    let success = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? Bool ?? false
                    guard success else { return }
                    let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    try await parent.runtime.importCookies(cookies)
                    _ = try await parent.runtime.call("__webLoginSuccess")
                    complete = true
                    parent.onSuccess()
                } catch { parent.onError(error.localizedDescription) }
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onError(error.localizedDescription) }
        }
    }
}
