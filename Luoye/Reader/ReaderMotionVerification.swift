#if DEBUG
import SwiftUI
import UIKit

@MainActor enum ReaderMotionVerification {
    private final class Position { var value = ReadingPosition(chapter: 0, offset: 0) }
    static func run() async {
        var checks: [[String: Any]] = []
        func check(_ value: Bool, _ title: String) { checks.append(["passed": value, "title": title]); print("READER_MOTION \(value ? "PASS" : "FAIL") \(title)") }
        let style = ReaderStyle(fontSize: 19, lineHeight: 1.85, scheme: .light, recognizesByline: false)
        let chapters = (0..<9).map { Chapter(id: $0, title: "第\($0)章", paragraphs: ["自写短正文，用于验证章节接续时的位置稳定。"] ) }
        let content = BookContent(chapters: chapters, image: { _ in nil })
        let position = Position()
        let binding = Binding(get: { position.value }, set: { position.value = $0 })
        let parent = PagedReader(content: content, style: style, size: CGSize(width: 390, height: 800), insets: UIEdgeInsets(top: 40, left: 24, bottom: 40, right: 24), position: binding, onTapCenter: {})
        let strip = PageStripView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        strip.update(parent)
        func settle() { for _ in 0 ..< 240 where strip.isMoving || strip.target != strip.x { strip.advance(by: 1.0 / 60) } }
        try? await Task.sleep(for: .milliseconds(30))
        let original = strip.currentPage
        var hiddenFooter = strip.parent!; hiddenFooter.showsFooterTitle = false; strip.update(hiddenFooter)
        check(strip.currentPage === original && original?.footerTitle == "", "hiding the footer does not recreate the page or repaginate text")
        var shownFooter = strip.parent!; shownFooter.showsFooterTitle = true; strip.update(shownFooter)
        check(strip.currentPage === original && original?.footerTitle == "第0章", "restoring the footer keeps the current rendered page")

        // 连点三下：动画不断档，三下都算数，停在第三页。
        strip.step(1); strip.advance(by: 0.03)
        strip.step(1); strip.advance(by: 0.03)
        strip.step(1)
        check(strip.target - strip.x > 1.5, "rapid taps queue onto the moving page strip instead of being dropped")
        settle()
        try? await Task.sleep(for: .milliseconds(30))
        check(position.value == ReadingPosition(chapter: 3, offset: 0) && strip.currentPage?.ref.chapter == 3, "three rapid taps land exactly three pages ahead")
        for _ in 0 ..< 8 { strip.step(1) }
        check(strip.target - strip.x <= 3.01, "a burst of taps leads the visible page by at most three pages")
        settle()
        try? await Task.sleep(for: .milliseconds(30))
        check(position.value.chapter == 6, "a capped burst of taps settles on a real page and reports it")
        strip.step(-1); strip.step(-1)
        settle()
        try? await Task.sleep(for: .milliseconds(30))
        check(position.value.chapter == 4, "backward taps queue the same way")

        // 翻页途中点了目录：目录赢，动画作废，不会再被旧动画写回去。
        strip.step(1); strip.advance(by: 0.05)
        position.value = ReadingPosition(chapter: 7, offset: 5); strip.update(strip.parent!)
        settle()
        try? await Task.sleep(for: .milliseconds(60))
        check(position.value == ReadingPosition(chapter: 7, offset: 5), "directory selection during a page turn keeps its requested position")
        check(strip.currentPage?.ref.chapter == 7 && !strip.isMoving, "directory selection during a page turn renders the newer chapter at rest")

        // 自动翻页的指令只在页带上加一页，与手动连点叠加也不会跳页。
        position.value = ReadingPosition(chapter: 5, offset: 0); strip.update(strip.parent!)
        try? await Task.sleep(for: .milliseconds(30))
        var turn = strip.parent!; turn.forwardTurns += 1; strip.update(turn)
        strip.step(1)
        settle()
        try? await Task.sleep(for: .milliseconds(30))
        check(position.value.chapter == 7, "an automatic turn and a tap together advance exactly two pages")
        strip.step(1); settle()
        check(!strip.step(1), "the last page refuses to move past the end")
        settle()
        check(strip.currentPage?.ref.chapter == 8 && strip.x == 0, "the end-of-book nudge springs back to the last page")
        strip.deactivate()

        // iPad 横屏：摊开两页，翻一下前进两页；右页绕书脊翻到左边。
        let longChapters = (0..<3).map { Chapter(id: $0, title: "第\($0)章", paragraphs: Array(repeating: "摊开的书页，一页接着一页，翻过去的是右页，落下来的是下一屏的左页。", count: 60)) }
        let spreadPosition = Position()
        let spreadParent = PagedReader(content: BookContent(chapters: longChapters, image: { _ in nil }), style: style, size: CGSize(width: 1210, height: 834),
                                       insets: UIEdgeInsets(top: 60, left: 82, bottom: 70, right: 82),
                                       position: Binding(get: { spreadPosition.value }, set: { spreadPosition.value = $0 }), onTapCenter: {},
                                       columns: 2, columnGap: 96)
        let book = PageStripView(frame: CGRect(x: 0, y: 0, width: 1210, height: 834))
        book.update(spreadParent)
        try? await Task.sleep(for: .milliseconds(30))
        let firstLayout = book.layout(for: 0)
        book.step(1)
        for _ in 0 ..< 240 where book.isMoving { book.advance(by: 1.0 / 60) }
        try? await Task.sleep(for: .milliseconds(30))
        check(firstLayout.pageCount > 4 && spreadPosition.value == ReadingPosition(chapter: 0, offset: firstLayout.characterRange(ofPage: 2).location),
              "one turn on a two-page spread advances exactly two pages")
        spreadPosition.value = ReadingPosition(chapter: 0, offset: firstLayout.characterRange(ofPage: 5).location + 3); book.update(book.parent!)
        try? await Task.sleep(for: .milliseconds(30))
        check(book.anchor == .init(chapter: 0, page: 2), "a position on a right-hand page opens the spread that contains it")
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.addSubview(book)
            book.step(1); book.advance(by: 0.09)
            book.setNeedsLayout(); book.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
            let image = UIGraphicsImageRenderer(bounds: book.bounds).image { _ in book.drawHierarchy(in: book.bounds, afterScreenUpdates: true) }
            try? image.pngData()?.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeSpreadFlip.png"))
            book.removeFromSuperview()
        }
        book.deactivate()

        // 划得太短、没被认成拖动的一下：按划的方向翻页，不能按落点当成点击往回翻。
        let left = CGPoint(x: 60, y: 400)
        check(PageStripView.tapIntent(down: left, up: CGPoint(x: 62, y: 403), width: 390) == .tap, "a still finger on the left edge is a tap")
        check(PageStripView.tapIntent(down: left, up: CGPoint(x: 52, y: 401), width: 390) == .flick(1), "a short leftward flick on the left edge turns forward, not back")
        check(PageStripView.tapIntent(down: left, up: CGPoint(x: 70, y: 402), width: 390) == .flick(-1), "a short rightward flick turns back")
        check(PageStripView.tapIntent(down: left, up: CGPoint(x: 63, y: 430), width: 390) == .ignore, "a short downward swipe never turns a page")

        let scrollPosition = Position(); scrollPosition.value = ReadingPosition(chapter: 5, offset: 0)
        let scrollParent = ScrollReader(content: content, style: style, size: CGSize(width: 390, height: 800), insets: parent.insets, position: Binding(get: { scrollPosition.value }, set: { scrollPosition.value = $0 }), speed: 0, onTap: {}, onReachEnd: {})
        let scrollCoordinator = scrollParent.makeCoordinator(), scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        scrollCoordinator.scrollView = scroll; scroll.delegate = scrollCoordinator
        scrollCoordinator.refresh()
        let views = scroll.subviews.compactMap { $0 as? UITextView }
        let titles = views.map { $0.text.components(separatedBy: "\n").first ?? "" }
        check(titles.count == Set(titles).count, "prepending short chapters never inserts duplicate chapter views")
        check(scrollPosition.value == ReadingPosition(chapter: 5, offset: 0), "initial chapter assembly does not report intermediate scroll positions")
        let before = scroll.subviews.compactMap { $0 as? UITextView }.first { $0.text.hasPrefix("第5章\n") }
        let visualY = before.map { $0.frame.minY - scroll.contentOffset.y }
        check(visualY != nil && abs(visualY! - parent.insets.top) < 1, "prepending preserves the selected chapter at the same visual anchor")
        var changedInsets = parent.insets; changedInsets.top += 20
        scrollCoordinator.parent = ScrollReader(content: content, style: style, size: scrollParent.size, insets: changedInsets, position: scrollParent.$position, speed: 0, onTap: {}, onReachEnd: {})
        scrollCoordinator.refresh()
        let changed = scroll.subviews.compactMap { $0 as? UITextView }.first { $0.text.hasPrefix("第5章\n") }
        check(changed != nil && abs(changed!.frame.minY - scroll.contentOffset.y - scrollCoordinator.parent.insets.top) < 1, "safe-area inset changes rebuild around the same reading position")
        // Observe real CADisplayLink callbacks, including paused/manual reading.
        func speed(_ value: CGFloat) {
            scrollCoordinator.parent = ScrollReader(content: content, style: style, size: scrollParent.size, insets: changedInsets, position: scrollParent.$position, speed: value, onTap: {}, onReachEnd: {})
            scrollCoordinator.refresh()
        }
        scrollCoordinator.startTicking()
        try? await Task.sleep(for: .milliseconds(250))
        check(scrollCoordinator.displayTickCount == 0, "manual scrolling does not run a display-link loop")
        speed(40)
        let initialTicks = scrollCoordinator.displayTickCount
        try? await Task.sleep(for: .milliseconds(250))
        check(scrollCoordinator.displayTickCount > initialTicks, "automatic scrolling starts its display-link loop")
        speed(0)
        let pausedTicks = scrollCoordinator.displayTickCount
        let pausedOffset = scroll.contentOffset.y
        try? await Task.sleep(for: .milliseconds(300))
        check(scrollCoordinator.displayTickCount == pausedTicks && scroll.contentOffset.y == pausedOffset, "paused scrolling schedules no frame callbacks or movement")
        speed(40)
        try? await Task.sleep(for: .milliseconds(200))
        check(scrollCoordinator.displayTickCount > pausedTicks && scroll.contentOffset.y - pausedOffset < 15, "resuming restarts smoothly without replaying paused time")
        let beforeSlow = scroll.contentOffset.y
        speed(10)
        try? await Task.sleep(for: .milliseconds(250))
        let slowDistance = scroll.contentOffset.y - beforeSlow
        let beforeFast = scroll.contentOffset.y
        speed(100)
        try? await Task.sleep(for: .milliseconds(250))
        let fastDistance = scroll.contentOffset.y - beforeFast
        check(slowDistance > 0 && fastDistance > slowDistance * 3, "changing scroll speed adjusts movement without pausing")
        var dragEvents: [Bool] = []
        scrollCoordinator.parent = ScrollReader(content: content, style: style, size: scrollParent.size, insets: changedInsets,
                                                position: scrollParent.$position, speed: 0, onTap: {}, onReachEnd: {},
                                                onManualScrollChanged: { _, active in dragEvents.append(active) })
        scrollCoordinator.refresh()
        scrollCoordinator.scrollViewWillBeginDragging(scroll)
        scrollCoordinator.scrollViewDidEndDragging(scroll, willDecelerate: true)
        check(dragEvents == [true], "automatic scrolling remains paused during swipe deceleration")
        scrollCoordinator.scrollViewDidEndDecelerating(scroll)
        check(dragEvents == [true, false], "automatic scrolling resumes only after deceleration")
        scrollCoordinator.scrollViewWillBeginDragging(scroll)
        scrollCoordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        check(dragEvents == [true, false, true, false], "a swipe without deceleration resumes on release")
        scrollCoordinator.stopTicking(); scroll.delegate = nil
        let report: [String: Any] = ["success": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeReaderMotionVerification.json"), options: .atomic) }
    }
}
#endif
