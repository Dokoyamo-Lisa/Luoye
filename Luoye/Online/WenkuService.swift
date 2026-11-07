import Foundation
import WebKit
import Observation
import CryptoKit

struct WenkuBook: Codable, Identifiable, Hashable {
    let id: Int
    var title: String
    var author: String
    var info: String
    var summary: String
    var cover: String?
    var tags: [String]?
}
struct WenkuChapterReference: Codable, Identifiable {
    let id: Int
    let title: String
    let volume: String
    let url: String
}
struct WenkuContentBlock: Codable {
    let kind: String
    let value: String
}
struct WenkuFacet: Codable, Identifiable, Hashable {
    var id: String { path }
    let name: String
    let group: String
    let path: String
}
struct WenkuPage: Codable {
    var title: String
    var text: String
    var login: Bool
    var challenge: Bool
    var books: [WenkuBook]
    var catalogue: String?
    var chapters: [WenkuChapterReference]
    var content: [WenkuContentBlock]
    var facets: [WenkuFacet]
    var shelfPages: [String]?
    var displayName: String?
}

enum WenkuFailure: LocalizedError {
    case login, challenge, busy, timeout, invalid, message(String)
    var errorDescription: String? {
        switch self {
        case .login: "请先登录轻小说文库账号。"
        case .challenge: "文库需要验证，请打开安全验证页面完成后重试。"
        case .busy: "正在连接文库，请稍后再试。"
        case .timeout: "文库连接超时，请检查网络后重试。"
        case .invalid: "文库页面未能识别，请稍后重试。"
        case .message(let text): text
        }
    }
}

/// 同一 WebKit 会话负责登录和页面请求，页面解析结果供原生界面使用。
@MainActor @Observable
final class WenkuService: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    @ObservationIgnored lazy var backgroundService = WenkuService()
    var authenticated = false
    var accountKey: String?
    var username = UserDefaults.standard.string(forKey: "wenku.username") ?? ""
    var checking = false
    @ObservationIgnored private var continuation: CheckedContinuation<WenkuPage, Error>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var accepting = false
    @ObservationIgnored private var lastRequest = Date.distantPast
    @ObservationIgnored private var lastSearch = Date.distantPast
    @ObservationIgnored private var baseURL = URL(string: "https://www.wenku8.net")!
    @ObservationIgnored private var requestToken = UUID()
    @ObservationIgnored private var extracting = false
    @ObservationIgnored private var activeNavigation: WKNavigation?
    @ObservationIgnored private var activeJob: UUID?
    @ObservationIgnored private var cancelledJobs = Set<UUID>()
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    private struct CachedPage: Codable { let savedAt: Date; let page: WenkuPage }
    @ObservationIgnored private var memoryPages: [String: CachedPage] = [:]
    private struct Job {
        let id: UUID
        let path: String
        let owner: String?
        let refresh: Bool
        let continuation: CheckedContinuation<WenkuPage, Error>
    }
    @ObservationIgnored private var jobs: [Job] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: "window.webkit.messageHandlers.wenkuReady.postMessage(location.href)", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakWenkuReady(self), name: "wenkuReady")
        webView.navigationDelegate = self
    }

    private func cacheKey(_ path: String) -> String { "page-v1|" + (accountKey ?? "anonymous") + "|" + path }

    func page(_ path: String, refresh: Bool = false, background: Bool = false) async throws -> WenkuPage {
        guard !checking else { throw WenkuFailure.busy }
        if background {
            await backgroundService.refreshSession()
            return try await backgroundService.page(path, refresh: refresh)
        }
        try Task.checkCancellation()
        let key = cacheKey(path)
        if !refresh {
            if let hit = memoryPages[key], Date().timeIntervalSince(hit.savedAt) < 120 { return hit.page }
            if let data = await FanhuaCache.shared.data(for: key), let hit = try? JSONDecoder().decode(CachedPage.self, from: data), Date().timeIntervalSince(hit.savedAt) < 120 {
                memoryPages[key] = hit
                return hit.page
            }
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { response in
                cleanupTask?.cancel()
                jobs.append(Job(id: id, path: path, owner: accountKey, refresh: refresh, continuation: response))
                if queue == nil { queue = Task { await self.runJobs() } }
            }
        } onCancel: { Task { @MainActor in self.cancelJob(id) } }
    }

    private func cancelJob(_ id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            let job = jobs.remove(at: index)
            job.continuation.resume(throwing: CancellationError())
        } else if activeJob == id {
            cancelledJobs.insert(id)
            finish(.failure(CancellationError()))
            webView.stopLoading()
        }
    }

    private func runJobs() async {
        while !jobs.isEmpty {
            let eligible = jobs.firstIndex {
                checking || $0.owner != accountKey || (!$0.refresh && memoryPages[cacheKey($0.path)].map { Date().timeIntervalSince($0.savedAt) < 120 } == true) || !$0.path.contains("/search.php") || Date().timeIntervalSince(lastSearch) >= 30
            }
            guard let index = eligible else { try? await Task.sleep(for: .milliseconds(150)); continue }
            let job = jobs.remove(at: index)
            activeJob = job.id
            do {
                guard !checking else { throw WenkuFailure.busy }
                guard job.owner == accountKey else { throw WenkuFailure.login }
                if !job.refresh, let hit = memoryPages[cacheKey(job.path)], Date().timeIntervalSince(hit.savedAt) < 120 {
                    job.continuation.resume(returning: hit.page)
                    activeJob = nil
                    continue
                }
                let delay = 0.9 - Date().timeIntervalSince(lastRequest)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                guard !cancelledJobs.contains(job.id) else { throw CancellationError() }
                lastRequest = .now
                if job.path.contains("/search.php") { lastSearch = .now }
                let started = Date()
                let page = try await navigate(job.path)
                await refreshSession()
                if authenticated, let name = page.displayName, !name.isEmpty { username = name }
                if page.challenge { throw WenkuFailure.challenge }
                if page.login { throw WenkuFailure.login }
                if page.title.contains("出现错误") {
                    let lines = page.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                    throw WenkuFailure.message(lines.first { $0.contains("搜索间隔") || $0.contains("两次搜索") || $0.contains("对不起") || $0.contains("请稍后") } ?? "文库暂时拒绝了这次查询，请稍后重试。")
                }
                let hit = CachedPage(savedAt: .now, page: page)
                let key = cacheKey(job.path)
                if memoryPages.count >= 48, let oldest = memoryPages.min(by: { $0.value.savedAt < $1.value.savedAt })?.key { memoryPages.removeValue(forKey: oldest) }
                memoryPages[key] = hit
                if let data = try? JSONEncoder().encode(hit) { await FanhuaCache.shared.store(data, for: key) }
                #if DEBUG
                print("WENKU_TIMING path=\(job.path) seconds=\(Date().timeIntervalSince(started)) books=\(page.books.count)")
                #endif
                job.continuation.resume(returning: page)
            } catch { job.continuation.resume(throwing: error) }
            cancelledJobs.remove(job.id)
            activeJob = nil
        }
        queue = nil
        cleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.queue == nil else { return }
            await self.clearPageCache()
        }
    }

    func clearResponseMemory() {
        memoryPages.removeAll()
        backgroundService.memoryPages.removeAll()
    }

    #if DEBUG
    func performanceProbe() async {
        do {
            _ = try await WenkuContentPolicy.ruleList(background: false)
            print("WENKU_AD_POLICY visible_rules_compiled=true")
            await backgroundService.refreshSession()
            let previousSearch = lastSearch
            lastSearch = .now
            let blocked = Task { try await self.page(Self.searchPath("性能检查", field: "articlename", page: 1), refresh: true) }
            await Task.yield()
            let background = Task { try await self.page("/modules/article/bookcase.php?classid=1", refresh: true, background: true) }
            let begin = Date()
            let path = "/modules/article/toplist.php?sort=lastupdate&page=1"
            let page = try await self.page(path, refresh: true)
            let foregroundSeconds = Date().timeIntervalSince(begin)
            blocked.cancel()
            _ = await blocked.result
            lastSearch = previousSearch
            let cachedBegin = Date()
            let cached = try await self.page(path)
            let cachedSeconds = Date().timeIntervalSince(cachedBegin)
            let back = try await background.value
            print("WENKU_PERF foreground_seconds=\(foregroundSeconds) cached_seconds=\(cachedSeconds) books=\(page.books.count) cached_books=\(cached.books.count) background_books=\(back.books.count) search_wait_did_not_block=\(foregroundSeconds < 29)")
        } catch { print("WENKU_PERF_ERROR \(error.localizedDescription)") }
    }
    #endif

    private func navigate(_ path: String) async throws -> WenkuPage {
        try await WenkuContentPolicy.install(on: webView, background: true)
        guard let url = URL(string: path, relativeTo: baseURL),
              Self.allowed(url) else { throw WenkuFailure.invalid }
        return try await waiting {
            self.activeNavigation = self.webView.load(URLRequest(url: url.absoluteURL))
        }
    }

    private func waiting(start: () -> Void) async throws -> WenkuPage {
        guard continuation == nil else { throw WenkuFailure.busy }
        return try await withCheckedThrowingContinuation { next in
            continuation = next
            requestToken = UUID()
            extracting = false
            accepting = true
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                #if DEBUG
                NSLog("Wenku navigation timeout")
                #endif
                self?.webView.stopLoading()
                self?.finish(.failure(WenkuFailure.timeout))
            }
            #if DEBUG
            NSLog("Wenku navigation start")
            #endif
            start()
        }
    }

    func login(username: String, password: String) async throws {
        guard !checking else { throw WenkuFailure.busy }
        checking = true
        defer { checking = false }
        await queue?.value
        let page = try await navigate("/login.php")
        if page.challenge { throw WenkuFailure.challenge }
        guard page.login else {
            await refreshSession()
            if authenticated { return }
            throw WenkuFailure.invalid
        }
        let result = try await waiting {
            Task { @MainActor in
                do {
                    // Arguments remain values; credentials are never written into source or logs.
                    _ = try await self.webView.callAsyncJavaScript("""
                    const u = document.querySelector('input[name=username]');
                    const p = document.querySelector('input[name=password]');
                    if (!u || !p || !p.form) throw Error('登录表单未找到');
                    u.value = username; p.value = password;
                    const remember = p.form.querySelector('[name=usecookie]');
                    if (remember) remember.value = '2592000';
                    p.form.requestSubmit();
                    """, arguments: ["username": username, "password": password], in: nil, contentWorld: .page)
                } catch { self.finish(.failure(error)) }
            }
        }
        await refreshSession()
        if result.challenge { throw WenkuFailure.challenge }
        guard authenticated else {
            let hint = result.text.split(separator: "\n").first { $0.contains("错误") || $0.contains("失败") || $0.contains("密码不") }
            throw WenkuFailure.message(hint.map(String.init) ?? "登录未成功，请检查用户名和密码。")
        }
        self.username = username
        UserDefaults.standard.set(username, forKey: "wenku.username")
    }

    func refreshSession() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let sessions = cookies.filter {
            ($0.domain == "wenku8.net" || $0.domain.hasSuffix(".wenku8.net") || $0.domain == "wenku8.com" || $0.domain.hasSuffix(".wenku8.com")) && $0.name == "jieqiUserInfo" && !$0.value.isEmpty && ($0.expiresDate == nil || $0.expiresDate! > .now)
        }
        authenticated = !sessions.isEmpty
        let identity: String?
        if let value = sessions.first?.value {
            var decoded = value
            for _ in 0..<3 { decoded = decoded.removingPercentEncoding ?? decoded }
            if let match = decoded.range(of: "jieqiUserId[^0-9]*[0-9]+", options: .regularExpression) {
                identity = "uid-" + decoded[match].filter(\.isNumber)
            } else { identity = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
        } else { identity = nil }
        if accountKey != identity { username = ""; accountKey = identity }
        if let session = sessions.first(where: { webView.url?.host?.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == true }) ?? sessions.first {
            let domain = session.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            baseURL = URL(string: "https://www." + domain.replacingOccurrences(of: "www.", with: "")) ?? baseURL
        }
    }

    func clearPageCache() async {
        await webView.configuration.websiteDataStore.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache], modifiedSince: .distantPast)
    }

    func logout() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await queue?.value
        memoryPages.removeAll()
        backgroundService.memoryPages.removeAll()
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        authenticated = false
        accountKey = nil
        username = ""
    }

    private func finish(_ result: Result<WenkuPage, Error>) {
        guard let next = continuation else { return }
        continuation = nil
        accepting = false
        extracting = false
        timeoutTask?.cancel()
        timeoutTask = nil
        next.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation || checking else { return }
        extractPage()
    }

    func documentReady(_ url: String) {
        guard let value = URL(string: url), Self.allowed(value), webView.url?.absoluteString == url else { return }
        extractPage()
    }

    private func extractPage() {
        guard accepting, !extracting else { return }
        extracting = true
        let token = requestToken
        Task { @MainActor in
            do {
                guard let json = try await webView.evaluateJavaScript(Self.extraction) as? String,
                      let data = json.data(using: .utf8) else { throw WenkuFailure.invalid }
                guard token == requestToken, accepting else { return }
                let page = try JSONDecoder().decode(WenkuPage.self, from: data)
                finish(.success(page))
                webView.stopLoading()
            } catch {
                guard token == requestToken else { return }
                finish(.failure(error))
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }
    private func navigationFailed(_ error: Error) {
        let value = error as NSError
        if value.code == NSURLErrorCancelled || (value.domain == "WebKitErrorDomain" && value.code == 102) { return }
        finish(.failure(error))
    }
    static func allowed(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return ["wenku8.net", "wenku8.com"].contains(host) || host.hasSuffix(".wenku8.net") || host.hasSuffix(".wenku8.com")
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        guard Self.allowed(url) || (action.targetFrame?.isMainFrame == false && url.host == "challenges.cloudflare.com") else { return .cancel }
        if url.scheme == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            c.scheme = "https"
            var request = action.request
            request.url = c.url
            activeNavigation = webView.load(request)
            return .cancel
        }
        return url.scheme == "https" ? .allow : .cancel
    }

    static func searchPath(_ query: String, field: String, page: Int) -> String {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let bytes = query.data(using: encoding) ?? Data(query.utf8)
        let escaped = bytes.map { String(format: "%%%02X", $0) }.joined()
        if field == "tag" { return "/modules/article/tags.php?t=\(escaped)&page=\(page)" }
        return "/modules/article/search.php?searchtype=\(field)&searchkey=\(escaped)&page=\(page)"
    }

    static let extraction = #"""
    (() => {
      const text = document.body?.innerText || '';
      const bookRoot = document.querySelector('#content') || document.querySelector('#centers') || document.body;
      const anchors = [...bookRoot.querySelectorAll('a[href]')];
      const seen = new Set(); const books = [];
      // 一个列表里的许多链接会共用祖先节点；每个祖先只扫描一次书籍 ID。
      const parentBookCounts = new WeakMap();
      const bookCountIn = (parent) => {
        if (parentBookCounts.has(parent)) return parentBookCounts.get(parent);
        const ids = new Set();
        for (const link of parent.querySelectorAll('a[href]')) {
          const id = link.href.match(/\/book\/(\d+)\.htm/)?.[1];
          if (id) ids.add(id);
          if (ids.size > 1) break;
        }
        parentBookCounts.set(parent, ids.size);
        return ids.size;
      };
      for (const a of anchors) {
        const url = new URL(a.href, location.href);
        const match = url.pathname.match(/^\/book\/(\d+)\.htm$/);
        const aid = match?.[1] || url.searchParams.get('aid');
        const title = (a.getAttribute('title') || a.innerText || '').trim();
        if (!aid || !title || /^\d+$/.test(title) || seen.has(aid)) continue;
        seen.add(aid);
        let box = a.parentElement;
        if (location.pathname.endsWith('bookcase.php')) {
          box = a.closest('tr') || box;
        } else {
          for (let parent = box.parentElement; parent && parent !== document.body; parent = parent.parentElement) {
            if (bookCountIn(parent) > 1) break;
            box = parent;
            if (parent.id === 'content') break;
          }
        }
        const paragraphs = [...box.querySelectorAll('p')].map(p => p.innerText.trim());
        const body = box.innerText;
        const author = (paragraphs.find(p => p.includes('作者:') || p.includes('作者：')) || body.match(/作者[：:]\s*([^\n/]+)/)?.[0] || '').replace(/^.*?作者[：:]\s*/, '').split('/')[0];
        const image = box.querySelector('img[src*=image]') || box.querySelector('img');
        const imageURL = image ? new URL(image.getAttribute('src'), location.href).href.replace(/^http:/,'https:') : null;
        const shelfAuthor = box.querySelector('a[href*=authorarticle]')?.innerText.trim() || (location.pathname.endsWith('bookcase.php') ? box.querySelectorAll('td')[1]?.innerText.trim() : '');
        books.push({id:Number(aid), title, author:author || shelfAuthor || '', info:paragraphs.find(p => /更新|字数|连载|完结/.test(p)) || '', summary:(paragraphs.find(p => /简介[：:]/.test(p)) || '').replace(/^简介[：:]\s*/, ''), cover:imageURL, tags:(paragraphs.find(p => /Tags[:：]/.test(p)) || '').replace(/^.*?Tags[:：]\s*/,'').split(/\s+/).filter(Boolean)});
      }
      const detailID = location.pathname.match(/^\/book\/(\d+)\.htm$/)?.[1];
      if (detailID) {
        const content = document.querySelector('#content') || document.body;
        const heading = content.querySelector('h1') || content.querySelector('td span b') || content.querySelector('b');
        const title = heading?.innerText.trim() || document.title.split(' - ')[0];
        const spans = [...content.querySelectorAll('span')].map(s => s.innerText.trim());
        const summary = spans.filter(t => t.length > 40 && !/首页|用户登录|小说作者|文库分类/.test(t)).sort((a,b) => b.length-a.length)[0] || '';
        const cover = [...content.querySelectorAll('img')].find(i => /image|cover/.test(i.src))?.src.replace(/^http:/,'https:') || null;
        const author = text.match(/小说作者[：:]\s*([^\s]+)/)?.[1] || '';
        const existing = books.find(b => b.id === Number(detailID));
        const tags = (spans.find(t => /^作品Tags[:：]/.test(t)) || '').replace(/^作品Tags[:：]\s*/,'').split(/\s+/).filter(Boolean);
        if (existing) Object.assign(existing, {title, author, summary, cover, tags});
        else books.unshift({id:Number(detailID), title, author, info:'', summary, cover, tags});
        const own = books.find(b => b.id === Number(detailID));
        books.splice(0, books.length, own);
      }
      const catalogue = anchors.find(a => /\/novel\/\d+\/\d+\/index\.htm/.test(a.href))?.href || null;
      let volume = ''; const chapters = []; const chapterIDs = new Set();
      const rows = document.querySelectorAll('td.vcss, td.ccss');
      for (const td of rows) {
        if (td.classList.contains('vcss')) { volume = td.innerText.trim(); continue; }
        const a = td.querySelector('a[href]');
        const match = a?.href.match(/\/novel\/\d+\/\d+\/(\d+)\.htm/);
        if (!match || chapterIDs.has(match[1])) continue;
        chapterIDs.add(match[1]);
        chapters.push({id:Number(match[1]), title:a.innerText.trim(), volume, url:a.href.replace(/^http:/,'https:')});
      }
      const content = [];
      if (/\/novel\/\d+\/\d+\/\d+\.htm$/.test(location.pathname)) {
        const root = document.querySelector('#content')?.cloneNode(true);
        if (root) {
          root.querySelectorAll('script,style,iframe,form,nav,ins,.ads,.ad').forEach(n => n.remove());
          root.querySelectorAll('br').forEach(n => n.replaceWith(document.createTextNode('\n')));
          function walk(node) {
            if (node.nodeType === 3) {
              for (const line of node.textContent.split(/\n/)) {
                const value = line.replace(/^[\s\u3000]+|[\s\u3000]+$/g,'');
                if (value) content.push({kind:'text',value});
              }
            } else if (node.nodeName === 'IMG') {
              const image = new URL(node.getAttribute('src') || '', location.href);
              if (/^https?:$/.test(image.protocol)) content.push({kind:'image',value:image.href.replace(/^http:/,'https:')});
            } else { node.childNodes.forEach(walk); }
          }
          walk(root);
        }
      }
      const facets = []; const facetIDs = new Set();
      for (const a of document.querySelectorAll('#left a[href], #content a[href], a[href*="sort=anime"], a[href*="fullflag=1"]')) {
        const u = new URL(a.href, location.href); let group = '';
        if (u.searchParams.has('page')) continue;
        if (u.pathname.endsWith('articlelist.php') && u.searchParams.has('class')) group = '文库分类';
        if (u.pathname.endsWith('tags.php') && u.searchParams.has('t')) {
          group = '作品标签';
          let node = a;
          while (node && node.id !== 'left') {
            for (let sibling = node.previousSibling; sibling; sibling = sibling.previousSibling) {
              const match = sibling.textContent?.trim().match(/(日常系|幻想系|黑深残|人物属性类|特殊属性类).*?Tags/);
              if (match) { group = match[1]; break; }
            }
            if (group !== '作品标签') break;
            node = node.parentElement;
          }
        }
        if (u.pathname.endsWith('toplist.php') && u.searchParams.has('sort')) group = '排行榜';
        if (u.searchParams.get('sort') === 'anime' || u.searchParams.get('fullflag') === '1') group = '作品筛选';
        if (/\/zt\/sugoi\/\d+\.php/.test(u.pathname)) group = '年度榜单';
        const name = a.innerText.trim(); const path = u.pathname + u.search;
        if (group && name && !/^(?:\d+|[<>«»]+|下一页|上一页|首页|尾页)$/.test(name) && !facetIDs.has(path) && !/更多|推荐本书/.test(name)) {
          facetIDs.add(path); facets.push({name,group,path});
        }
      }
      const shelfPages = [...document.querySelectorAll('.pages a[href], .pagelink a[href], #pagelink a[href]')].map(a => new URL(a.href,location.href)).filter(u => u.pathname.endsWith('bookcase.php')).map(u => u.pathname + u.search);
      const displayName = text.match(/欢迎您[，,]\s*([^\s\[]+)/)?.[1] || null;
      return JSON.stringify({title:document.title, text, login:!!document.querySelector('input[name=password]'), challenge:/just a moment|attention required|security verification/i.test(document.title) || /you have been blocked|请完成人机验证/i.test(text), books, catalogue, chapters, content, facets, shelfPages, displayName});
    })()
    """#
}

@MainActor private final class WeakWenkuReady: NSObject, WKScriptMessageHandler {
    weak var owner: WenkuService?
    init(_ owner: WenkuService) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.frameInfo.isMainFrame, let url = message.body as? String { owner?.documentReady(url) }
    }
}
