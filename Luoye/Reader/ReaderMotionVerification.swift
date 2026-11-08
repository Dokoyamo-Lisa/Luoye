#if DEBUG
import SwiftUI
import UIKit

@MainActor enum ReaderMotionVerification {
    private final class Position { var value = ReadingPosition(chapter: 0, offset: 0) }
    private final class DeferredPageController: UIPageViewController {
        var finishTurn: ((Bool) -> Void)?
        override func setViewControllers(_ viewControllers: [UIViewController]?, direction: UIPageViewController.NavigationDirection, animated: Bool, completion: ((Bool) -> Void)? = nil) {
            super.setViewControllers(viewControllers, direction: direction, animated: false)
            if let completion { finishTurn = completion }
        }
    }
    static func run() async {
        var checks: [[String: Any]] = []
        func check(_ value: Bool, _ title: String) { checks.append(["passed": value, "title": title]); print("READER_MOTION \(value ? "PASS" : "FAIL") \(title)") }
        let style = ReaderStyle(fontSize: 19, lineHeight: 1.85, scheme: .light, recognizesByline: false)
        let chapters = (0..<9).map { Chapter(id: $0, title: "第\($0)章", paragraphs: ["自写短正文，用于验证章节接续时的位置稳定。"] ) }
        let content = BookContent(chapters: chapters, image: { _ in nil })
        let position = Position()
        let binding = Binding(get: { position.value }, set: { position.value = $0 })
        let parent = PagedReader(content: content, style: style, size: CGSize(width: 390, height: 800), insets: UIEdgeInsets(top: 40, left: 24, bottom: 40, right: 24), position: binding, onTapCenter: {})
        let coordinator = parent.makeCoordinator(), controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        coordinator.pageViewController = controller
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        coordinator.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        let original = controller.viewControllers?.first as? PageController
        coordinator.parent.showsFooterTitle = false; coordinator.refresh()
        let hidden = controller.viewControllers?.first as? PageController
        check(original === hidden, "hiding the footer does not recreate the page or repaginate text")
        coordinator.parent.showsFooterTitle = true; coordinator.refresh()
        check(controller.viewControllers?.first === hidden, "restoring the footer keeps the current rendered page")
        try? await Task.sleep(for: .milliseconds(30))
        let layout = ChapterLayout(text: style.attributedText(for: chapters[1]), pageSize: CGSize(width: 342, height: 720))
        let next = PageController(chapter: 1, page: 0, layout: layout, title: chapters[1].title, style: style, insets: parent.insets)
        controller.setViewControllers([next], direction: .forward, animated: false)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
        // A new directory selection happens before the previous page's async binding report executes.
        position.value = ReadingPosition(chapter: 7, offset: 5)
        try? await Task.sleep(for: .milliseconds(30))
        check(position.value == ReadingPosition(chapter: 7, offset: 5), "late page report cannot overwrite a newer directory selection")
        // Directory changes can arrive before UIKit finishes an interactive transition,
        // not only after didFinishAnimating queued its report.
        position.value = ReadingPosition(chapter: 0, offset: 0); coordinator.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        coordinator.pageViewController(controller, willTransitionTo: [next])
        position.value = ReadingPosition(chapter: 7, offset: 5); coordinator.refresh()
        controller.setViewControllers([next], direction: .forward, animated: false)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
        try? await Task.sleep(for: .milliseconds(60))
        check(position.value == ReadingPosition(chapter: 7, offset: 5), "directory selection during a completed swipe keeps its requested position")
        check((controller.viewControllers?.first as? PageController)?.chapter == 7, "completed old swipe renders the newer directory chapter")
        coordinator.pageViewController(controller, willTransitionTo: [next])
        position.value = ReadingPosition(chapter: 6, offset: 3); coordinator.refresh()
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: false)
        try? await Task.sleep(for: .milliseconds(60))
        check(position.value == ReadingPosition(chapter: 6, offset: 3) && (controller.viewControllers?.first as? PageController)?.chapter == 6, "cancelled swipe also applies a pending directory selection")
        coordinator.deactivate()
        controller.dataSource = nil; controller.delegate = nil

        let turnPosition = Position()
        let turnParent = PagedReader(content: content, style: style, size: parent.size, insets: parent.insets, position: Binding(get: { turnPosition.value }, set: { turnPosition.value = $0 }), onTapCenter: {})
        let turnCoordinator = turnParent.makeCoordinator()
        let turnController = DeferredPageController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        turnController.view.frame = controller.view.frame; turnCoordinator.pageViewController = turnController
        turnCoordinator.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        turnCoordinator.parent.forwardTurns += 1; turnCoordinator.refresh()
        check(turnController.finishTurn != nil, "programmatic page turn is held at its UIKit completion boundary")
        turnPosition.value = ReadingPosition(chapter: 8, offset: 4); turnCoordinator.refresh()
        turnController.finishTurn?(true); turnController.finishTurn = nil
        try? await Task.sleep(for: .milliseconds(60))
        check(turnPosition.value == ReadingPosition(chapter: 8, offset: 4), "directory selection during an animated page turn is not overwritten")
        check((turnController.viewControllers?.first as? PageController)?.chapter == 8, "animated page-turn completion renders the newer directory chapter")
        turnCoordinator.deactivate()

        // An automatic command that expires while a finger holds a page must not
        // run against the next page immediately after UIKit finishes the swipe.
        for completed in [true, false] {
            let swipePosition = Position()
            var interactions: [Bool] = []
            var redrawAfterInteraction: (() -> Void)?
            let swipeParent = PagedReader(content: content, style: style, size: parent.size, insets: parent.insets, position: Binding(get: { swipePosition.value }, set: { swipePosition.value = $0 }), onTapCenter: {}, onInteractionChanged: { _, active in
                interactions.append(active)
                // Updating the outer pause state schedules a SwiftUI redraw.
                if !active { DispatchQueue.main.async { redrawAfterInteraction?() } }
            })
            let swipeCoordinator = swipeParent.makeCoordinator()
            redrawAfterInteraction = { [weak swipeCoordinator] in swipeCoordinator?.refresh() }
            let swipeController = DeferredPageController(transitionStyle: .scroll, navigationOrientation: .horizontal)
            swipeController.view.frame = controller.view.frame; swipeCoordinator.pageViewController = swipeController
            swipeCoordinator.refresh()
            try? await Task.sleep(for: .milliseconds(30))
            let start = swipeController.viewControllers!.first!
            let destination = swipeCoordinator.pageViewController(swipeController, viewControllerAfter: start)!
            swipeCoordinator.pageViewController(swipeController, willTransitionTo: [destination])
            swipeCoordinator.parent.forwardTurns += 1; swipeCoordinator.refresh()
            if completed { swipeController.setViewControllers([destination], direction: .forward, animated: false) }
            swipeCoordinator.pageViewController(swipeController, didFinishAnimating: true, previousViewControllers: [start], transitionCompleted: completed)
            try? await Task.sleep(for: .milliseconds(60))
            let expectedChapter = completed ? 1 : 0
            check(interactions == [true, false], completed ? "completed swipe pauses and restarts its automatic countdown" : "cancelled swipe also restarts its automatic countdown")
            check((swipeController.viewControllers?.first as? PageController)?.chapter == expectedChapter, completed ? "expired automatic turn cannot skip the newly swiped page" : "expired automatic turn cannot move a cancelled swipe")
            check(swipeController.finishTurn == nil, completed ? "completed swipe does not queue an extra animated turn" : "cancelled swipe does not queue an automatic animation")
            swipeCoordinator.pageViewController(swipeController, willTransitionTo: [destination])
            swipeCoordinator.deactivate()
            swipeCoordinator.pageViewController(swipeController, didFinishAnimating: true, previousViewControllers: [start], transitionCompleted: completed)
            try? await Task.sleep(for: .milliseconds(30))
            check(interactions == [true, false, true, false], "removed reader releases its pending swipe exactly once")
            swipeController.finishTurn = nil
        }

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
