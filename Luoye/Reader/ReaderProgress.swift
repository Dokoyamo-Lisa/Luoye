import Foundation

/// Reading offsets and lengths share the rendered chapter's UTF-16 coordinate space.
enum ReaderProgress {
    static func fraction(position: ReadingPosition, chapters: [Chapter], renderedLength: Int? = nil) -> Double {
        guard !chapters.isEmpty else { return 0 }
        let current = min(max(position.chapter, 0), chapters.count - 1)
        let within: Double
        if let renderedLength, renderedLength > 0 {
            within = Double(min(max(position.offset, 0), renderedLength)) / Double(renderedLength)
        } else {
            within = 0
        }
        return (Double(current) + within) / Double(chapters.count)
    }
}
