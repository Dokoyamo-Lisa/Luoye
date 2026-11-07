import Foundation
import SwiftData

/// 书斋里的一本书。原文件复制到 App 自己的目录里，这里只记书名、作者等信息。
@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String
    /// "txt"、"epub"、"mobi"、"fb2"、"md"
    var format: String
    /// 原文件在 BookStorage.directory 里的文件名
    var fileName: String
    /// 封面图片文件名（有封面图时保存）
    var coverFileName: String?
    /// 书源与原站版本标识，如 "wenku8:1234" 或 "zlib:6125207"
    var sourceKey: String?
    /// 版本或格式说明，如 "EPUB · 中文"
    var editionNote: String?
    var addedAt: Date
    /// 读到第几章、章内第几个字
    var readingChapter: Int = 0
    var readingOffset: Int = 0
    /// 读到全书的几成，供书架和阅读器显示进度。
    var progress: Double = 0
    var lastOpenedAt: Date?

    init(
        id: UUID,
        title: String,
        author: String,
        format: String,
        fileName: String,
        coverFileName: String?,
        sourceKey: String? = nil,
        editionNote: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.fileName = fileName
        self.coverFileName = coverFileName
        self.sourceKey = sourceKey
        self.editionNote = editionNote
        self.addedAt = .now
    }

    var fileURL: URL { BookStorage.directory.appending(path: fileName) }
    var coverURL: URL? { coverFileName.map { BookStorage.directory.appending(path: $0) } }
}

/// 书籍文件存放的位置：App 的 Application Support/Books。
enum BookStorage {
    static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Books", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 删除一本书留下的所有文件。
    static func removeFiles(of book: Book) {
        try? FileManager.default.removeItem(at: book.fileURL)
        if let cover = book.coverURL {
            try? FileManager.default.removeItem(at: cover)
        }
    }
}
