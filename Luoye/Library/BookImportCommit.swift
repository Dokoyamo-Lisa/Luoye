import Foundation
import SwiftData

/// The main-actor commit boundary for prepared online books; owns cleanup until a successful save.
@MainActor enum BookImportCommit {
    static func hasLocalFile(_ book: Book) -> Bool {
        guard let values = try? book.fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
    static func commit(_ prepared: PreparedBookImport, context: ModelContext,
                       matchingID: UUID? = nil, legacyFileName: String? = nil) throws -> Book {
        do { try Task.checkCancellation() }
        catch { prepared.removeFiles(); throw error }
        let rows: [Book]
        do { rows = try context.fetch(FetchDescriptor<Book>()) }
        catch { prepared.removeFiles(); throw error }
        let existing = rows.first {
            (matchingID != nil && $0.id == matchingID) ||
            (prepared.source != nil && $0.sourceKey == prepared.source) ||
            (legacyFileName != nil && $0.fileName == legacyFileName)
        }
        if let existing {
            if existing.fileName != prepared.fileName, hasLocalFile(existing) {
                prepared.removeFiles(); return existing
            }
            // Restore a missing file while retaining Book identity, bookmarks and reading position.
            let previous = (existing.fileName, existing.format, existing.coverFileName, existing.sourceKey, existing.editionNote)
            existing.fileName = prepared.fileName; existing.format = prepared.format
            existing.coverFileName = prepared.cover ?? existing.coverFileName
            existing.sourceKey = existing.sourceKey ?? prepared.source
            existing.editionNote = prepared.note ?? existing.editionNote
            do { try context.save() }
            catch {
                existing.fileName = previous.0; existing.format = previous.1; existing.coverFileName = previous.2
                existing.sourceKey = previous.3; existing.editionNote = previous.4
                prepared.removeFiles(); throw error
            }
            if previous.0 != prepared.fileName, !rows.contains(where: { $0.id != existing.id && $0.fileName == previous.0 }) {
                let oldFile = BookStorage.directory.appending(path: previous.0)
                if (try? oldFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { try? FileManager.default.removeItem(at: oldFile) }
            }
            if let oldCover = previous.2, oldCover != existing.coverFileName, !rows.contains(where: { $0.id != existing.id && $0.coverFileName == oldCover }) {
                try? FileManager.default.removeItem(at: BookStorage.directory.appending(path: oldCover))
            }
            return existing
        }
        let book = prepared.makeBook()
        context.insert(book)
        do { try context.save() }
        catch { context.delete(book); prepared.removeFiles(); throw error }
        return book
    }
}
