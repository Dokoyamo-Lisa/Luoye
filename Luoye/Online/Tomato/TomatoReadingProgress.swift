import Foundation
import Observation

/// Observable navigation state; existing per-chapter offsets remain compatible with previous builds.
@MainActor @Observable
final class TomatoReadingProgress {
    private let defaults: UserDefaults
    private var lastChapters: [String: String] = [:]
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func lastChapter(bookID: String) -> String? {
        lastChapters[bookID] ?? defaults.string(forKey: "haiku.tomato.lastChapter.\(bookID)")
    }
    func offset(chapterID: String) -> Int {
        max(0, defaults.integer(forKey: "haiku.tomato.offset.\(chapterID)"))
    }
    func save(bookID: String, chapterID: String, offset: Int) {
        guard TomatoBookID.valid(bookID), TomatoBookID.valid(chapterID) else { return }
        if lastChapters[bookID] != chapterID { lastChapters[bookID] = chapterID }
        defaults.set(chapterID, forKey: "haiku.tomato.lastChapter.\(bookID)")
        defaults.set(max(0, offset), forKey: "haiku.tomato.offset.\(chapterID)")
    }
}
