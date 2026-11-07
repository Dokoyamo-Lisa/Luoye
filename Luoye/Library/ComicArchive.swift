import Foundation
import PDFKit
import UIKit

/// 本地漫画分页。CBZ 按文件名自然排序，PDF 按文档页序。
struct ComicArchive {
    enum ArchiveError: LocalizedError {
        case noPages
        case unsupported

        var errorDescription: String? {
            switch self {
            case .noPages: "漫画中没有可阅读的图片。"
            case .unsupported: "漫画文件无法读取或包含暂不支持的压缩方式。"
            }
        }
    }

    private enum Storage {
        case cbz(ZipReader, [String])
        case pdf(PDFDocument)
        case folder([URL])
    }

    private let storage: Storage
    let pageCount: Int

    init(fileURL: URL, format: String) throws {
        switch format {
        case "cbz", "zip":
            let zip = try ZipReader(url: fileURL)
            let images = zip.entries.keys.filter { path in
                guard !path.hasPrefix("__MACOSX/"),
                      let last = path.split(separator: "/").last,
                      !last.hasPrefix(".") else { return false }
                return ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains((path as NSString).pathExtension.lowercased())
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard !images.isEmpty else { throw ArchiveError.noPages }
            storage = .cbz(zip, images)
            pageCount = images.count
        case "pdf":
            guard let document = PDFDocument(url: fileURL), document.pageCount > 0 else { throw ArchiveError.noPages }
            storage = .pdf(document)
            pageCount = document.pageCount
        case "folder":
            let files = try FileManager.default.contentsOfDirectory(at: fileURL, includingPropertiesForKeys: nil)
                .filter { ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard !files.isEmpty else { throw ArchiveError.noPages }
            storage = .folder(files)
            pageCount = files.count
        default:
            throw ArchiveError.unsupported
        }
    }

    /// ZIP/PDF indexing can be expensive; only the count crosses back to the reader.
    static func loadPageCount(fileURL: URL, format: String) async throws -> Int {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let count = try ComicArchive(fileURL: fileURL, format: format).pageCount
            try Task.checkCancellation()
            return count
        }
        return try await withTaskCancellationHandler {
            let count = try await worker.value
            try Task.checkCancellation()
            return count
        } onCancel: { worker.cancel() }
    }

    func imageData(at index: Int) throws -> Data? {
        guard index >= 0, index < pageCount else { return nil }
        switch storage {
        case .cbz(let zip, let paths):
            return try zip.read(paths[index])
        case .pdf(let document):
            guard let page = document.page(at: index) else { return nil }
            let size = page.bounds(for: .mediaBox).size
            let scale = min(2.0, 1500 / max(size.width, 1))
            return page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox).pngData()
        case .folder(let files):
            return try Data(contentsOf: files[index], options: .mappedIfSafe)
        }
    }
}
