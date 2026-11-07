import Foundation
import SwiftData

/// 一枚书签：哪本书、第几章、章内第几个字，外加一小段摘录，列表里一眼认得出是哪里。
@Model
final class Bookmark {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var chapter: Int
    var offset: Int
    var chapterTitle: String
    var excerpt: String
    var createdAt: Date

    init(bookID: UUID, chapter: Int, offset: Int, chapterTitle: String, excerpt: String) {
        self.id = UUID()
        self.bookID = bookID
        self.chapter = chapter
        self.offset = offset
        self.chapterTitle = chapterTitle
        self.excerpt = excerpt
        self.createdAt = .now
    }

    /// 从这一页开头取一句话做摘录：跳过章名和空白，最多 40 个字。
    static func excerpt(from text: String, at offset: Int, skippingTitle title: String) -> String {
        let source = text as NSString
        var location = min(max(offset, 0), source.length)
        // Reader offsets come from TextKit. Keep UTF-16 indexing and move malformed
        // offsets to the beginning of a complete composed character.
        if location < source.length {
            location = source.rangeOfComposedCharacterSequence(at: location).location
        }
        var start = String.Index(utf16Offset: location, in: text)
        if !title.isEmpty, let heading = text.range(of: title, options: .anchored), start < heading.upperBound {
            start = heading.upperBound
        }
        let snippet = text[start...]
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return snippet.count > 40 ? String(snippet.prefix(40)) + "…" : snippet
    }
}
