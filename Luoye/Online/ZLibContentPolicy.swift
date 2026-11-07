import WebKit

/// 限于 Z-Library 网页通道；拦截第三方广告与统计脚本，保留登录与安全验证所需资源。
@MainActor enum ZLibContentPolicy {
    private static var compiled: [Bool: Task<WKContentRuleList, Error>] = [:]

    static func ruleList(background: Bool) async throws -> WKContentRuleList {
        if let task = compiled[background] { return try await task.value }
        let task = Task { @MainActor in
            let identifier = background ? "Fanhua.ZLib.Background.NoAds.v1" : "Fanhua.ZLib.Verification.NoAds.v1"
            guard let value = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedRules(background: background)
            ) else {
                throw NSError(domain: "FanhuaContentPolicy", code: 2)
            }
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
            // 默认拦截第三方无用资源，仅放行原站、CDN 和安全验证域名
            ["trigger": ["url-filter": ".*", "load-type": ["third-party"]], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*z-lib\\.sk/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*z-library\\.sk/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*1lib\\.sk/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*cdn-zlib\\.sk/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*ncdn\\.ec/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*diamwall\\.com/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https://challenges\\.cloudflare\\.com/"], "action": ["type": "ignore-previous-rules"]],
            // 明确阻断统计与广告追踪器
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*yadro\\.ru/"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*propellerads\\."], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*googlesyndication\\.com/"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https?://([a-z0-9-]+\\.)*doubleclick\\.net/"], "action": ["type": "block"]],
            [
                "trigger": ["url-filter": ".*", "if-domain": ["*z-lib.sk", "*z-library.sk"]],
                "action": ["type": "css-display-none", "selector": "img[src*='yadro.ru'],.advertisement,ins.adsbygoogle,#ads,#ad-banner"]
            ]
        ]
        if background {
            // 后台通道仅需 HTML 与核心脚本，封面图片由原生并发缓存通道加载
            rules.append([
                "trigger": ["url-filter": ".*", "resource-type": ["image", "media", "font"]],
                "action": ["type": "block"]
            ])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
