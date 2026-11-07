import Foundation
import Observation
import CryptoKit

struct MangaSourceDescriptor: Codable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let name: String
    let version: String
    let fileName: String
    var updateURL: URL?
    var enabled: Bool = true
}

@MainActor @Observable
final class MangaSourceStore {
    private(set) var refreshingSources = false
    private(set) var refreshProgress = 0
    private(set) var refreshTotal = 0
    private(set) var refreshMessage: String?
    private(set) var lastRefresh: Date? = UserDefaults.standard.object(forKey: "manga.sources.lastRefresh") as? Date
    @ObservationIgnored private var defaultsCheckedThisSession = false
    private(set) var installingDefaults = false
    private(set) var defaultProgress = 0
    private(set) var defaultTotal = 0
    private(set) var defaultFailures: [String: String] = [:]
    private(set) var sources: [MangaSourceDescriptor] = []
    @ObservationIgnored private var runtimes: [String: MangaScriptRuntime] = [:]
    nonisolated static let directory = MangaLibrary.directory.appending(path: "Sources", directoryHint: .isDirectory)
    private let index = directory.appending(path: "index.json")

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index), let values = try? JSONDecoder().decode([MangaSourceDescriptor].self, from: data) { sources = values }
    }

    func installDefaultsIfNeeded(retry: Bool = false) async {
        guard !installingDefaults, retry || !defaultsCheckedThisSession else { return }
        defaultsCheckedThisSession = true
        if !retry && (UserDefaults.standard.bool(forKey: "manga.defaultSources.v1") || !sources.isEmpty) {
            UserDefaults.standard.set(true, forKey: "manga.defaultSources.v1")
            return
        }
        installingDefaults = true
        defaultProgress = 0; defaultFailures = [:]
        defer { installingDefaults = false }
        guard let manifest = Bundle.main.url(forResource: "DefaultMangaSources", withExtension: "json"),
              let data = try? Data(contentsOf: manifest), let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let missing = entries.filter { entry in !sources.contains { $0.key == entry["key"] as? String } }
        defaultTotal = missing.count
        for start in stride(from: 0, to: missing.count, by: 4) {
            let batch = Array(missing[start..<min(start + 4, missing.count)]).compactMap { entry -> (String, String)? in
                guard let key = entry["key"] as? String, let file = entry["fileName"] as? String else { return nil }
                return (key, file)
            }
            await withTaskGroup(of: (String, String?).self) { group in
                for (key, file) in batch {
                    group.addTask {
                        do {
                            do { try await self.install(url: URL(string: "https://raw.githubusercontent.com/venera-app/venera-configs/main/" + file)!) }
                            catch { try await self.install(url: URL(string: "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/" + file)!) }
                            return (key, nil)
                        } catch { return (key, error.localizedDescription) }
                    }
                }
                for await (key, error) in group {
                    defaultProgress += 1
                    if let error { defaultFailures[key] = error }
                }
            }
        }
        UserDefaults.standard.set(true, forKey: "manga.defaultSources.v1")
    }

    func refreshAllSources() async {
        guard !refreshingSources, !installingDefaults else { return }
        refreshingSources = true; refreshMessage = nil; refreshProgress = 0
        defer { refreshingSources = false }
        let existing = sources.filter { $0.updateURL != nil }
        refreshTotal = existing.count
        var failures: [String] = []
        for start in stride(from: 0, to: existing.count, by: 4) {
            let batch = Array(existing[start..<min(start + 4, existing.count)])
            await withTaskGroup(of: String?.self) { group in
                for descriptor in batch {
                    group.addTask {
                        do { try await self.install(url: descriptor.updateURL!, reload: true); return nil }
                        catch { return descriptor.name + "：" + error.localizedDescription }
                    }
                }
                for await error in group {
                    refreshProgress += 1
                    if let error { failures.append(error) }
                }
            }
        }
        await installDefaultsIfNeeded(retry: true)
        lastRefresh = .now
        UserDefaults.standard.set(lastRefresh, forKey: "manga.sources.lastRefresh")
        if failures.isEmpty && defaultFailures.isEmpty { refreshMessage = "已刷新 \(refreshTotal) 个漫画源，本地缓存已更新。" }
        else { refreshMessage = "刷新完成，失败的源继续使用原有缓存。\n" + (failures + defaultFailures.map { $0.key + "：" + $0.value }).joined(separator: "\n") }
    }

    func source(for key: String) -> (any MangaCatalogSource)? {
        if key == "mangadex" { return MangaDexSource() }
        guard let descriptor = sources.first(where: { $0.key == key && $0.enabled }), let runtime = try? runtime(for: descriptor) else { return nil }
        return MangaScriptSource(descriptor: descriptor, runtime: runtime)
    }

    func runtime(for descriptor: MangaSourceDescriptor) throws -> MangaScriptRuntime {
        if let existing = runtimes[descriptor.key] { return existing }
        let script = try String(contentsOf: Self.directory.appending(path: descriptor.fileName), encoding: .utf8)
        let runtime = MangaScriptRuntime(script: script, storageKey: descriptor.key, uiHandler: { message, reply in
            Task { @MainActor in MangaScriptPrompts.shared.receive(message, reply: reply) }
        })
        runtimes[descriptor.key] = runtime
        return runtime
    }

    func install(url: URL, reload: Bool = false) async throws {
        guard url.scheme == "https" else { throw MangaScriptRuntime.RuntimeError.message("请使用 HTTPS 漫画源地址") }
        var request = URLRequest(url: url, cachePolicy: reload ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy); request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 2_000_000, let script = String(data: data, encoding: .utf8) else {
            throw MangaScriptRuntime.RuntimeError.message("漫画源脚本下载失败或文件过大")
        }
        if let cached = sources.first(where: { $0.updateURL == url }),
           let previous = try? Data(contentsOf: Self.directory.appending(path: cached.fileName)), previous == data { return }
        try await install(script: script, origin: url)
    }

    func install(script: String, origin: URL? = nil) async throws {
        guard script.utf8.count <= 2_000_000 else { throw MangaScriptRuntime.RuntimeError.message("漫画源脚本过大") }
        let probe = MangaScriptRuntime(script: script, storageKey: "metadata-probe")
        let metadata = try JSONSerialization.jsonObject(with: await probe.metadata()) as? [String: Any] ?? [:]
        guard let key = metadata["key"] as? String, !key.isEmpty, key != "mangadex",
              key.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil,
              let name = metadata["name"] as? String, !name.isEmpty else { throw MangaScriptRuntime.RuntimeError.message("漫画源名称或标识无效") }
        let fileName = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".js"
        try Data(script.utf8).write(to: Self.directory.appending(path: fileName), options: .atomic)
        let update = (metadata["url"] as? String).flatMap(URL.init(string:)) ?? origin
        let enabled = sources.first(where: { $0.key == key })?.enabled ?? true
        let descriptor = MangaSourceDescriptor(key: key, name: name, version: metadata["version"] as? String ?? "", fileName: fileName, updateURL: update, enabled: enabled)
        if let index = sources.firstIndex(where: { $0.key == key }) { sources[index] = descriptor }
        else { sources.append(descriptor) }
        runtimes[key] = nil
        save()
    }

    func setEnabled(_ key: String, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.key == key }) else { return }
        sources[index].enabled = enabled
        save()
    }

    func remove(_ key: String) {
        guard let source = sources.first(where: { $0.key == key }) else { return }
        try? FileManager.default.removeItem(at: Self.directory.appending(path: source.fileName))
        sources.removeAll { $0.key == key }; runtimes[key] = nil; save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(sources) { try? data.write(to: index, options: .atomic) }
    }
}

struct MangaScriptSource: MangaCatalogSource {
    let descriptor: MangaSourceDescriptor
    let runtime: MangaScriptRuntime
    var exploreIndex = 0
    var searchOptions: [String]? = nil
    var id: String { descriptor.key }
    var displayName: String { descriptor.name }
    var chapterPageSize: Int? { nil }

    func discover(page: Int) async throws -> [MangaOnlineComic] {
        try parseBooks(await runtime.call("__discover", arguments: [page, exploreIndex]))
    }
    func search(_ query: String, page: Int) async throws -> [MangaOnlineComic] {
        try parseBooks(await runtime.call("__search", arguments: [query, page, searchOptions as Any? ?? NSNull()]))
    }
    func chapters(for comic: MangaOnlineComic, page: Int) async throws -> [MangaOnlineChapter] {
        guard page == 1 else { return [] }
        return try parseChapters(await runtime.call("__chapterList", arguments: [comic.id]), comic: comic)
    }
    func refreshChapters(for comic: MangaOnlineComic) async throws -> [MangaOnlineChapter] {
        try parseChapters(await runtime.call("__refreshChapterList", arguments: [comic.id]), comic: comic)
    }
    private func parseChapters(_ data: Data, comic: MangaOnlineComic) throws -> [MangaOnlineChapter] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (object["chapters"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return MangaOnlineChapter(id: id, title: entry["title"] as? String ?? "章节", language: "", group: entry["group"] as? String ?? "", pageCount: 0, externalURL: nil, comicID: comic.id)
        }
    }
    func pages(for chapter: MangaOnlineChapter) async throws -> [MangaImageRequest] {
        let data = try await runtime.call("__imageRequests", arguments: [chapter.comicID ?? "", chapter.id])
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []).compactMap { entry in
            guard let raw = entry["url"] as? String, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") else { return nil }
            return MangaImageRequest(url: url, headers: entry["headers"] as? [String: String] ?? [:], processor: runtime, processingKey: entry["processingKey"] as? String)
        }
    }
    func parseBooks(_ data: Data) throws -> [MangaOnlineComic] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (object["comics"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let value = entry["id"], !(value is NSNull) else { return nil }
            let id = value as? String ?? String(describing: value)
            let cover = (entry["cover"] as? String).flatMap(URL.init(string:))
            return MangaOnlineComic(id: id, title: entry["title"] as? String ?? "未命名漫画", summary: entry["description"] as? String ?? entry["subtitle"] as? String ?? "", coverURL: cover, source: self.id, favoriteID: (entry["favoriteId"] as? String) ?? (entry["favoriteId"] as? NSNumber)?.stringValue)
        }
    }
}
