import Foundation

/// Immutable file metadata crosses the worker boundary, never a SwiftData model.
struct PreparedBookImport: Sendable {
    let id: UUID
    let title: String
    let author: String
    let format: String
    let fileName: String
    let cover: String?
    let source: String?
    let note: String?
    init(_ book: Book) {
        id = book.id; title = book.title; author = book.author; format = book.format
        fileName = book.fileName; cover = book.coverFileName; source = book.sourceKey; note = book.editionNote
    }
    @MainActor func makeBook() -> Book {
        Book(id: id, title: title, author: author, format: format, fileName: fileName, coverFileName: cover, sourceKey: source, editionNote: note)
    }
    func removeFiles() {
        try? FileManager.default.removeItem(at: BookStorage.directory.appending(path: fileName))
        if let cover { try? FileManager.default.removeItem(at: BookStorage.directory.appending(path: cover)) }
    }
}
