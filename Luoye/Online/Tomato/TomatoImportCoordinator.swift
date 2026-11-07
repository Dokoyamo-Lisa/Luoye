import Foundation
import Observation
import SwiftData

/// One foreground import across all Tomato library screens, with stable aliases for entry points.
@MainActor @Observable
final class TomatoImportCoordinator {
    private(set) var importing: String?
    private(set) var message: String?
    private var request: UUID?
    private var task: Task<Void, Never>?
    private var aliases: [String: UUID] = [:]
    private let aliasFile: URL

    init(aliasFile: URL = URL.applicationSupportDirectory.appending(path: "HaikuTomato/importAliases.json")) {
        self.aliasFile = aliasFile
        if let data = try? Data(contentsOf: aliasFile), let saved = try? JSONDecoder().decode([String: UUID].self, from: data) { aliases = saved }
    }
    static func fileKey(base: URL, path: String) -> String {
        let canonical = (try? TomatoClient.serverURL(base.absoluteString)) ?? base
        return "tomato-file:\(canonical.absoluteString)|\(path)"
    }
    private static func canonicalKey(_ key: String?) -> String? {
        guard let key, key.hasPrefix("tomato-file:") else { return key }
        let parts = key.dropFirst("tomato-file:".count).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let base = try? TomatoClient.serverURL(String(parts[0])) else { return key }
        return fileKey(base: base, path: String(parts[1]))
    }
    @discardableResult
    func start(file: TomatoRemoteFile, base: URL, book: TomatoBook?, context: ModelContext,
               download: @escaping @Sendable () async throws -> URL,
               completion: @escaping @MainActor (Result<Book, Error>) -> Void) -> UUID? {
        guard request == nil else { return nil }
        let id = UUID(); request = id; importing = file.id; message = nil
        let fileKey = Self.fileKey(base: base, path: file.rel_path)
        task = Task {
            defer { if request == id { request = nil; importing = nil; task = nil } }
            do {
                let rows = try context.fetch(FetchDescriptor<Book>())
                let bookKey = book.map { "tomato:\($0.id)" }
                let aliasID = aliases[fileKey] ?? aliases.first { Self.canonicalKey($0.key) == fileKey }?.value
                let existing = rows.first(where: { $0.id == aliasID || Self.canonicalKey($0.sourceKey) == fileKey || (bookKey != nil && $0.sourceKey == bookKey) })
                if let existing, BookImportCommit.hasLocalFile(existing) {
                    try Task.checkCancellation()
                    remember(fileKey, bookKey: bookKey, book: existing)
                    completion(.success(existing)); return
                }
                let temp = try await download()
                defer { try? FileManager.default.removeItem(at: temp) }
                try Task.checkCancellation()
                try TomatoDownloadedFile.validate(temp, extensionName: file.ext)
                let title = book?.title ?? (file.name as NSString).deletingPathExtension
                let author = book?.author ?? ""
                let sourceKey = bookKey ?? fileKey
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let imported = try BookImporter.importDownloadedBook(from: temp, extensionName: file.ext,
                        preferredTitle: title, preferredAuthor: author, preferredCover: nil,
                        fileName: UUID().uuidString + "." + file.ext.lowercased(), sourceKey: sourceKey,
                        editionNote: "番茄小说 · 下载器导入")
                    return PreparedBookImport(imported)
                }.value
                guard request == id else { prepared.removeFiles(); throw CancellationError() }
                let imported = try BookImportCommit.commit(prepared, context: context, matchingID: existing?.id)
                remember(fileKey, bookKey: bookKey, book: imported)
                completion(.success(imported))
            } catch {
                let failure: Error = Task.isCancelled ? CancellationError() : error
                if request == id && !(failure is CancellationError) { message = failure.localizedDescription }
                completion(.failure(failure))
            }
        }
        return id
    }
    func cancel(id: UUID? = nil) {
        guard let current = request, id == nil || id == current else { return }
        task?.cancel(); task = nil; request = nil; importing = nil; message = nil
    }
    func localBookID(for bookID: String) -> UUID? { aliases["tomato:\(bookID)"] }
    private func remember(_ key: String, bookKey: String?, book: Book) {
        aliases[key] = book.id
        if let bookKey, !(book.sourceKey?.hasPrefix("tomato:") == true && book.sourceKey != bookKey) { aliases[bookKey] = book.id }
        do {
            try FileManager.default.createDirectory(at: aliasFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(aliases).write(to: aliasFile, options: .atomic)
        } catch { message = "书籍已导入，但导入记录暂未保存：" + error.localizedDescription }
    }
}
