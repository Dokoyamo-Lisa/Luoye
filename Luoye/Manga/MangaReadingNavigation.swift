import Foundation

enum MangaReadingMode: String, CaseIterable, Identifiable {
    case pageLeftToRight
    case pageRightToLeft
    case pageTopToBottom
    case continuousTopToBottom
    case continuousLeftToRight
    case continuousRightToLeft

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pageLeftToRight: "左右翻页"
        case .pageRightToLeft: "右向左翻页"
        case .pageTopToBottom: "上下翻页"
        case .continuousTopToBottom: "上下连续"
        case .continuousLeftToRight: "左右连续"
        case .continuousRightToLeft: "右向左连续"
        }
    }
    var isContinuous: Bool { rawValue.hasPrefix("continuous") }
    var isVertical: Bool { self == .pageTopToBottom || self == .continuousTopToBottom }
    var isRTL: Bool { self == .pageRightToLeft || self == .continuousRightToLeft }
}

struct MangaSpreadLayout {
    let imageCount: Int
    let coverAlone: Bool

    var spreads: [[Int]] {
        guard imageCount > 0 else { return [] }
        var result: [[Int]] = []
        var index = 0
        if coverAlone { result.append([0]); index = 1 }
        while index < imageCount {
            result.append(Array(index..<min(index + 2, imageCount)))
            index += 2
        }
        return result
    }

    func spread(for image: Int) -> Int {
        if coverAlone { return image == 0 ? 0 : 1 + (image - 1) / 2 }
        return image / 2
    }
}

/// Returns the first image of the next visible spread; other modes advance one image.
enum MangaReadingNavigation {
    static func visiblePages(at page: Int, count: Int, mode: MangaReadingMode, twoPage: Bool, coverAlone: Bool) -> [Int] {
        guard page >= 0, page < count else { return [] }
        if twoPage && (mode == .pageLeftToRight || mode == .pageRightToLeft) {
            let layout = MangaSpreadLayout(imageCount: count, coverAlone: coverAlone)
            return layout.spreads[layout.spread(for: page)]
        }
        return [page]
    }

    static func nextPage(after page: Int, count: Int, mode: MangaReadingMode, twoPage: Bool, coverAlone: Bool) -> Int? {
        guard page >= 0, page < count else { return nil }
        if twoPage && (mode == .pageLeftToRight || mode == .pageRightToLeft) {
            let layout = MangaSpreadLayout(imageCount: count, coverAlone: coverAlone)
            let next = layout.spread(for: page) + 1
            return layout.spreads.indices.contains(next) ? layout.spreads[next].first : nil
        }
        return page + 1 < count ? page + 1 : nil
    }
}

/// Any position, modal or setting change starts a fresh countdown.
struct MangaAutoPageClock: Hashable {
    let active: Bool
    let paused: Bool
    let chapterID: String
    let page: Int
    let count: Int
    let mode: MangaReadingMode
    let twoPage: Bool
    let coverAlone: Bool
    let seconds: Double
}

/// Waits for real image content and a stable end before advancing, including short chapters.
struct MangaScrollEndState {
    private var held = 0.0
    private var emitted = false

    mutating func reset() { held = 0; emitted = false }

    mutating func update(atEnd: Bool, contentReady: Bool, elapsed: Double) -> Bool {
        guard atEnd, contentReady else { reset(); return false }
        guard !emitted else { return false }
        held += max(0, min(elapsed, 0.05))
        guard held >= 3 else { return false }
        emitted = true
        return true
    }
}
