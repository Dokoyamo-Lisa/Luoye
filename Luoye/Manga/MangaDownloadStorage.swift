import Foundation
import CryptoKit

/// Only reuses a page when both its request and saved bytes still match.
/// Request headers are hashed, never persisted in plain text.
struct MangaDownloadStorage {
    private struct Entry: Codable {
        let request: String
        let fileName: String
        let digest: String
    }
    private struct Index: Codable {
        var version = 1
        var pages: [String: Entry] = [:]
    }
    let directory: URL
    private let requests: [MangaImageRequest]
    private var index: Index
    private var indexURL: URL { directory.appending(path: ".download-index.json") }

    init(directory: URL, requests: [MangaImageRequest]) throws {
        self.directory = directory
        self.requests = requests
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appending(path: ".download-index.json")),
           let saved = try? JSONDecoder().decode(Index.self, from: data), saved.version == 1 {
            index = saved
        } else { index = Index() }
    }

    func cachedData(at page: Int) -> Data? {
        guard requests.indices.contains(page), let entry = index.pages[String(page)],
              entry.request == fingerprint(requests[page]), entry.fileName == fileName(at: page),
              let data = try? Data(contentsOf: directory.appending(path: entry.fileName)),
              entry.digest == Self.digest(data) else { return nil }
        return data
    }

    mutating func save(_ data: Data, at page: Int) throws {
        guard requests.indices.contains(page), !data.isEmpty else { throw URLError(.badServerResponse) }
        let name = fileName(at: page)
        try data.write(to: directory.appending(path: name), options: .atomic)
        index.pages[String(page)] = Entry(request: fingerprint(requests[page]), fileName: name, digest: Self.digest(data))
        try saveIndex()
    }

    func fileURL(at page: Int) -> URL { directory.appending(path: fileName(at: page)) }

    /// Publish only the current chapter pages; stale extensions/tail pages must not enter the reader.
    mutating func finish() throws {
        let wanted = Set(requests.indices.map { fileName(at: $0) })
        for page in requests.indices {
            guard let entry = index.pages[String(page)], entry.request == fingerprint(requests[page]),
                  entry.fileName == fileName(at: page),
                  FileManager.default.fileExists(atPath: fileURL(at: page).path) else { throw URLError(.cannotOpenFile) }
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where !wanted.contains(file.lastPathComponent) {
            // Restrict cleanup to filenames produced by the downloader, never arbitrary user files.
            if file.lastPathComponent.range(of: #"^\d{5,}\.(jpg|jpeg|png|webp|gif|heic)$"#, options: .regularExpression) != nil {
                try FileManager.default.removeItem(at: file)
            }
        }
        index.pages = index.pages.filter { key, entry in
            guard let page = Int(key), requests.indices.contains(page) else { return false }
            return wanted.contains(entry.fileName)
        }
        try saveIndex()
    }

    private func saveIndex() throws {
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }
    private func fileName(at page: Int) -> String {
        let suffix = requests[page].url.pathExtension.lowercased()
        let ext = ["png", "webp", "gif", "heic"].contains(suffix) ? suffix : "jpg"
        return String(format: "%05d.%@", page, ext)
    }
    private func fingerprint(_ request: MangaImageRequest) -> String {
        let parts = [request.url.absoluteString, request.processor?.scriptFingerprint ?? "native", request.processingKey == nil ? "nil" : "value", request.processingKey ?? ""]
            + request.headers.keys.sorted().flatMap { [$0, request.headers[$0] ?? ""] }
        return Self.digest(Data(parts.map { String($0.utf8.count) + ":" + $0 }.joined().utf8))
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
