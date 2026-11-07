import Foundation
import CryptoKit

/// 仅管理可重新获取的缓存文件；书斋原书与进度存放在 Application Support。
actor FanhuaCache {
    static let maximumBytes = 300_000_000
    static let shared = FanhuaCache()
    private let directory: URL
    private let maximum: Int

    init(directory: URL = URL.cachesDirectory.appending(path: "FanhuaMedia", directoryHint: .isDirectory), maximum: Int = maximumBytes) {
        self.directory = directory
        self.maximum = maximum
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }
    func data(for key: String) -> Data? {
        let url = file(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }
    func store(_ data: Data, for key: String) {
        guard data.count <= maximum else { return }
        try? data.write(to: file(for: key), options: .atomic)
        trim()
    }
    func byteCount() -> Int { entries().reduce(0) { $0 + $1.size } }
    func clear() {
        for entry in entries() { try? FileManager.default.removeItem(at: entry.url) }
    }
    func trim() {
        let files = entries().sorted { $0.date < $1.date }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total > maximum {
            do { try FileManager.default.removeItem(at: file.url); total -= file.size } catch { continue }
        }
    }
    private func entries() -> [(url: URL, size: Int, date: Date)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])) ?? []
        return files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }
}

/// 避免系统 HTTP 磁盘缓存与受限的媒体缓存重复存储。
enum FanhuaNetwork {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
