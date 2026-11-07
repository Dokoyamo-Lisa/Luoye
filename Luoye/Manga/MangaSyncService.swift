import Foundation
import Observation
import CryptoKit

@MainActor @Observable
final class MangaSyncService {
    var server = UserDefaults.standard.string(forKey: "manga.webdav.server") ?? ""
    var username = UserDefaults.standard.string(forKey: "manga.webdav.username") ?? ""
    var autoSync = UserDefaults.standard.bool(forKey: "manga.webdav.auto") {
        didSet { UserDefaults.standard.set(autoSync, forKey: "manga.webdav.auto"); if autoSync { schedule() } }
    }
    private(set) var busy = false
    private(set) var message: String?
    private(set) var lastSync = UserDefaults.standard.object(forKey: "manga.webdav.lastSync") as? Date
    @ObservationIgnored private weak var library: MangaLibrary?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var attached = false
    @ObservationIgnored private let sessionConfiguration: URLSessionConfiguration?
    init(sessionConfiguration: URLSessionConfiguration? = nil) { self.sessionConfiguration = sessionConfiguration }
    @ObservationIgnored private let redirectDelegate = MangaSyncRedirectDelegate()
    @ObservationIgnored private lazy var session: URLSession = {
        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 35
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()
    var configured: Bool { !server.isEmpty && !username.isEmpty }

    func attach(_ library: MangaLibrary) {
        self.library = library
        library.onReadingDataChanged = { [weak self] in self?.schedule() }
        if !attached { attached = true; if autoSync { schedule() } }
    }
    func saveConfiguration(server: String, username: String, password: String) throws {
        let clean = server.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try destination(clean)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { throw MangaScriptRuntime.RuntimeError.message("请输入 WebDAV 用户名") }
        if !password.isEmpty { try MangaSecrets.write(Data(password.utf8), name: credentialName(server: clean, username: user)) }
        guard try MangaSecrets.read(credentialName(server: clean, username: user)) != nil else { throw MangaScriptRuntime.RuntimeError.message("请输入 WebDAV 密码") }
        self.server = clean; self.username = user
        UserDefaults.standard.set(clean, forKey: "manga.webdav.server")
        UserDefaults.standard.set(user, forKey: "manga.webdav.username")
        message = "连接配置已保存"
    }
    func schedule() {
        guard autoSync, configured, !applying else { return }
        scheduled?.cancel()
        scheduled = Task {
            do { try await Task.sleep(for: .seconds(5)); try Task.checkCancellation(); await synchronize() }
            catch { }
        }
    }
    func testConnection() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let (_, response) = try await request(method: "GET")
            guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else { throw statusError(response.statusCode) }
            message = response.statusCode == 404 ? "连接成功，可以创建在线阅读备份" : "连接成功，服务器已有阅读备份"
        } catch { message = error.localizedDescription }
    }
    func synchronize() async {
        guard !busy, let library else { return }
        busy = true; message = "正在同步…"; applying = true
        defer { busy = false; applying = false }
        do {
            for attempt in 0..<3 {
                let (remote, response) = try await request(method: "GET")
                if response.statusCode == 200 { try library.mergeReadingSnapshot(MangaReadingSnapshot.decode(remote)) }
                else if response.statusCode != 404 { throw statusError(response.statusCode) }
                let body = try JSONEncoder().encode(library.readingSnapshot())
                var headers: [String: String] = ["Content-Type":"application/json"]
                if response.statusCode == 404 { headers["If-None-Match"] = "*" }
                else if let tag = response.value(forHTTPHeaderField: "ETag") { headers["If-Match"] = tag }
                else if let date = response.value(forHTTPHeaderField: "Last-Modified") { headers["If-Unmodified-Since"] = date }
                let (_, uploaded) = try await request(method: "PUT", body: body, headers: headers)
                if [409,412].contains(uploaded.statusCode), attempt < 2 { continue }
                guard (200..<300).contains(uploaded.statusCode) else { throw statusError(uploaded.statusCode) }
                lastSync = .now
                UserDefaults.standard.set(lastSync, forKey: "manga.webdav.lastSync")
                message = "在线阅读数据已同步"
                return
            }
        } catch { message = error.localizedDescription }
    }
    private func destination(_ raw: String) throws -> URL {
        guard var components = URLComponents(string: raw), components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil, components.query == nil else { throw MangaScriptRuntime.RuntimeError.message("请填写 HTTPS WebDAV 目录地址，账号和密码填在下方") }
        components.fragment = nil
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let directory = components.url else { throw MangaScriptRuntime.RuntimeError.message("WebDAV 地址无效") }
        return directory.appending(path: "luoye-manga-reading-v1.json")
    }
    private func credentialName(server: String, username: String) -> String {
        "webdav:" + SHA256.hash(data: Data((server + "\n" + username).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func request(method: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let secret = try MangaSecrets.read(credentialName(server: server, username: username)), let password = String(data: secret, encoding: .utf8) else { throw MangaScriptRuntime.RuntimeError.message("请先保存 WebDAV 登录配置") }
        var request = URLRequest(url: try destination(server), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method; request.httpBody = body; request.allHTTPHeaderFields = headers
        request.setValue("Basic " + Data((username + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard data.count <= 20 * 1024 * 1024, let response = response as? HTTPURLResponse else { throw MangaScriptRuntime.RuntimeError.message("WebDAV 响应无效或文件过大") }
        return (data,response)
    }
    private func statusError(_ code: Int) -> Error {
        switch code {
        case 401,403: MangaScriptRuntime.RuntimeError.message("WebDAV 身份验证失败或目录没有访问权限")
        case 409: MangaScriptRuntime.RuntimeError.message("WebDAV 目录不存在，请填写已经创建的目录")
        case 412: MangaScriptRuntime.RuntimeError.message("其他设备正在更新，请稍后重新同步")
        default: MangaScriptRuntime.RuntimeError.message("WebDAV 请求失败（\(code)）")
        }
    }
}

private final class MangaSyncRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == task.originalRequest?.url?.host else { completionHandler(nil); return }
        completionHandler(request)
    }
}
