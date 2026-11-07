import Foundation
import WebKit
import Observation
import CryptoKit

enum BookSource: String, Codable, CaseIterable, Hashable, Identifiable {
    case wenku8
    case zlib
    case tomato

    static var zlibrary: BookSource { .zlib }
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wenku8: "轻小说文库"
        case .zlib: "Z-Library"
        case .tomato: "番茄小说"
        }
    }

    var title: String { displayName }

    var badgeText: String {
        switch self {
        case .wenku8: "WENKU8"
        case .zlib: "Z-LIB"
        case .tomato: "TOMATO"
        }
    }
}

struct ZLibBook: Codable, Identifiable, Hashable {
    /// 原站书籍 ID（按字符串处理，避免与 Wenku8 Int ID 冲突）
    let id: String
    var title: String
    var author: String
    var authorPath: String?
    var publisher: String
    var year: String
    var language: String
    var pages: String
    var isbn: String
    var extensionName: String
    var filesize: String
    var rating: String
    var summary: String
    var cover: String?
    var path: String
    var downloadPath: String?
    var categoryName: String?
    var categoryPath: String?
    var downloadedAt: String?

    var sourceKey: String { "zlib:\(id)" }

    /// 简短信息行，如 "EPUB · 2.16 MB · Chinese · 2019"
    var briefInfo: String {
        var parts: [String] = []
        if !extensionName.isEmpty { parts.append(extensionName.uppercased()) }
        if !filesize.isEmpty { parts.append(filesize) }
        if !language.isEmpty { parts.append(Self.localizedLanguage(language)) }
        if !year.isEmpty, year != "0" { parts.append(year) }
        return parts.joined(separator: " · ")
    }

    static func localizedLanguage(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chinese", "zh", "zho", "chi": return "中文"
        case "traditional chinese", "tw", "zh-tw", "zh-hk": return "繁体中文"
        case "english", "en", "eng": return "英语"
        case "japanese", "ja", "jpn": return "日语"
        case "french", "fr", "fre", "fra": return "法语"
        case "german", "de", "ger", "deu": return "德语"
        case "russian", "ru", "rus": return "俄语"
        case "spanish", "es", "spa": return "西班牙语"
        case "korean", "ko", "kor": return "韩语"
        case "italian", "it", "ita": return "意大利语"
        case "portuguese", "pt", "por": return "葡萄牙语"
        default: return raw
        }
    }
}

struct ZLibFormatOption: Codable, Identifiable, Hashable {
    let id: String
    var extensionName: String
    var filesize: String
    var downloadPath: String?
    var isLowQuality: Bool
    var isPrimary: Bool

    var isSupportedByReader: Bool {
        BookImporter.isSupported(extensionName: extensionName)
    }

    var displayLabel: String {
        let ext = extensionName.isEmpty ? "未知格式" : extensionName.uppercased()
        if filesize.isEmpty { return ext }
        return "\(ext) · \(filesize)"
    }
}

struct ZLibBooklist: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var author: String
    var count: Int
    var views: String
    var description: String
    var path: String
}

struct ZLibFacet: Codable, Identifiable, Hashable {
    var id: String { path }
    let name: String
    let group: String
    let count: Int?
    let path: String
}

struct ZLibQuota: Codable, Hashable {
    let used: Int
    let limit: Int
    var resetHint: String

    var remaining: Int { max(0, limit - used) }
    var isExhausted: Bool { limit > 0 && used >= limit }
    var summaryText: String {
        if limit > 0 {
            let base = "今日已用 \(used) / \(limit) 次（剩余 \(remaining) 次）"
            return resetHint.isEmpty ? base : "\(base) · \(resetHint)"
        }
        return resetHint.isEmpty ? "今日已下载 \(used) 次" : "今日已下载 \(used) 次 · \(resetHint)"
    }
}

struct ZLibSearchFilter: Equatable, Hashable {
    var exact: Bool = false
    var language: String = ""
    var extensionName: String = ""
    var yearFrom: Int? = nil
    var yearTo: Int? = nil

    var isActive: Bool {
        exact || !language.isEmpty || !extensionName.isEmpty || yearFrom != nil || yearTo != nil
    }

    var summaryLabel: String {
        var parts: [String] = []
        if !language.isEmpty { parts.append(ZLibBook.localizedLanguage(language)) }
        if !extensionName.isEmpty { parts.append(extensionName.uppercased()) }
        if let from = yearFrom, let to = yearTo { parts.append("\(from)-\(to)") }
        else if let from = yearFrom { parts.append("\(from)年后") }
        else if let to = yearTo { parts.append("\(to)年前") }
        if exact { parts.append("精确") }
        return parts.isEmpty ? "筛选" : parts.joined(separator: " · ")
    }
}

struct ZLibPage: Codable {
    var title: String
    var text: String
    var login: Bool
    var challenge: Bool
    var notFound: Bool
    var quotaExceeded: Bool
    var books: [ZLibBook]
    var relatedBooks: [ZLibBook]
    var formats: [ZLibFormatOption]
    var booklists: [ZLibBooklist]
    var facets: [ZLibFacet]
    var currentPage: Int
    var totalPages: Int
    var hasNextPage: Bool
    var displayName: String?
    var email: String?
    var userId: String?
    var isFavorite: Bool
    var quota: ZLibQuota?
}

enum ZLibFailure: LocalizedError {
    case login
    case challenge
    case quotaExceeded(String)
    case busy
    case timeout
    case notFound
    case invalid
    case message(String)

    var errorDescription: String? {
        switch self {
        case .login:
            "请先登录 Z-Library 账号。"
        case .challenge:
            "网站需要完成安全验证，请打开验证页面完成后重试。"
        case .quotaExceeded(let hint):
            hint.isEmpty ? "今日下载额度已用完，请等待额度重置后再试。" : "今日下载额度已用完（\(hint)）。"
        case .busy:
            "正在连接 Z-Library，请稍候再试。"
        case .timeout:
            "连接 Z-Library 超时，请检查网络后重试。"
        case .notFound:
            "未找到对应的页面或书目。"
        case .invalid:
            "页面内容暂时无法识别，请稍后重试。"
        case .message(let text):
            text
        }
    }
}

/// Z-Library 独立会话与数据解析服务，与 Wenku8 会话完全隔离。
@MainActor @Observable
final class ZLibService: NSObject, WKNavigationDelegate {
    nonisolated static let dataStoreIdentifier = UUID(uuidString: "9A6C4E12-7B3D-4F80-A51E-2D8B9C7F6041")!
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    let webView: WKWebView
    @ObservationIgnored lazy var backgroundService = ZLibService(isBackgroundInstance: true)

    var authenticated = false
    var accountKey: String?
    var username = UserDefaults.standard.string(forKey: "zlib.username") ?? ""
    var email = UserDefaults.standard.string(forKey: "zlib.email") ?? ""
    var quota: ZLibQuota?
    var checking = false

    @ObservationIgnored private let isBackgroundInstance: Bool
    @ObservationIgnored private(set) var baseURL = URL(string: "https://z-lib.sk")!
    @ObservationIgnored private var originReady = false
    @ObservationIgnored private var continuation: CheckedContinuation<ZLibPage, Error>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var accepting = false
    @ObservationIgnored private var lastRequest = Date.distantPast
    @ObservationIgnored private var requestToken = UUID()
    @ObservationIgnored private var activeNavigation: WKNavigation?
    @ObservationIgnored private var activeJob: UUID?
    @ObservationIgnored private var cancelledJobs = Set<UUID>()
    @ObservationIgnored private var inFlightPages: [String: [CheckedContinuation<ZLibPage, Error>]] = [:]

    private struct CachedPage: Codable {
        let savedAt: Date
        let page: ZLibPage
    }
    @ObservationIgnored private var memoryPages: [String: CachedPage] = [:]

    private struct Job {
        let id: UUID
        let path: String
        let owner: String?
        let refresh: Bool
        let continuation: CheckedContinuation<ZLibPage, Error>
    }
    @ObservationIgnored private var jobs: [Job] = []

    init(isBackgroundInstance: Bool = false) {
        self.isBackgroundInstance = isBackgroundInstance
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreIdentifier)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.cachedExtractionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 852), configuration: configuration)
        webView.customUserAgent = Self.userAgent
        super.init()
        webView.navigationDelegate = self
    }

    private func cacheKey(_ path: String) -> String {
        "zlib-page-v1|" + (accountKey ?? "anonymous") + "|" + path
    }

    // MARK: - Page Fetching & Coalescing

    func page(_ path: String, refresh: Bool = false, background: Bool = false) async throws -> ZLibPage {
        guard !checking else { throw ZLibFailure.busy }
        if background && !isBackgroundInstance {
            await backgroundService.refreshSession()
            return try await backgroundService.page(path, refresh: refresh, background: false)
        }
        try Task.checkCancellation()
        let key = cacheKey(path)
        if !refresh {
            if let hit = memoryPages[key], Date().timeIntervalSince(hit.savedAt) < 180 {
                return hit.page
            }
            if let data = await FanhuaCache.shared.data(for: key),
               let hit = try? JSONDecoder().decode(CachedPage.self, from: data),
               Date().timeIntervalSince(hit.savedAt) < 180 {
                memoryPages[key] = hit
                return hit.page
            }
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { response in
                if !refresh, inFlightPages[key] != nil {
                    inFlightPages[key]?.append(response)
                    return
                }
                if !refresh {
                    inFlightPages[key] = []
                }
                jobs.append(Job(id: id, path: path, owner: accountKey, refresh: refresh, continuation: response))
                if queue == nil {
                    queue = Task { await self.runJobs() }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelJob(id) }
        }
    }

    private func cancelJob(_ id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            let job = jobs.remove(at: index)
            let key = cacheKey(job.path)
            let followers = inFlightPages.removeValue(forKey: key) ?? []
            job.continuation.resume(throwing: CancellationError())
            for follower in followers {
                follower.resume(throwing: CancellationError())
            }
        } else if activeJob == id {
            cancelledJobs.insert(id)
            finishNavigation(.failure(CancellationError()))
            webView.stopLoading()
        }
    }

    private func runJobs() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            activeJob = job.id
            let key = cacheKey(job.path)
            do {
                guard !checking else { throw ZLibFailure.busy }
                guard job.owner == accountKey else { throw ZLibFailure.login }
                if !job.refresh, let hit = memoryPages[key], Date().timeIntervalSince(hit.savedAt) < 180 {
                    let followers = inFlightPages.removeValue(forKey: key) ?? []
                    job.continuation.resume(returning: hit.page)
                    for follower in followers { follower.resume(returning: hit.page) }
                    activeJob = nil
                    continue
                }
                let delay = 0.28 - Date().timeIntervalSince(lastRequest)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                guard !cancelledJobs.contains(job.id) else { throw CancellationError() }
                lastRequest = .now

                let started = Date()
                var page = try await fetchOrNavigate(job.path)
                guard !cancelledJobs.contains(job.id) else { throw CancellationError() }

                await refreshSession()
                applyUserMetadata(from: page)

                if page.challenge { throw ZLibFailure.challenge }
                if page.login { throw ZLibFailure.login }
                if page.notFound { throw ZLibFailure.notFound }
                if page.quotaExceeded {
                    throw ZLibFailure.quotaExceeded(page.quota?.resetHint ?? "")
                }

                // 若是书籍详情页，顺带拉取该书的全部可用格式/版本列表
                if job.path.hasPrefix("/book/"), let primary = page.books.first {
                    if let extraFormats = try? await fetchBookFormats(bookId: primary.id, primaryBook: primary) {
                        page.formats = extraFormats
                    }
                }

                let hit = CachedPage(savedAt: .now, page: page)
                if memoryPages.count >= 64,
                   let oldest = memoryPages.min(by: { $0.value.savedAt < $1.value.savedAt })?.key {
                    memoryPages.removeValue(forKey: oldest)
                }
                memoryPages[key] = hit
                if let data = try? JSONEncoder().encode(hit) {
                    await FanhuaCache.shared.store(data, for: key)
                }
                #if DEBUG
                print("ZLIB_TIMING path=\(job.path) seconds=\(String(format: "%.3f", Date().timeIntervalSince(started))) books=\(page.books.count)")
                #endif

                let followers = inFlightPages.removeValue(forKey: key) ?? []
                job.continuation.resume(returning: page)
                for follower in followers { follower.resume(returning: page) }
            } catch {
                let followers = inFlightPages.removeValue(forKey: key) ?? []
                job.continuation.resume(throwing: error)
                for follower in followers { follower.resume(throwing: error) }
            }
            cancelledJobs.remove(job.id)
            activeJob = nil
        }
        queue = nil
    }

    private func applyUserMetadata(from page: ZLibPage) {
        if let q = page.quota {
            self.quota = q
            if !isBackgroundInstance {
                backgroundService.quota = q
            }
        }
        if authenticated {
            if let name = page.displayName, !name.isEmpty {
                username = name
                UserDefaults.standard.set(name, forKey: "zlib.username")
            }
            if let mail = page.email, !mail.isEmpty {
                email = mail
                UserDefaults.standard.set(mail, forKey: "zlib.email")
                if username.isEmpty {
                    username = mail.components(separatedBy: "@").first ?? mail
                }
            }
        }
    }

    // MARK: - Transport (Fast Same-Origin Fetch + Challenge Navigation Fallback)

    private func ensureOriginLoaded() async throws {
        if originReady, let currentHost = webView.url?.host, Self.allowed(host: currentHost) {
            return
        }
        _ = try await navigate("/")
        originReady = true
    }

    private func fetchOrNavigate(_ path: String) async throws -> ZLibPage {
        try await ZLibContentPolicy.install(on: webView, background: true)
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              Self.allowed(url) else {
            throw ZLibFailure.invalid
        }
        if originReady, let currentHost = webView.url?.host, Self.allowed(host: currentHost) {
            if var fastPage = try? await fetchInPage(url.absoluteString), !fastPage.challenge {
                if path == "/" && fastPage.books.isEmpty,
                   let popURL = URL(string: "/popular", relativeTo: baseURL)?.absoluteURL,
                   let popPage = try? await fetchInPage(popURL.absoluteString),
                   !popPage.books.isEmpty {
                    fastPage.books = popPage.books
                }
                return fastPage
            }
        }
        var navigated = try await navigate(path)
        if !navigated.challenge {
            originReady = true
            if path == "/" && navigated.books.isEmpty,
               let popURL = URL(string: "/popular", relativeTo: baseURL)?.absoluteURL,
               let popPage = try? await fetchInPage(popURL.absoluteString),
               !popPage.books.isEmpty {
                navigated.books = popPage.books
            }
        }
        return navigated
    }

    private func fetchInPage(_ absoluteURL: String) async throws -> ZLibPage {
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                Self.cachedInPageFetchScript,
                arguments: ["targetUrl": absoluteURL],
                in: nil,
                contentWorld: .page
            )
        } catch {
            // 旧页面或 WebKit 重建进程时可能尚未注入函数，保留原有提取路径。
            raw = try await webView.callAsyncJavaScript(
                Self.inPageFetchScript,
                arguments: ["targetUrl": absoluteURL],
                in: nil,
                contentWorld: .page
            )
        }
        guard let json = raw as? String,
              let data = json.data(using: .utf8) else {
            throw ZLibFailure.invalid
        }
        return try JSONDecoder().decode(ZLibPage.self, from: data)
    }

    private func navigate(_ path: String) async throws -> ZLibPage {
        try await ZLibContentPolicy.install(on: webView, background: true)
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              Self.allowed(url) else {
            throw ZLibFailure.invalid
        }
        guard continuation == nil else { throw ZLibFailure.busy }
        return try await withCheckedThrowingContinuation { next in
            continuation = next
            requestToken = UUID()
            accepting = true
            let token = requestToken
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(32))
                guard !Task.isCancelled, let self, self.requestToken == token else { return }
                self.webView.stopLoading()
                self.finishNavigation(.failure(ZLibFailure.timeout))
            }
            activeNavigation = webView.load(URLRequest(url: url))
            startSettleMonitor(token: token)
        }
    }

    private func startSettleMonitor(token: UUID) {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            let start = Date()
            var domAppearedAt: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(240))
                guard let self, self.accepting, self.requestToken == token else { return }
                let state = (try? await self.webView.evaluateJavaScript(
                    """
                    JSON.stringify({
                      ready: document.readyState || '',
                      title: document.title || '',
                      path: location.pathname || '',
                      hasWall: !!document.querySelector('#verification, iframe[src*="diamwall"], .cf-turnstile') || /diamwall|just a moment|security verification/i.test(document.title || '') || /diamwall/i.test(document.documentElement?.innerHTML || ''),
                      hasZLibDOM: !!document.querySelector('z-cover, z-bookcard, .details-book, #categoriesContainer, z-booklist, #loginForm, .dstats-row, #searchFieldx, .main-menu'),
                      itemCount: document.querySelectorAll('z-cover, z-bookcard, .details-book, #categoriesContainer .subcategory-name, z-booklist, #loginForm').length
                    })
                    """
                ) as? String) ?? ""
                guard let data = state.data(using: .utf8),
                      let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let ready = info["ready"] as? String ?? ""
                let hasWall = info["hasWall"] as? Bool ?? false
                let hasZLibDOM = info["hasZLibDOM"] as? Bool ?? false
                let itemCount = info["itemCount"] as? Int ?? 0
                let path = info["path"] as? String ?? ""

                if !hasWall && hasZLibDOM && (ready == "complete" || ready == "interactive") && !self.webView.isLoading {
                    if domAppearedAt == nil { domAppearedAt = Date() }
                    // 给首页或列表页动态挂载的 z-cover / z-bookcard 留出最多 1.2 秒渲染窗口
                    if itemCount == 0 && (path == "/" || path == "/popular") && Date().timeIntervalSince(domAppearedAt!) < 1.2 {
                        continue
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                    guard self.accepting, self.requestToken == token else { return }
                    await self.extractCurrentDocument(token: token)
                    return
                }
                if Date().timeIntervalSince(start) > 26 && hasWall {
                    await self.extractCurrentDocument(token: token)
                    return
                }
            }
        }
    }

    private func extractCurrentDocument(token: UUID) async {
        guard accepting, token == requestToken else { return }
        do {
            guard let json = try await webView.evaluateJavaScript(Self.currentDocumentExtractionScript) as? String,
                  let data = json.data(using: .utf8) else {
                throw ZLibFailure.invalid
            }
            guard accepting, token == requestToken else { return }
            let page = try JSONDecoder().decode(ZLibPage.self, from: data)
            finishNavigation(.success(page))
        } catch {
            guard accepting, token == requestToken else { return }
            finishNavigation(.failure(error))
        }
    }

    private func finishNavigation(_ result: Result<ZLibPage, Error>) {
        guard let next = continuation else { return }
        continuation = nil
        accepting = false
        timeoutTask?.cancel()
        timeoutTask = nil
        settleTask?.cancel()
        settleTask = nil
        next.resume(with: result)
    }

    // MARK: - Formats, Booklist Pagination & Favorites API

    func fetchBookFormats(bookId: String, primaryBook: ZLibBook) async throws -> [ZLibFormatOption] {
        var options: [ZLibFormatOption] = []
        if !primaryBook.extensionName.isEmpty {
            options.append(ZLibFormatOption(
                id: primaryBook.id,
                extensionName: primaryBook.extensionName.lowercased(),
                filesize: primaryBook.filesize,
                downloadPath: primaryBook.downloadPath,
                isLowQuality: false,
                isPrimary: true
            ))
        }
        guard bookId.allSatisfy(\.isNumber) else { return options }
        try await ensureOriginLoaded()
        let raw = try await webView.callAsyncJavaScript(
            """
            const r = await fetch('/papi/book/' + encodeURIComponent(bookId) + '/formats', {credentials: 'include'});
            return await r.text();
            """,
            arguments: ["bookId": bookId],
            in: nil,
            contentWorld: .page
        ) as? String

        if let text = raw, let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["books"] as? [[String: Any]] {
            for item in list {
                let idValue: String
                if let n = item["id"] as? Int { idValue = String(n) }
                else if let s = item["id"] as? String { idValue = s }
                else { continue }
                if options.contains(where: { $0.id == idValue }) { continue }
                let ext = (item["extension"] as? String ?? "").lowercased()
                let size = item["filesizeString"] as? String ?? ""
                let href = item["href"] as? String
                let lowQ = (item["isLowQuality"] as? Bool) ?? false
                options.append(ZLibFormatOption(
                    id: idValue,
                    extensionName: ext,
                    filesize: size,
                    downloadPath: href,
                    isLowQuality: lowQ,
                    isPrimary: false
                ))
            }
        }
        // 将阅读器支持的格式排在前面，方便直接阅读
        return options.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary {
                if lhs.isPrimary && lhs.isSupportedByReader { return true }
                if rhs.isPrimary && rhs.isSupportedByReader { return false }
            }
            if lhs.isSupportedByReader != rhs.isSupportedByReader {
                return lhs.isSupportedByReader
            }
            return false
        }
    }

    func fetchBooklistMorePage(booklistId: String, page: Int) async throws -> (books: [ZLibBook], hasNext: Bool) {
        try await ensureOriginLoaded()
        let raw = try await webView.callAsyncJavaScript(
            """
            const r = await fetch('/papi/booklist/' + encodeURIComponent(listId) + '/get-books/' + page, {
              method: 'POST',
              headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8', 'X-Requested-With': 'XMLHttpRequest'},
              body: 'order=date_saved&searchQuery=',
              credentials: 'include'
            });
            const j = await r.json();
            const books = (j.books || []).map(row => {
              const b = row.book || {};
              return {
                id: String(b.id || ''),
                title: String(b.title || '').trim(),
                author: String(b.author || '').trim(),
                authorPath: b.author ? '/author/' + encodeURIComponent(String(b.author).trim()) : null,
                publisher: String(b.publisher || '').trim(),
                year: b.year ? String(b.year) : '',
                language: String(b.language || '').trim(),
                pages: b.pages ? String(b.pages) : '',
                isbn: String(b.identifier || '').trim(),
                extensionName: String(b.extension || '').toLowerCase(),
                filesize: String(b.filesizeString || '').trim(),
                rating: String(b.interestScore || b.qualityScore || '').trim(),
                summary: String(b.description || '').replace(/<[^>]+>/g, ' ').replace(/\\s+/g, ' ').trim(),
                cover: b.cover ? String(b.cover).replace(/^http:/, 'https:') : null,
                path: String(b.href || ''),
                downloadPath: b.dl ? String(b.dl) : null,
                categoryName: null,
                categoryPath: null,
                downloadedAt: null
              };
            }).filter(b => b.id && b.title);
            return JSON.stringify({books, hasNext: !!(j.pagination && j.pagination.next)});
            """,
            arguments: ["listId": booklistId, "page": page],
            in: nil,
            contentWorld: .page
        ) as? String
        guard let json = raw, let data = json.data(using: .utf8) else {
            throw ZLibFailure.invalid
        }
        struct Payload: Decodable {
            let books: [ZLibBook]
            let hasNext: Bool
        }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        return (decoded.books, decoded.hasNext)
    }

    func setFavorite(bookId: String, favorite: Bool) async throws {
        guard authenticated else { throw ZLibFailure.login }
        try await ensureOriginLoaded()
        let raw = try await webView.callAsyncJavaScript(
            """
            const url = fav
              ? '/papi/my-library/book/' + encodeURIComponent(bookId)
              : '/papi/my-library/book/' + encodeURIComponent(bookId) + '/favorites';
            const r = await fetch(url, {method: fav ? 'PUT' : 'DELETE', credentials: 'include'});
            return r.status;
            """,
            arguments: ["bookId": bookId, "fav": favorite],
            in: nil,
            contentWorld: .page
        ) as? Int
        guard let status = raw, (200..<300).contains(status) else {
            throw ZLibFailure.message("未能更新收藏状态，请稍后重试。")
        }
        memoryPages.removeAll()
    }

    // MARK: - Authentication & Session Management

    func login(email: String, password: String) async throws {
        guard !checking else { throw ZLibFailure.busy }
        checking = true
        defer { checking = false }
        await queue?.value

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            throw ZLibFailure.message("请输入邮箱和密码。")
        }

        try await ensureOriginLoaded()
        // 凭据通过参数传入，绝不拼接到源码或写入任何日志
        let raw = try await webView.callAsyncJavaScript(
            """
            const body = new URLSearchParams({
              isModal: 'true',
              email: email,
              password: password,
              site_mode: 'books',
              action: 'login',
              isSingleLogin: '1',
              redirectUrl: '',
              gg_json_mode: '1'
            });
            const r = await fetch('/rpc.php', {
              method: 'POST',
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
                'X-Requested-With': 'XMLHttpRequest'
              },
              body: body.toString(),
              credentials: 'include'
            });
            const text = await r.text();
            return JSON.stringify({status: r.status, text});
            """,
            arguments: ["email": trimmedEmail, "password": password],
            in: nil,
            contentWorld: .page
        ) as? String

        guard let raw, let rawData = raw.data(using: .utf8),
              let wrapper = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let bodyText = wrapper["text"] as? String else {
            throw ZLibFailure.invalid
        }

        if bodyText.lowercased().contains("diamwall") || bodyText.lowercased().contains("just a moment") {
            throw ZLibFailure.challenge
        }

        if let bodyData = bodyText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            if let resp = json["response"] as? [String: Any] {
                if let validationError = resp["validationError"] as? Bool, validationError {
                    let msg = (resp["message"] as? String) ?? "邮箱或密码不正确，请检查后重试。"
                    throw ZLibFailure.message(Self.localizedLoginError(msg))
                }
                if let userId = resp["user_id"], let userKey = resp["user_key"] as? String, !userKey.isEmpty {
                    let uidStr = "\(userId)"
                    _ = try? await webView.callAsyncJavaScript(
                        """
                        document.cookie = 'remix_userid=' + encodeURIComponent(uid) + '; path=/; max-age=31536000; SameSite=Lax';
                        document.cookie = 'remix_userkey=' + encodeURIComponent(ukey) + '; path=/; max-age=31536000; SameSite=Lax';
                        """,
                        arguments: ["uid": uidStr, "ukey": userKey],
                        in: nil,
                        contentWorld: .page
                    )
                }
            }
            if let errors = json["errors"] as? [[String: Any]], let first = errors.first,
               let msg = first["message"] as? String, !msg.isEmpty {
                throw ZLibFailure.message(Self.localizedLoginError(msg))
            }
        }

        await refreshSession()
        guard authenticated else {
            throw ZLibFailure.message("登录未成功，请确认账号密码或完成安全验证后重试。")
        }

        self.email = trimmedEmail
        if self.username.isEmpty {
            self.username = trimmedEmail.components(separatedBy: "@").first ?? trimmedEmail
        }
        UserDefaults.standard.set(trimmedEmail, forKey: "zlib.email")
        UserDefaults.standard.set(self.username, forKey: "zlib.username")
        memoryPages.removeAll()
        backgroundService.memoryPages.removeAll()

        // 登录成功后刷新一次首页或下载页以读取用户昵称和今日下载额度
        if let profilePage = try? await fetchInPage(baseURL.appending(path: "users/downloads").absoluteString) {
            applyUserMetadata(from: profilePage)
        }
    }

    private static func localizedLoginError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("incorrect email or password") || lower.contains("wrong password") {
            return "邮箱或密码不正确，请核对后重试。"
        }
        if lower.contains("too many") || lower.contains("try again later") {
            return "登录尝试过于频繁，请稍后再试。"
        }
        if lower.contains("captcha") || lower.contains("verification") {
            return "需要完成安全验证，请点击下方安全验证入口。"
        }
        return raw
    }

    func refreshSession() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let validCookies = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let domainOK = domain == "z-lib.sk" || domain.hasSuffix(".z-lib.sk") || domain == "z-library.sk" || domain.hasSuffix(".z-library.sk") || domain == "1lib.sk" || domain.hasSuffix(".1lib.sk")
            let expiryOK = cookie.expiresDate == nil || cookie.expiresDate! > .now
            return domainOK && expiryOK && !cookie.value.isEmpty
        }

        let userIdCookie = validCookies.first { $0.name == "remix_userid" }
        let userKeyCookie = validCookies.first { $0.name == "remix_userkey" }

        let isSignedIn = userIdCookie != nil && userKeyCookie != nil
        authenticated = isSignedIn

        let newIdentity: String?
        if let uid = userIdCookie?.value, !uid.isEmpty, isSignedIn {
            newIdentity = "zlib-uid-" + uid
        } else if let ukey = userKeyCookie?.value, !ukey.isEmpty, isSignedIn {
            let hash = SHA256.hash(data: Data(ukey.utf8)).map { String(format: "%02x", $0) }.joined()
            newIdentity = "zlib-key-" + hash
        } else {
            newIdentity = nil
        }

        if accountKey != newIdentity {
            if newIdentity == nil {
                username = ""
                email = ""
                quota = nil
            }
            accountKey = newIdentity
            memoryPages.removeAll()
        }
    }

    func refreshQuotaIfNeeded() async {
        await refreshSession()
        guard authenticated else { return }
        if let page = try? await self.page("/users/downloads", refresh: true, background: true) {
            applyUserMetadata(from: page)
        }
    }

    func allSessionCookies() async -> [HTTPCookie] {
        await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
    }

    func clearResponseMemory() {
        memoryPages.removeAll()
        if !isBackgroundInstance {
            backgroundService.memoryPages.removeAll()
        }
    }

    func clearPageCache() async {
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
            modifiedSince: .distantPast
        )
    }

    func logout() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await queue?.value
        if originReady {
            _ = try? await webView.callAsyncJavaScript(
                "await fetch('/papi/user/logout', {method: 'POST', credentials: 'include'});",
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
        }
        memoryPages.removeAll()
        if !isBackgroundInstance {
            backgroundService.memoryPages.removeAll()
        }
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        originReady = false
        authenticated = false
        accountKey = nil
        username = ""
        email = ""
        quota = nil
        UserDefaults.standard.removeObject(forKey: "zlib.username")
        UserDefaults.standard.removeObject(forKey: "zlib.email")
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 由 startSettleMonitor 统一检测 DiamWall 验证与 DOM 挂载完成，避免在空白验证壳阶段提前提取。
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        let value = error as NSError
        if value.code == NSURLErrorCancelled || (value.domain == "WebKitErrorDomain" && value.code == 102) { return }
        finishNavigation(.failure(error))
    }

    static func allowed(host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "z-lib.sk" || lower.hasSuffix(".z-lib.sk")
            || lower == "z-library.sk" || lower.hasSuffix(".z-library.sk")
            || lower == "1lib.sk" || lower.hasSuffix(".1lib.sk")
    }

    static func allowed(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return allowed(host: host)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let host = url.host?.lowercased() ?? ""
        let isVerificationSubframe = action.targetFrame?.isMainFrame == false
            && (host == "challenges.cloudflare.com" || host.hasSuffix(".diamwall.com") || Self.allowed(host: host))
        guard Self.allowed(url) || isVerificationSubframe else { return .cancel }
        if url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            components.scheme = "https"
            var request = action.request
            request.url = components.url
            activeNavigation = webView.load(request)
            return .cancel
        }
        return url.scheme == "https" ? .allow : .cancel
    }

    // MARK: - Route Builders

    static func searchPath(query: String, filter: ZLibSearchFilter, page: Int) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        var items: [String] = []
        if filter.exact {
            items.append("e=1")
        }
        if let from = filter.yearFrom {
            items.append("yearFrom=\(from)")
        }
        if let to = filter.yearTo {
            items.append("yearTo=\(to)")
        }
        if !filter.language.isEmpty,
           let encodedLang = filter.language.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            items.append("languages%5B%5D=\(encodedLang)")
        }
        if !filter.extensionName.isEmpty,
           let encodedExt = filter.extensionName.uppercased().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            items.append("extensions%5B%5D=\(encodedExt)")
        }
        items.append("page=\(max(1, page))")
        let queryString = items.joined(separator: "&")
        return "/s/\(encodedQuery)?\(queryString)"
    }

    static func booklistsPath(order: String = "popular", query: String = "", page: Int = 1) -> String {
        var components = URLComponents()
        components.path = "/booklists"
        var items = [
            URLQueryItem(name: "order", value: order),
            URLQueryItem(name: "page", value: String(max(1, page)))
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "searchQuery", value: trimmed))
        }
        components.queryItems = items
        return components.string ?? "/booklists?page=\(page)"
    }

    // MARK: - JavaScript Extraction

    static let sharedExtractionFunction = #"""
    function extractZLibDocument(doc, rawUrl, statusCode) {
      const pageUrl = new URL(rawUrl || location.href, location.origin);
      const pathname = pageUrl.pathname;
      const title = (doc.title || '').trim();
      const bodyText = (doc.body?.innerText || '').trim();

      // 1. 严格区分验证页、登录页、404错误页、额度不足页
      const isChallenge = statusCode === 503 || statusCode === 513 || statusCode === 517
        || /diamwall|just a moment|attention required|security verification/i.test(title)
        || !!doc.querySelector('iframe#verification, iframe[src*="diamwall"], .cf-turnstile')
        || /you have been blocked|请完成人机验证/i.test(bodyText);

      const isLoginPage = /^\/(login|registration|passwordreminder)\b/i.test(pathname)
        || (!!doc.querySelector('#loginForm, form[data-action="login"]') && !doc.querySelector('z-bookcard, .details-book.cardBooks, .books-mosaic'));

      const isNotFound = statusCode === 404 || /^page not found$/i.test(title);
      const isQuotaExceeded = /daily limit reached|daily download limit|exceeded your daily|今日下载额度/i.test(bodyText)
        && !doc.querySelector('z-bookcard, .details-book.cardBooks');

      // 2. 提取用户信息与下载额度
      let userId = null;
      let email = null;
      let displayName = null;
      let quota = null;

      const scriptsText = [...doc.querySelectorAll('script:not([src])')].map(s => s.textContent || '').join('\n');
      const userMatch = scriptsText.match(/const\s+CurrentUser\s*=\s*new\s+User\((\{[\s\S]*?\})\)\s*;/);
      if (userMatch) {
        try {
          const u = JSON.parse(userMatch[1]);
          if (u && u.id) {
            userId = String(u.id);
            email = u.email ? String(u.email) : null;
            displayName = u.name ? String(u.name) : null;
          }
        } catch {}
      }
      const cardName = doc.querySelector('.user-card__name')?.textContent?.trim();
      if (cardName) displayName = cardName;

      // 从导航栏 .caret-scroll__tile 或 /users/downloads 的 .dstats-info 提取下载额度
      const dCountText = doc.querySelector('.dstats-info .d-count')?.textContent?.trim()
        || [...doc.querySelectorAll('.caret-scroll__tile .caret-scroll__title')].map(n => n.textContent.trim()).find(t => /^\d+\s*\/\s*\d+$/.test(t));
      const dResetText = doc.querySelector('.dstats-info .d-reset')?.textContent?.trim()
        || [...doc.querySelectorAll('.caret-scroll__tile .caret-scroll__desc')].map(n => n.textContent.trim()).filter(Boolean).join(' · ')
        || '';

      if (dCountText) {
        const parts = dCountText.split('/').map(s => parseInt(s.trim(), 10));
        if (parts.length === 2 && !isNaN(parts[0]) && !isNaN(parts[1])) {
          quota = { used: parts[0], limit: parts[1], resetHint: dResetText };
        }
      }

      if (isChallenge || isLoginPage || isNotFound) {
        return {
          title, text: bodyText.slice(0, 1500),
          login: isLoginPage, challenge: isChallenge, notFound: isNotFound, quotaExceeded: isQuotaExceeded,
          books: [], relatedBooks: [], formats: [], booklists: [], facets: [],
          currentPage: 1, totalPages: 1, hasNextPage: false,
          displayName, email, userId, isFavorite: false, quota
        };
      }

      const normCover = (src) => {
        if (!src) return null;
        try {
          const u = new URL(src, pageUrl.origin);
          if (!/^https?:$/.test(u.protocol)) return null;
          return u.href.replace(/^http:/, 'https:').replace('/covers100/', '/covers200/').replace('/covers150/', '/covers200/');
        } catch { return null; }
      };

      const normPath = (href) => {
        if (!href) return '';
        try {
          const u = new URL(href, pageUrl.origin);
          return u.pathname + u.search;
        } catch { return href; }
      };

      // 解析页面内 ZLibraryModelList JSON（书单详情页、收藏页等带有丰富元数据）
      const modelMap = new Map();
      const modelMatch = scriptsText.match(/new\s+ZLibraryModelList\((\[\{[\s\S]*?\}\])\)/);
      if (modelMatch) {
        try {
          const arr = JSON.parse(modelMatch[1]);
          for (const row of arr) {
            const b = row.book || row;
            if (b && b.id) modelMap.set(String(b.id), b);
          }
        } catch {}
      }

      const books = [];
      const relatedBooks = [];
      const formats = [];
      const seenBookIds = new Set();
      let isFavorite = false;

      // 3A. 若是书籍详情页 (/book/...)
      const detailRoot = doc.querySelector('.details-book.cardBooks');
      if (detailRoot) {
        const zcov = detailRoot.querySelector('z-cover');
        const id = String(detailRoot.getAttribute('data-book_id') || zcov?.getAttribute('id') || '').trim();
        const bookTitle = (detailRoot.querySelector('h1.book-title')?.textContent || zcov?.getAttribute('title') || '').trim();
        const authorAnchors = [...detailRoot.querySelectorAll('.authors a')];
        const author = authorAnchors.map(a => a.textContent.trim()).filter(Boolean).join(', ') || (zcov?.getAttribute('author') || '').trim();
        const authorPath = authorAnchors[0] ? normPath(authorAnchors[0].getAttribute('href')) : null;
        const cover = normCover(zcov?.querySelector('img')?.getAttribute('src') || zcov?.querySelector('img')?.getAttribute('data-src'));
        const descBox = doc.querySelector('#bookDescriptionBox');
        let summary = '';
        if (descBox) {
          const clone = descBox.cloneNode(true);
          clone.querySelectorAll('br, p').forEach(el => el.insertAdjacentText('afterend', '\n'));
          summary = (clone.textContent || '').split(/\n+/).map(s => s.trim()).filter(Boolean).join('\n\n');
        }
        const propVal = (cls) => (doc.querySelector('.bookDetailsBox .' + cls + ' .property_value')?.textContent || '').trim();
        const publisher = propVal('property_publisher');
        const year = propVal('property_year');
        const language = propVal('property_language');
        const pages = propVal('property_pages');
        const isbns = [...doc.querySelectorAll('.bookDetailsBox .property_isbn .property_value')].map(n => n.textContent.trim()).filter(Boolean);
        const isbn = [...new Set(isbns)].join(', ') || (zcov?.getAttribute('isbn') || '').trim();
        const catAnchor = doc.querySelector('.bookDetailsBox .property_categories .property_value a[href]');
        const categoryName = catAnchor?.textContent?.trim() || null;
        const categoryPath = catAnchor ? normPath(catAnchor.getAttribute('href')) : null;

        const fileText = propVal('property_file');
        let extensionName = '';
        let filesize = '';
        if (fileText) {
          const fParts = fileText.split(',').map(s => s.trim());
          extensionName = (fParts[0] || '').toLowerCase();
          filesize = fParts.slice(1).join(', ');
        }
        const dlBtn = detailRoot.querySelector('.book-details-button a.addDownloadedBook:not(.reader-link)');
        if (!extensionName && dlBtn) {
          extensionName = (dlBtn.querySelector('.book-property__extension')?.textContent || '').trim().toLowerCase();
        }
        const downloadPath = dlBtn ? normPath(dlBtn.getAttribute('href')) : null;
        const rating = (doc.querySelector('.book-rating-interest-score')?.textContent || '').trim();

        isFavorite = /MyLibraryBook\s*=\s*\{/.test(scriptsText)
          || !!detailRoot.querySelector('.zlibicon-mylibrary-fill, .zlibicon-heart-fill');

        if (id && bookTitle) {
          seenBookIds.add(id);
          books.push({
            id, title: bookTitle, author, authorPath,
            publisher, year, language, pages, isbn,
            extensionName, filesize, rating, summary,
            cover, path: pathname, downloadPath,
            categoryName, categoryPath, downloadedAt: null
          });
          if (extensionName) {
            formats.push({
              id, extensionName, filesize, downloadPath, isLowQuality: false, isPrimary: true
            });
          }
        }

        // 提取详情页底部的相关推荐书籍
        for (const a of doc.querySelectorAll('.books-mosaic a[href*="/book/"]')) {
          const cov = a.querySelector('z-cover');
          if (!cov) continue;
          const rid = String(cov.getAttribute('id') || '').trim();
          const rtitle = (cov.getAttribute('title') || '').trim();
          if (!rid || !rtitle || seenBookIds.has(rid)) continue;
          seenBookIds.add(rid);
          relatedBooks.push({
            id: rid,
            title: rtitle,
            author: (cov.getAttribute('author') || '').trim(),
            authorPath: null,
            publisher: '', year: '', language: '', pages: '',
            isbn: (cov.getAttribute('isbn') || '').trim(),
            extensionName: '', filesize: '', rating: '', summary: '',
            cover: normCover(cov.querySelector('img')?.getAttribute('src') || cov.querySelector('img')?.getAttribute('data-src')),
            path: normPath(a.getAttribute('href')),
            downloadPath: null, categoryName: null, categoryPath: null, downloadedAt: null
          });
        }
      }

      // 3B. 提取 <z-bookcard>（搜索结果、分类页、作者页、书单详情页、收藏页、下载页）
      if (!detailRoot) {
        for (const card of doc.querySelectorAll('z-bookcard')) {
          let id = String(card.getAttribute('id') || '').trim();
          const href = normPath(card.getAttribute('href'));
          if (!id && href) {
            const m = href.match(/^\/book\/([^\/]+)/);
            if (m) id = m[1];
          }
          const mInfo = modelMap.get(id) || {};
          const bTitle = (card.querySelector('[slot="title"]')?.textContent || mInfo.title || '').trim();
          if (!id || !bTitle || seenBookIds.has(id)) continue;
          seenBookIds.add(id);

          const bAuthor = (card.querySelector('[slot="author"]')?.textContent || mInfo.author || '').trim();
          const img = card.querySelector('img');
          const cover = normCover(img?.getAttribute('data-src') || img?.getAttribute('src') || mInfo.cover);
          const dl = normPath(card.getAttribute('download') || mInfo.dl || '');
          const publisher = (card.getAttribute('publisher') || mInfo.publisher || '').trim();
          const language = (card.getAttribute('language') || mInfo.language || '').trim();
          const year = String(card.getAttribute('year') || mInfo.year || '').trim();
          const extensionName = String(card.getAttribute('extension') || mInfo.extension || '').trim().toLowerCase();
          const filesize = String(card.getAttribute('filesize') || mInfo.filesizeString || '').trim();
          const rating = String(card.getAttribute('rating') || mInfo.interestScore || '').trim();
          const isbn = String(card.getAttribute('isbn') || mInfo.identifier || '').trim();
          const rawDesc = mInfo.description ? String(mInfo.description).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() : '';
          const note = (card.querySelector('[slot="note"]')?.textContent || '').trim();

          books.push({
            id, title: bTitle, author: bAuthor,
            authorPath: bAuthor ? '/author/' + encodeURIComponent(bAuthor) : null,
            publisher, year, language, pages: mInfo.pages ? String(mInfo.pages) : '',
            isbn, extensionName, filesize,
            rating: rating === '0.0' || rating === '0' ? '' : rating,
            summary: rawDesc || note,
            cover, path: href,
            downloadPath: dl || null,
            categoryName: null, categoryPath: null,
            downloadedAt: card.getAttribute('date') || null
          });
        }

        // 3C. 若无 <z-bookcard>，检查下载历史表格行 (.dstats-row)
        for (const row of doc.querySelectorAll('tr.dstats-row')) {
          const a = row.querySelector('a[href*="/book/"]');
          if (!a) continue;
          const href = normPath(a.getAttribute('href'));
          const m = href.match(/^\/book\/([^\/]+)/);
          const id = String(row.getAttribute('data-book_id') || m?.[1] || '').trim();
          const bTitle = (row.querySelector('.book-title')?.textContent || a.textContent || '').trim();
          if (!id || !bTitle || seenBookIds.has(id)) continue;
          seenBookIds.add(id);
          const dateStr = (row.querySelector('td.lg-w-120')?.textContent || '').trim();
          const authorStr = (row.querySelector('.book-author, i, .authors')?.textContent || '').trim();
          books.push({
            id, title: bTitle, author: authorStr, authorPath: null,
            publisher: '', year: '', language: '', pages: '', isbn: '',
            extensionName: '', filesize: '', rating: '', summary: '',
            cover: normCover(row.querySelector('img')?.getAttribute('src') || row.querySelector('img')?.getAttribute('data-src')),
            path: href, downloadPath: null, categoryName: null, categoryPath: null,
            downloadedAt: dateStr || null
          });
        }

        // 3D. 若仍无书籍，提取首页/热门页/推荐页的 <z-cover> 网格
        if (books.length === 0) {
          const seenCoverTitles = new Set();
          for (const a of doc.querySelectorAll('a[href*="/book/"]')) {
            const cov = a.querySelector('z-cover');
            if (!cov) continue;
            const href = normPath(a.getAttribute('href'));
            const m = href.match(/^\/book\/([^\/]+)/);
            const id = String(cov.getAttribute('id') || m?.[1] || '').trim();
            const bTitle = (cov.getAttribute('title') || '').trim();
            const bAuthor = (cov.getAttribute('author') || '').trim();
            const titleKey = (bTitle + '|' + bAuthor).toLowerCase();
            if (!id || !bTitle || seenBookIds.has(id) || seenCoverTitles.has(titleKey)) continue;
            seenBookIds.add(id);
            seenCoverTitles.add(titleKey);
            books.push({
              id, title: bTitle, author: bAuthor,
              authorPath: bAuthor ? '/author/' + encodeURIComponent(bAuthor) : null,
              publisher: '', year: '', language: '', pages: '',
              isbn: (cov.getAttribute('isbn') || '').trim(),
              extensionName: '', filesize: '', rating: '', summary: '',
              cover: normCover(cov.querySelector('img')?.getAttribute('src') || cov.querySelector('img')?.getAttribute('data-src')),
              path: href, downloadPath: null, categoryName: null, categoryPath: null, downloadedAt: null
            });
          }
        }
      }

      // 4. 提取书单 <z-booklist>
      const booklists = [];
      const seenLists = new Set();
      for (const bl of doc.querySelectorAll('z-booklist')) {
        const lid = String(bl.getAttribute('id') || '').trim();
        const lhref = normPath(bl.getAttribute('href'));
        const ltitle = (bl.getAttribute('topic') || '').trim();
        if (!lid || !ltitle || !lhref || seenLists.has(lid)) continue;
        seenLists.add(lid);
        booklists.push({
          id: lid,
          title: ltitle,
          author: (bl.getAttribute('author') || '').trim(),
          count: parseInt(bl.getAttribute('quantity') || '0', 10) || 0,
          views: (bl.getAttribute('views') || '').trim(),
          description: (bl.getAttribute('description') || bl.textContent || '').trim(),
          path: lhref
        });
      }

      // 5. 提取分类列表 (/categories)
      const facets = [];
      const seenFacets = new Set();
      for (const box of doc.querySelectorAll('#categoriesContainer .subcategories-container')) {
        const groupName = (box.querySelector('.category-name')?.textContent || '分类').trim();
        for (const li of box.querySelectorAll('.subcategory-name a[href^="/category/"]')) {
          const fpath = normPath(li.getAttribute('href'));
          if (!fpath || seenFacets.has(fpath)) continue;
          seenFacets.add(fpath);
          const countText = (li.querySelector('.books-count')?.textContent || '').replace(/\D+/g, '');
          const count = countText ? parseInt(countText, 10) : null;
          const clone = li.cloneNode(true);
          clone.querySelectorAll('.books-count').forEach(n => n.remove());
          const fname = (clone.textContent || '').replace(/\s+/g, ' ').trim();
          if (fname) {
            facets.push({ name: fname, group: groupName, count, path: fpath });
          }
        }
      }

      // 6. 提取分页信息
      let currentPage = parseInt(pageUrl.searchParams.get('page') || '1', 10) || 1;
      let totalPages = currentPage;
      let hasNextPage = false;

      const pagerMatch = scriptsText.match(/pagerOptions\s*=\s*\{[\s\S]*?pagesTotal\s*:\s*(\d+)[\s\S]*?pageCurrent\s*:\s*(\d+)/);
      if (pagerMatch) {
        totalPages = parseInt(pagerMatch[1], 10) || 1;
        currentPage = parseInt(pagerMatch[2], 10) || currentPage;
        hasNextPage = currentPage < totalPages;
      } else if (pathname.startsWith('/booklist/')) {
        const totalBooksMatch = scriptsText.match(/let\s+booksCount\s*=\s*(\d+)/);
        const totalCount = totalBooksMatch ? parseInt(totalBooksMatch[1], 10) : 0;
        hasNextPage = totalCount > books.length;
        totalPages = hasNextPage ? currentPage + 1 : currentPage;
      } else if (pathname.startsWith('/booklists')) {
        hasNextPage = booklists.length >= 10;
        totalPages = hasNextPage ? currentPage + 1 : currentPage;
      } else if (doc.querySelector('.paginator a[href*="page=' + (currentPage + 1) + '"]')) {
        hasNextPage = true;
        totalPages = currentPage + 1;
      }

      // 如果是书单详情页，用 CurrentReadlist.title 作为页面标题
      let finalTitle = title;
      const readlistMatch = scriptsText.match(/window\.CurrentReadlist\s*=\s*(\{[\s\S]*?\});/);
      if (readlistMatch) {
        try {
          const rl = JSON.parse(readlistMatch[1]);
          if (rl && rl.title) finalTitle = String(rl.title);
        } catch {}
      }

      return {
        title: finalTitle,
        text: bodyText.slice(0, 1500),
        login: isLoginPage,
        challenge: isChallenge,
        notFound: isNotFound,
        quotaExceeded: isQuotaExceeded,
        books,
        relatedBooks,
        formats,
        booklists,
        facets,
        currentPage,
        totalPages,
        hasNextPage,
        displayName,
        email,
        userId,
        isFavorite,
        quota
      };
    }
    """#

    static let currentDocumentExtractionScript = """
    (() => {
      \(sharedExtractionFunction)
      return JSON.stringify(extractZLibDocument(document, location.href, 200));
    })()
    """

    static let inPageFetchScript = """
    \(sharedExtractionFunction)
    const r = await fetch(targetUrl, {credentials: 'include', redirect: 'follow'});
    const html = await r.text();
    const doc = new DOMParser().parseFromString(html, 'text/html');
    return JSON.stringify(extractZLibDocument(doc, r.url || targetUrl, r.status));
    """

    static let cachedExtractionScript = """
    \(sharedExtractionFunction)
    window.__luoyeExtractZLibDocument = extractZLibDocument;
    """

    static let cachedInPageFetchScript = """
    if (typeof window.__luoyeExtractZLibDocument !== 'function') throw new Error('extractor unavailable');
    const r = await fetch(targetUrl, {credentials: 'include', redirect: 'follow'});
    const html = await r.text();
    const doc = new DOMParser().parseFromString(html, 'text/html');
    return JSON.stringify(window.__luoyeExtractZLibDocument(doc, r.url || targetUrl, r.status));
    """
}
