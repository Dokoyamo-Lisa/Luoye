#if DEBUG
import SwiftUI
import UIKit

@MainActor enum ReaderProgressVerification {
    private final class Position { var value = ReadingPosition(chapter: 0, offset: 0) }
    static func run() async {
        var checks: [[String: Any]] = []
        let style = ReaderStyle(fontSize: 19, lineHeight: 1.85, scheme: .light, recognizesByline: false)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { c in UIColor.red.setFill(); c.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }.pngData()!
        let chapters = [
            Chapter(id: 0, title: "章节标题也在阅读偏移里", paragraphs: [String(repeating: "文", count: 100)]),
            Chapter(id: 0, title: "", paragraphs: [String(repeating: "🐱", count: 50)]),
            Chapter(id: 0, title: "注音", paragraphs: [String(InlineMark.rubyStart) + "汉字" + String(InlineMark.separator) + "han zi reading" + String(InlineMark.end)]),
            Chapter(id: 0, title: "插图", paragraphs: [String(InlineMark.image) + "long/image/path/that/is/not/visible/on/the/page.png", "正文"])
        ]
        for (index, chapter) in chapters.enumerated() {
            let rendered = style.attributedText(for: chapter, images: { _ in png }).length
            let offset = rendered / 2
            let value = ReaderProgress.fraction(position: ReadingPosition(chapter: 0, offset: offset), chapters: [chapter], renderedLength: rendered)
            let expected = Double(offset) / Double(rendered)
            checks.append(["passed": abs(value - expected) < 0.0001, "title": "rendered progress case \(index): title, emoji, ruby or image", "actual": value, "expected": expected])
        }
        func check(_ value: Bool, _ title: String) { checks.append(["passed": value, "title": title]) }
        check(ReaderProgress.fraction(position: ReadingPosition(chapter: 0, offset: 100), chapters: []) == 0, "empty content has zero progress")
        check(ReaderProgress.fraction(position: ReadingPosition(chapter: -1, offset: -1), chapters: chapters, renderedLength: 100) == 0, "negative offsets and chapter indexes clamp safely")
        check(ReaderProgress.fraction(position: ReadingPosition(chapter: 99, offset: 999), chapters: chapters, renderedLength: 100) == 1, "past-end offsets and chapter indexes clamp safely")
        let content = BookContent(chapters: chapters, image: { _ in png })
        let box = Position(), binding = Binding(get: { box.value }, set: { box.value = $0 })
        var pagedLengths: [(Int, Int)] = []
        let insets = UIEdgeInsets(top: 40, left: 24, bottom: 40, right: 24)
        let parent = PagedReader(content: content, style: style, size: CGSize(width: 390, height: 800), insets: insets, position: binding, onTapCenter: {}, onChapterLength: { pagedLengths.append(($0, $1)) })
        let strip = PageStripView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        strip.update(parent)
        try? await Task.sleep(for: .milliseconds(30))
        check(pagedLengths.count == 1 && pagedLengths.first?.1 == style.attributedText(for: chapters[0]).length, "paged reader reports the existing rendered storage length")
        box.value = ReadingPosition(chapter: 1, offset: 0); strip.update(strip.parent!)
        box.value = ReadingPosition(chapter: 2, offset: 0)
        try? await Task.sleep(for: .milliseconds(30))
        check(pagedLengths.count == 1, "stale page metrics cannot override a newer selection")
        strip.deactivate()
        box.value = ReadingPosition(chapter: 0, offset: 0)
        var scrollLengths: [(Int, Int)] = []
        let scrollParent = ScrollReader(content: content, style: style, size: parent.size, insets: insets, position: binding, speed: 0, onTap: {}, onReachEnd: {}, onChapterLength: { scrollLengths.append(($0, $1)) })
        let scrollCoordinator = scrollParent.makeCoordinator(), scroll = UIScrollView(frame: CGRect(origin: .zero, size: parent.size))
        scrollCoordinator.scrollView = scroll; scroll.delegate = scrollCoordinator; scrollCoordinator.startTicking(); scrollCoordinator.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        check(scrollLengths.count == 1 && scrollLengths.first?.1 == style.attributedText(for: chapters[0]).length, "scroll reader reports the existing rendered storage length")
        box.value = ReadingPosition(chapter: 1, offset: 0); scrollCoordinator.refresh()
        box.value = ReadingPosition(chapter: 2, offset: 0)
        try? await Task.sleep(for: .milliseconds(30))
        check(scrollLengths.count == 1, "stale scroll metrics cannot override a newer selection")
        scrollCoordinator.refresh(); scrollCoordinator.stopTicking()
        try? await Task.sleep(for: .milliseconds(30))
        check(scrollLengths.count == 1, "dismantled scroll reader drops queued progress metrics")
        scroll.delegate = nil
        let excerpts: [(String, String, String)] = [
            ("标题\n🐱🐱准确摘录\n后文", "准确摘录", "准确摘录"),
            ("标题\n👨‍👩‍👧‍👦接下来的正文", "接下来的正文", "接下来的正文"),
            ("标题\nCafe\u{0301} 正文", "正文", "正文"),
            ("标题\n" + String(repeating: "🐱", count: 300), String(repeating: "🐱", count: 40), String(repeating: "🐱", count: 40) + "…")
        ]
        for (index, sample) in excerpts.enumerated() {
            let location = index == 3 ? 450 : (sample.0 as NSString).range(of: sample.1).location
            let actual = Bookmark.excerpt(from: sample.0, at: location, skippingTitle: "标题")
            checks.append(["passed": actual == sample.2, "title": "UTF-16 bookmark excerpt case \(index)", "actual": actual, "expected": sample.2])
        }
        let family = "👨‍👩‍👧‍👦"
        check(Bookmark.excerpt(from: "标题\n" + family + "正文", at: 4, skippingTitle: "标题") == family + "正文", "offset inside a surrogate pair preserves the entire composed emoji")
        check(Bookmark.excerpt(from: "🐱标题\n正文", at: 1, skippingTitle: "🐱标题") == "正文", "emoji headings are skipped in the rendered offset space")
        check(Bookmark.excerpt(from: "标题\n正文", at: -99, skippingTitle: "标题") == "正文", "negative excerpt offsets clamp to the chapter beginning")
        check(Bookmark.excerpt(from: "标题\n正文", at: 999, skippingTitle: "标题").isEmpty, "past-end excerpt offsets return an empty excerpt")
        check(Bookmark.excerpt(from: "标题\n" + String(repeating: family, count: 41), at: 3, skippingTitle: "标题") == String(repeating: family, count: 40) + "…", "excerpt length limit never splits a composed emoji")
        let report: [String: Any] = ["success": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeReaderProgressVerification.json"), options: .atomic) }
    }
}
#endif
