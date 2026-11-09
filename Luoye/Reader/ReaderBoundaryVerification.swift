#if DEBUG
import SwiftUI
import UIKit

/// Exercises the production UIKit reader coordinators; no user books, progress or preferences are changed.
@MainActor enum ReaderBoundaryVerification {
    private final class PositionBox { var value = ReadingPosition(chapter: 0, offset: 0) }
    static func run() async {
        var checks: [[String: Any]] = []
        func check(_ value: Bool, _ title: String) {
            checks.append(["passed": value, "title": title]); print("READER_BOUNDARY \(value ? "PASS" : "FAIL") \(title)")
        }
        let style = ReaderStyle(fontSize: 19, lineHeight: 1.85, scheme: .light, recognizesByline: false)
        let paragraph = String(repeating: "这是自写测试正文，用来确认末页边界不会跳过尚未阅读的内容。", count: 25)
        let chapters = [Chapter(id: 0, title: "自写第一章", paragraphs: [paragraph]), Chapter(id: 1, title: "自写第二章", paragraphs: [paragraph])]
        let content = BookContent(chapters: chapters, image: { _ in nil })
        let box = PositionBox(), binding = Binding(get: { box.value }, set: { box.value = $0 })
        var ends = 0
        let parent = PagedReader(content: content, style: style, size: CGSize(width: 390, height: 800), insets: UIEdgeInsets(top: 40, left: 24, bottom: 40, right: 24), position: binding, onTapCenter: {}, onReachEnd: { ends += 1 })
        let strip = PageStripView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        strip.update(parent)
        func settle() { for _ in 0 ..< 240 where strip.isMoving || strip.target != strip.x { strip.advance(by: 1.0 / 60) } }
        try? await Task.sleep(for: .milliseconds(30))
        check(strip.step(1), "forward tap within a multi-page chapter turns locally")
        settle()
        try? await Task.sleep(for: .milliseconds(30))
        check(ends == 0, "forward turn within a multi-page chapter does not request another chapter")
        box.value = ReadingPosition(chapter: 0, offset: style.attributedText(for: chapters[0]).length - 1)
        strip.update(strip.parent!)
        check(strip.step(1), "local chapter boundary still uses the next chapter already in BookContent")
        settle()
        try? await Task.sleep(for: .milliseconds(30))
        check(ends == 0 && box.value.chapter == 1, "crossing into the next local chapter reports its first page")
        box.value = ReadingPosition(chapter: 1, offset: style.attributedText(for: chapters[1]).length - 1)
        strip.update(strip.parent!)
        check(!strip.step(1), "final page has no forward neighbour")
        settle()
        try? await Task.sleep(for: .milliseconds(30))
        check(ends == 1, "forward tap at the final page emits an external boundary")
        var auto = strip.parent!; auto.forwardTurns += 1; strip.update(auto)
        settle()
        try? await Task.sleep(for: .milliseconds(30))
        check(ends == 2, "automatic page turn at the final page emits the same external boundary")
        strip.step(1)
        box.value = ReadingPosition(chapter: 0, offset: 0)
        strip.update(strip.parent!)
        try? await Task.sleep(for: .milliseconds(30))
        check(ends == 2, "queued final-page boundary cannot override a newer directory selection")
        box.value = ReadingPosition(chapter: 1, offset: style.attributedText(for: chapters[1]).length - 1)
        strip.update(strip.parent!)
        let endsBeforeTeardown = ends
        strip.step(1); strip.deactivate()
        try? await Task.sleep(for: .milliseconds(30))
        check(ends == endsBeforeTeardown, "queued page boundary after reader dismantles is ignored")

        let short = BookContent(chapters: [Chapter(id: 0, title: "自写第一章", paragraphs: ["自写短章正文。"]), Chapter(id: 1, title: "自写第二章", paragraphs: ["第二章自写正文。"])], image: { _ in nil })
        let scrollBox = PositionBox()
        var scrollEnds = 0
        let scrollParent = ScrollReader(content: short, style: style, size: CGSize(width: 390, height: 500), insets: UIEdgeInsets(top: 40, left: 24, bottom: 40, right: 24), position: Binding(get: { scrollBox.value }, set: { scrollBox.value = $0 }), speed: 0, onTap: {}, onReachEnd: { scrollEnds += 1 })
        let scrollCoordinator = scrollParent.makeCoordinator(), scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        scrollCoordinator.scrollView = scroll; scroll.delegate = scrollCoordinator
        scrollCoordinator.startTicking(); scrollCoordinator.refresh()
        let end = max(0, scroll.contentSize.height - scroll.bounds.height)
        check(end > 10, "scroll fixture includes multiple locally stitched chapters")
        scrollCoordinator.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = end / 2
        scrollCoordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        try? await Task.sleep(for: .milliseconds(30))
        check(scrollEnds == 0, "manual scroll before the end does not emit a boundary")
        scrollCoordinator.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = end + 20
        scrollCoordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        scrollCoordinator.scrollViewDidEndDecelerating(scroll)
        try? await Task.sleep(for: .milliseconds(30))
        check(scrollEnds == 1, "manual upward scroll at book end emits one boundary")
        scroll.contentOffset.y = 0
        scrollCoordinator.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = -20
        scrollCoordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        try? await Task.sleep(for: .milliseconds(30))
        check(scrollEnds == 1, "pulling downward at the start cannot advance chapters")
        scroll.contentOffset.y = 0
        scrollCoordinator.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = end + 20
        scrollCoordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        scrollBox.value = ReadingPosition(chapter: 0, offset: 0)
        scrollCoordinator.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        check(scrollEnds == 1, "queued scroll boundary cannot override a newer directory selection")
        let scrollEndsBeforeTeardown = scrollEnds
        scroll.contentOffset.y = 0
        scrollCoordinator.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = max(0, scroll.contentSize.height - scroll.bounds.height) + 20
        scrollCoordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        scrollCoordinator.stopTicking()
        try? await Task.sleep(for: .milliseconds(30))
        check(scrollEnds == scrollEndsBeforeTeardown, "queued scroll boundary after reader dismantles is ignored")
        scroll.delegate = nil
        let report: [String: Any] = ["success": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeReaderBoundaryVerification.json"), options: .atomic)
        }
    }
}
#endif
