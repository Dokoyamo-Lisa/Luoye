import WebKit

/// 限于文库网页通道；原生封面请求不受此规则影响。
@MainActor enum WenkuContentPolicy {
    private static var compiled: [Bool: Task<WKContentRuleList, Error>] = [:]
    static func ruleList(background: Bool) async throws -> WKContentRuleList {
        if let task = compiled[background] { return try await task.value }
        let task = Task { @MainActor in
            guard let value = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: background ? "Fanhua.Reader.NoAds.v1" : "Fanhua.Verification.NoAds.v1", encodedContentRuleList: encodedRules(background: background)) else { throw NSError(domain: "FanhuaContentPolicy", code: 1) }
            return value
        }
        compiled[background] = task
        do { return try await task.value }
        catch { compiled.removeValue(forKey: background); throw error }
    }
    static func install(on webView: WKWebView, background: Bool) async throws {
        let rules = try await ruleList(background: background)
        webView.configuration.userContentController.removeAllContentRuleLists()
        webView.configuration.userContentController.add(rules)
    }
    static func encodedRules(background: Bool) -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*", "load-type": ["third-party"]], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*wenku8\\.net/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*wenku8\\.com/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https://challenges\\.cloudflare\\.com/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*777743\\.xyz/"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*444495\\.xyz/"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*", "if-domain": ["*wenku8.net", "*wenku8.com"]], "action": ["type": "css-display-none", "selector": "a[href*='444495.xyz'],a[href*='777743.xyz'],img[src*='777743.xyz'],img[src^='http']:not([src*='wenku8.']):not([src*='challenges.cloudflare.com']),.advertisement,ins.adsbygoogle,#ads,#ad-banner"]]
        ]
        if background {
            // 隐藏取数页面只需要 HTML 和必要脚本，封面由原生图片通道加载。
            rules.append(["trigger": ["url-filter": ".*", "resource-type": ["image", "media", "font"]], "action": ["type": "block"]])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
