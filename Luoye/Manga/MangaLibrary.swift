import Foundation
import Observation
import UniformTypeIdentifiers
import UIKit

struct MangaComic: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var format: String
    var fileName: String
    var coverFileName: String?
    var page: Int = 0
    var pageCount: Int
    var addedAt: Date = .now
    var lastOpenedAt: Date?
    var contentRevision: UUID? = nil

    var fileURL: URL { MangaLibrary.directory.appending(path: fileName) }
    var coverURL: URL? { coverFileName.map { MangaLibrary.directory.appending(path: $0) } }
}

@MainActor @Observable
final class MangaLibrary {
    nonisolated static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Manga", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let supportedTypes: [UTType] = [.pdf] + ["cbz", "zip"].compactMap { UTType(filenameExtension: $0) }

    private let indexURL: URL
    private let readingStateURL: URL
    private let stampsURL: URL
    private var syncStamps = MangaSyncStamps()
    @ObservationIgnored var onReadingDataChanged: (() -> Void)?
    private let readLaterURL: URL
    private(set) var readLater: [MangaOnlineComic] = []
    private let downloadsURL: URL
    private(set) var downloads: [MangaDownloadJob] = []
    @ObservationIgnored var sourceStore: MangaSourceStore?
    @ObservationIgnored private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    private let onlineURL: URL
    private(set) var comics: [MangaComic] = []
    private(set) var favorites: [MangaOnlineComic] = []
    private(set) var recent: [MangaOnlineComic] = []
    private(set) var onlinePages: [String: Int] = [:]

    init(stateDirectory: URL? = nil) {
        let directory = stateDirectory ?? Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        indexURL = directory.appending(path: "library.json")
        readingStateURL = directory.appending(path: "reading-state.json")
        stampsURL = directory.appending(path: "sync-stamps.json")
        readLaterURL = directory.appending(path: "read-later.json")
        downloadsURL = directory.appending(path: "downloads.json")
        onlineURL = directory.appending(path: "online.json")

        if let data = try? Data(contentsOf: stampsURL), let stamps = try? JSONDecoder().decode(MangaSyncStamps.self, from: data) { syncStamps = stamps }
        if let data = try? Data(contentsOf: readLaterURL), let values = try? JSONDecoder().decode([MangaOnlineComic].self, from: data) { readLater = values }
        if let data = try? Data(contentsOf: downloadsURL), let jobs = try? JSONDecoder().decode([MangaDownloadJob].self, from: data) {
            downloads = jobs.map { job in
                var value = job
                if value.status == .running || value.status == .queued || value.status == .pausing { value.status = .paused }
                return value
            }
        }
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([MangaComic].self, from: data) {
            comics = saved
        }
        if let data = try? Data(contentsOf: onlineURL), let saved = try? JSONDecoder().decode(OnlineState.self, from: data) {
            favorites = saved.favorites
            recent = saved.recent
            onlinePages = saved.pages
        }
        if let data = try? Data(contentsOf: readingStateURL), let value = try? MangaReadingSnapshot.decode(data) {
            favorites = value.favorites; recent = value.recent; readLater = value.readLater
            onlinePages = value.pages; syncStamps = value.stamps
        }
    }

    func importComic(from url: URL) async throws {
        let comic = try await Task.detached(priority: .userInitiated) {
            try Self.prepareImport(from: url)
        }.value
        comics.insert(comic, at: 0)
        save()
    }

    func enqueueDownload(_ chapter: MangaOnlineChapter, of comic: MangaOnlineComic) {
        guard chapter.externalURL == nil else { return }
        if let existing = downloads.first(where: { $0.comic.id == comic.id && $0.comic.source == comic.source && $0.chapter.id == chapter.id }) {
            if existing.status == .completed && (savedDownload(existing.id).map { !FileManager.default.fileExists(atPath: $0.fileURL.path) } ?? true) {
                updateDownload(existing.id) { $0.status = .paused }
                resumeDownload(existing.id)
                return
            }
            if existing.status != .completed { resumeDownload(existing.id) }
            return
        }
        let job = MangaDownloadJob(id: UUID(), comic: comic, chapter: chapter)
        downloads.insert(job, at: 0)
        saveDownloads()
        resumeDownload(job.id)
    }

    func savedDownload(_ id: UUID) -> MangaComic? { comics.first { $0.id == id } }

    func resumeDownload(_ id: UUID) {
        guard downloadTasks[id] == nil, let job = downloads.first(where: { $0.id == id }), job.status != .completed else { return }
        guard downloadTasks.count < 2 else {
            updateDownload(id) { $0.status = .queued }
            return
        }
        updateDownload(id) { $0.status = .running; $0.error = nil }
        downloadTasks[id] = Task {
            do {
                guard let source = sourceStore?.source(for: job.comic.source) ?? (job.comic.source == "mangadex" ? MangaDexSource() : nil) else { throw MangaScriptRuntime.RuntimeError.message("请先启用此漫画源") }
                let urls = try await source.pages(for: job.chapter)
                try Task.checkCancellation()
                guard !urls.isEmpty else { throw ComicArchive.ArchiveError.noPages }
                updateDownload(id) { $0.total = urls.count; $0.completed = 0 }
                let worker = Task.detached(priority: .utility) {
                    try await Self.prepareDownload(id: id, chapter: job.chapter, comic: job.comic, urls: urls) { completed in
                        await self.updateDownload(id) { $0.completed = completed }
                    }
                }
                let saved = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                if let index = comics.firstIndex(where: { $0.id == saved.id }) {
                    var updated = saved
                    updated.page = min(comics[index].page, max(0, saved.pageCount - 1))
                    updated.addedAt = comics[index].addedAt; updated.lastOpenedAt = comics[index].lastOpenedAt
                    comics[index] = updated
                } else { comics.insert(saved, at: 0) }
                save()
                updateDownload(id) { $0.status = .completed; $0.completed = urls.count }
            } catch is CancellationError {
                updateDownload(id) { $0.status = .paused; $0.error = nil }
            } catch {
                updateDownload(id) { $0.status = Task.isCancelled ? .paused : .failed; $0.error = Task.isCancelled ? nil : error.localizedDescription }
            }
            downloadTasks[id] = nil
            if let next = downloads.first(where: { $0.status == .queued }) { resumeDownload(next.id) }
        }
    }

    func pauseDownload(_ id: UUID) {
        if downloads.first(where: { $0.id == id })?.status == .queued {
            updateDownload(id) { $0.status = .paused }
        }
        if let task = downloadTasks[id] {
            updateDownload(id) { $0.status = .pausing; $0.error = nil }
            task.cancel()
        }
    }

    func removeDownload(_ id: UUID) {
        guard downloadTasks[id] == nil else { pauseDownload(id); return }
        if let job = downloads.first(where: { $0.id == id }), job.status != .completed {
            try? FileManager.default.removeItem(at: Self.directory.appending(path: "\(id.uuidString)-pages"))
        }
        downloads.removeAll { $0.id == id }
        saveDownloads()
    }

    private func updateDownload(_ id: UUID, change: (inout MangaDownloadJob) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        change(&downloads[index])
        saveDownloads()
    }

    private func saveDownloads() {
        if let data = try? JSONEncoder().encode(downloads) { try? data.write(to: downloadsURL, options: .atomic) }
    }

    private nonisolated static func prepareDownload(id: UUID, chapter: MangaOnlineChapter, comic: MangaOnlineComic, urls: [MangaImageRequest], progress: @Sendable (Int) async -> Void) async throws -> MangaComic {
        let folder = "\(id.uuidString)-pages"
        let destination = directory.appending(path: folder, directoryHint: .isDirectory)
        var storage = try MangaDownloadStorage(directory: destination, requests: urls)
        var completed = 0
        for start in stride(from: 0, to: urls.count, by: 4) {
            try Task.checkCancellation()
            let end = min(start + 4, urls.count)
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for index in start..<end {
                    if let data = storage.cachedData(at: index), UIImage(data: data) != nil {
                        completed += 1
                        await progress(completed)
                        continue
                    }
                    let imageRequest = urls[index]
                    group.addTask {
                        var request = URLRequest(url: imageRequest.url)
                        request.allHTTPHeaderFields = imageRequest.headers
                        request.timeoutInterval = 40
                        let (rawData, response) = try await URLSession.shared.data(for: request)
                        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                            throw URLError(.badServerResponse)
                        }
                        let data: Data
                        if let processor = imageRequest.processor, let key = imageRequest.processingKey { data = try await processor.processImage(rawData, key: key) }
                        else { data = rawData }
                        guard UIImage(data: data) != nil else { throw URLError(.cannotDecodeContentData) }
                        return (index, data)
                    }
                }
                for try await (index, data) in group {
                    try Task.checkCancellation()
                    try storage.save(data, at: index)
                    completed += 1
                    await progress(completed)
                }
            }
        }
        try Task.checkCancellation()
        try storage.finish()
        let coverData = try Data(contentsOf: storage.fileURL(at: 0))
        let coverName = try saveThumbnail(coverData, id: id)
        return MangaComic(id: id, title: "\(comic.title) · \(chapter.title)", format: "folder",
                          fileName: folder, coverFileName: coverName, pageCount: urls.count, contentRevision: UUID())
    }

    private nonisolated static func saveThumbnail(_ data: Data, id: UUID) throws -> String? {
        guard let image = UIImage(data: data) else { return nil }
        let ratio = min(1, 360 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let thumbnail = UIGraphicsImageRenderer(size: size).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        let name = "\(id.uuidString)-cover.png"
        try thumbnail.write(to: directory.appending(path: name), options: .atomic)
        return name
    }

    private nonisolated static func prepareImport(from url: URL) throws -> MangaComic {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard ["cbz", "zip", "pdf"].contains(ext) else { throw ComicArchive.ArchiveError.unsupported }
        let id = UUID()
        let fileName = "\(id.uuidString).\(ext)"
        let target = Self.directory.appending(path: fileName)
        try FileManager.default.copyItem(at: url, to: target)
        do {
            let archive = try ComicArchive(fileURL: target, format: ext)
            var coverFileName: String?
            if let cover = try archive.imageData(at: 0), let image = UIImage(data: cover) {
                let name = "\(id.uuidString)-cover.png"
                let ratio = min(1, 360 / max(image.size.width, image.size.height))
                let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                let thumbnail = UIGraphicsImageRenderer(size: size).pngData { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                if (try? thumbnail.write(to: Self.directory.appending(path: name), options: .atomic)) != nil {
                    coverFileName = name
                }
            }
            return MangaComic(id: id, title: url.deletingPathExtension().lastPathComponent,
                              format: ext, fileName: fileName, coverFileName: coverFileName,
                              pageCount: archive.pageCount)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func recordPage(_ index: Int, for id: UUID) {
        guard let position = comics.firstIndex(where: { $0.id == id }) else { return }
        comics[position].page = index
        comics[position].lastOpenedAt = .now
        save()
    }

    func remove(_ id: UUID) {
        guard let position = comics.firstIndex(where: { $0.id == id }) else { return }
        let comic = comics.remove(at: position)
        if downloads.contains(where: { $0.id == id && $0.status == .completed }) {
            updateDownload(id) { $0.status = .paused; $0.completed = 0; $0.error = "离线文件已移除，可重新下载。" }
        }
        try? FileManager.default.removeItem(at: comic.fileURL)
        if let cover = comic.coverURL { try? FileManager.default.removeItem(at: cover) }
        save()
    }

    func isReadLater(_ comic: MangaOnlineComic) -> Bool {
        readLater.contains { $0.source == comic.source && $0.id == comic.id }
    }

    func toggleReadLater(_ comic: MangaOnlineComic) {
        let key = MangaSyncStamps.key(comic)
        if isReadLater(comic) {
            readLater.removeAll { $0.source == comic.source && $0.id == comic.id }
            syncStamps.removedReadLater[key] = .now
        } else {
            readLater.insert(comic, at: 0)
            syncStamps.readLater[key] = .now
        }
        saveStamps()
        if let data = try? JSONEncoder().encode(readLater) { try? data.write(to: readLaterURL, options: .atomic) }
    }

    func isFavorite(_ comic: MangaOnlineComic) -> Bool {
        favorites.contains { $0.source == comic.source && $0.id == comic.id }
    }

    func toggleFavorite(_ comic: MangaOnlineComic) {
        let key = MangaSyncStamps.key(comic)
        if isFavorite(comic) {
            syncStamps.removedFavorites[key] = .now
            favorites.removeAll { $0.source == comic.source && $0.id == comic.id }
        } else {
            syncStamps.favorites[key] = .now
            favorites.insert(comic, at: 0)
        }
        saveOnline()
    }

    func recordViewed(_ comic: MangaOnlineComic) {
        syncStamps.recent[MangaSyncStamps.key(comic)] = .now
        recent.removeAll { $0.source == comic.source && $0.id == comic.id }
        recent.insert(comic, at: 0)
        recent = Array(recent.prefix(100))
        saveOnline()
    }

    func removeRecent(_ comic: MangaOnlineComic) {
        syncStamps.removedRecent[MangaSyncStamps.key(comic)] = .now
        recent.removeAll { $0.source == comic.source && $0.id == comic.id }
        saveOnline()
    }

    func recordOnlinePage(_ page: Int, comic: MangaOnlineComic, chapter: MangaOnlineChapter) {
        syncStamps.pages["\(comic.source):\(comic.id):\(chapter.id)"] = .now
        onlinePages["\(comic.source):\(comic.id):\(chapter.id)"] = page
        saveOnline()
    }

    func onlinePage(comic: MangaOnlineComic, chapter: MangaOnlineChapter) -> Int {
        onlinePages["\(comic.source):\(comic.id):\(chapter.id)"] ?? 0
    }

    private func save() {
        if let data = try? JSONEncoder().encode(comics) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func saveStamps() {
        if let data = try? JSONEncoder().encode(readingSnapshot()) { try? data.write(to: readingStateURL, options: .atomic) }
        if let data = try? JSONEncoder().encode(syncStamps) { try? data.write(to: stampsURL, options: .atomic) }
        onReadingDataChanged?()
    }

    func readingSnapshot() -> MangaReadingSnapshot {
        MangaReadingSnapshot(favorites: favorites, recent: recent, readLater: readLater, pages: onlinePages, stamps: syncStamps)
    }

    func mergeReadingSnapshot(_ incoming: MangaReadingSnapshot) throws {
        let merged = try readingSnapshot().merging(incoming)
        favorites = merged.favorites; recent = merged.recent; readLater = merged.readLater
        onlinePages = merged.pages; syncStamps = merged.stamps
        if let data = try? JSONEncoder().encode(readLater) { try? data.write(to: readLaterURL, options: .atomic) }
        saveOnline()
    }

    private func saveOnline() {
        saveStamps()
        let value = OnlineState(favorites: favorites, recent: recent, pages: onlinePages)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: onlineURL, options: .atomic) }
    }

    private struct OnlineState: Codable {
        var favorites: [MangaOnlineComic]
        var recent: [MangaOnlineComic]
        var pages: [String: Int]
    }
}
