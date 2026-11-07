import Foundation
import Observation

@MainActor @Observable
final class TomatoStore {
    private(set) var server = UserDefaults.standard.string(forKey: "haiku.tomato.server") ?? ""
    private(set) var favorites: [TomatoBook] = []
    private(set) var message: String?
    private(set) var connecting = false
    private var connectionRequest = UUID()
    var homeRefresh = 0
    private(set) var client = TomatoClient()
    let catalog: TomatoPublicCatalog
    let website = TomatoWebsite()
    let progress: TomatoReadingProgress
    let importer = TomatoImportCoordinator()
    private let file: URL
    var endpoint: URL? { try? TomatoClient.serverURL(server) }
    init(catalog: TomatoPublicCatalog = TomatoPublicCatalog(), progress: TomatoReadingProgress? = nil, favoritesFile: URL = URL.applicationSupportDirectory.appending(path: "HaikuTomato/favorites.json")) {
        self.catalog = catalog; self.progress = progress ?? TomatoReadingProgress(); self.file = favoritesFile
        if let data = try? Data(contentsOf: file), let books = try? JSONDecoder().decode([TomatoBook].self, from: data) { favorites = books }
    }
    func configure(_ address: String) throws {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = clean.isEmpty ? "" : try TomatoClient.serverURL(clean).absoluteString
        if normalized != (endpoint?.absoluteString ?? "") {
            importer.cancel(); client = TomatoClient(); connectionRequest = UUID(); connecting = false
        }
        server = normalized; UserDefaults.standard.set(normalized, forKey: "haiku.tomato.server"); message = nil
    }
    func connect(password: String) async {
        guard !connecting, let endpoint else { return }
        let request = UUID(); connectionRequest = request
        let client = client
        connecting = true; defer { if connectionRequest == request { connecting = false } }
        do {
            let version = try await client.connect(endpoint, password: password)
            guard connectionRequest == request else { return }
            message = "已连接下载器 · " + version
        } catch { if connectionRequest == request { message = error.localizedDescription } }
    }
    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }
    func toggleFavorite(_ book: TomatoBook) {
        if isFavorite(book.id) { favorites.removeAll { $0.id == book.id } }
        else { favorites.insert(book, at: 0) }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(favorites).write(to: file, options: .atomic)
        } catch { message = "收藏未能保存：" + error.localizedDescription }
    }
}
