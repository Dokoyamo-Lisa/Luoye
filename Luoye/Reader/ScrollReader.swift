import SwiftUI
import UIKit

/// 自动滚动模式：各章正文上下接成一长条，像片尾字幕一样匀速往上走。
/// 手指拖动时让位给手指，松手后接着滚；滚到全书末尾停下。
struct ScrollReader: UIViewRepresentable {
    let content: BookContent
    let style: ReaderStyle
    /// 整个阅读区的大小（含安全区）
    let size: CGSize
    /// 正文离四边的距离（与翻页模式相同，保证一行字数一致）
    let insets: UIEdgeInsets
    @Binding var position: ReadingPosition
    /// 每秒往上走多少点
    let speed: CGFloat
    var onTap: () -> Void
    var onReachEnd: () -> Void
    var onChapterLength: (Int, Int) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        scrollView.addGestureRecognizer(tap)
        context.coordinator.scrollView = scrollView
        context.coordinator.startTicking()
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh()
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.stopTicking()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ScrollReader
        weak var scrollView: UIScrollView?

        /// 已经铺进滚动区的章节，按顺序
        private var sections: [(chapter: Int, view: UITextView)] = []
        private var builtStyle: ReaderStyle?
        private var builtSize: CGSize?
        private var builtInsets: UIEdgeInsets?
        private var isLayingOut = false
        /// 最近一次由滚动上报出去的位置；外面改的位置（如目录跳转）与它不同，就重新铺
        private var reported: ReadingPosition?
        private var lastReportTime: CFTimeInterval = 0
        private var displayLink: CADisplayLink?
        #if DEBUG
        private(set) var displayTickCount = 0
        #endif
        private var lastTick: CFTimeInterval?
        /// 累积不足一个像素的位移，慢速时也能平滑前进
        private var carry: CGFloat = 0
        private var endNotified = false
        private var boundaryRevision = UUID()
        private var shortChapterDistance: CGFloat = 0
        private var dragStartY: CGFloat = 0
        private var draggedForward = false

        init(parent: ScrollReader) {
            self.parent = parent
        }

        private var gap: CGFloat { parent.style.linePitch * 3 }
        private var textWidth: CGFloat { parent.size.width - parent.insets.left - parent.insets.right }

        func refresh() {
            updateTicking()
            guard textWidth > 0, parent.size.height > 0, !parent.content.chapters.isEmpty, let scrollView else { return }
            if parent.style != builtStyle || parent.size != builtSize || parent.insets != builtInsets || parent.position != reported {
                if builtStyle == nil || UIAccessibility.isReduceMotionEnabled {
                    build(from: parent.position)
                } else {
                    // 目录跳转、换字号等：淡入淡出地换过去。
                    UIView.transition(with: scrollView, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
                        self.build(from: self.parent.position)
                    }
                }
            }
        }

        // MARK: 铺正文

        private func build(from position: ReadingPosition) {
            guard let scrollView else { return }
            isLayingOut = true
            defer { isLayingOut = false }
            boundaryRevision = UUID()
            endNotified = false; shortChapterDistance = 0
            sections.forEach { $0.view.removeFromSuperview() }
            sections = []
            builtStyle = parent.style
            builtSize = parent.size
            builtInsets = parent.insets

            let chapter = min(max(position.chapter, 0), parent.content.chapters.count - 1)
            append(chapter)

            // 让当前读到的那一行出现在正文区顶端；前后章节等位置定好再接。
            let view = sections[0].view
            var y: CGFloat = 0
            let manager = view.layoutManager
            manager.ensureLayout(for: view.textContainer)
            let length = view.textStorage.length
            if length > 0, position.offset > 0 {
                let glyph = manager.glyphIndexForCharacter(at: min(position.offset, length - 1))
                y = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }
            scrollView.contentOffset = CGPoint(x: 0, y: max(0, view.frame.minY + y - parent.insets.top))
            reported = position
            appendIfNeeded()
            let revision = boundaryRevision, expected = parent.position
            DispatchQueue.main.async { [weak self] in
                guard let self, self.boundaryRevision == revision, self.parent.position == expected else { return }
                self.parent.onChapterLength(chapter, length)
            }
        }

        private func makeTextView(for chapter: Int) -> UITextView {
            // 用 TextKit 1：排版是即时完成的，量位置不会因为“还没排到”而得到 0。
            let view = UITextView(usingTextLayoutManager: false)
            view.isEditable = false
            view.isSelectable = false
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.attributedText = parent.style.attributedText(for: parent.content.chapters[chapter], images: parent.content.image)
            let height = view.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            view.frame = CGRect(x: parent.insets.left, y: 0, width: textWidth, height: height)
            return view
        }

        private func append(_ chapter: Int) {
            guard let scrollView else { return }
            let view = makeTextView(for: chapter)
            view.frame.origin.y = sections.last.map { $0.view.frame.maxY + gap } ?? parent.insets.top
            scrollView.addSubview(view)
            sections.append((chapter, view))
            updateContentSize()
        }

        private func updateContentSize() {
            guard let scrollView, let tail = sections.last else { return }
            // 末尾留出半屏空白，最后一行也能滚到中间。
            scrollView.contentSize = CGSize(width: parent.size.width, height: tail.view.frame.maxY + parent.size.height / 2)
        }

        /// 把所有章节整体上下挪动，同时挪动滚动位置，屏幕上看到的内容不动。
        private func shift(by delta: CGFloat) {
            guard let scrollView else { return }
            for section in sections { section.view.frame.origin.y += delta }
            updateContentSize()
            scrollView.contentOffset.y += delta
        }

        /// 快滚到已铺内容的底部时，接上下一章；快滚到顶部时，在上面接上前一章。
        /// 离屏幕很远的章节拿掉，长时间阅读也不会越占越多。
        private func appendIfNeeded() {
            guard let scrollView else { return }
            let wasLayingOut = isLayingOut; isLayingOut = true
            defer { isLayingOut = wasLayingOut }
            let top = scrollView.contentOffset.y
            let screen = parent.size.height
            while let tail = sections.last,
                  tail.view.frame.maxY < top + screen * 2,
                  tail.chapter + 1 < parent.content.chapters.count {
                append(tail.chapter + 1)
            }
            if let head = sections.first, head.chapter > 0, top < screen {
                let view = makeTextView(for: head.chapter - 1)
                view.frame.origin.y = parent.insets.top
                scrollView.addSubview(view)
                shift(by: view.frame.height + gap)
                sections.insert((head.chapter - 1, view), at: 0)
            }
            while sections.count > 3, let head = sections.first, head.view.frame.maxY < scrollView.contentOffset.y - screen * 2 {
                head.view.removeFromSuperview()
                sections.removeFirst()
                if let next = sections.first {
                    shift(by: parent.insets.top - next.view.frame.minY)
                }
            }
            while sections.count > 3, let tail = sections.last, tail.view.frame.minY > scrollView.contentOffset.y + screen * 4 {
                tail.view.removeFromSuperview()
                sections.removeLast()
                updateContentSize()
            }
        }

        // MARK: 匀速滚动

        func startTicking() {
            guard displayLink == nil else { updateTicking(); return }
            let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            updateTicking()
        }

        private func updateTicking() {
            guard let displayLink else { return }
            let paused = parent.speed <= 0
            guard displayLink.isPaused != paused else { return }
            displayLink.isPaused = paused
            // Resume from a fresh frame rather than accumulating time spent in menus.
            lastTick = nil; carry = 0
        }

        func stopTicking() {
            boundaryRevision = UUID()
            displayLink?.invalidate()
            displayLink = nil
            lastTick = nil; carry = 0
        }

        fileprivate func tick(_ link: CADisplayLink) {
            #if DEBUG
            displayTickCount += 1
            #endif
            defer { lastTick = link.timestamp }
            guard let scrollView, let last = lastTick,
                  !scrollView.isTracking, !scrollView.isDecelerating
            else { return }
            // Do not replay elapsed background time or a stalled frame as one large scroll.
            carry += parent.speed * CGFloat(min(max(link.timestamp - last, 0), 0.1))
            let scale = scrollView.traitCollection.displayScale
            let step = (carry * scale).rounded(.down) / scale
            guard step > 0 else { return }
            carry -= step

            let maxY = max(0, scrollView.contentSize.height - parent.size.height)
            if scrollView.contentOffset.y >= maxY {
                // A chapter shorter than the viewport still needs reading time; do not skip it on the first tick.
                if maxY == 0 {
                    shortChapterDistance += step
                    let readableHeight = sections.reduce(CGFloat.zero) { $0 + $1.view.frame.height }
                    guard shortChapterDistance >= readableHeight else { return }
                }
                notifyEndIfNeeded()
                return
            }
            scrollView.contentOffset.y = min(maxY, scrollView.contentOffset.y + step)
        }

        private func notifyEndIfNeeded() {
            guard !endNotified, let scrollView,
                  scrollView.contentOffset.y >= max(0, scrollView.contentSize.height - parent.size.height) - 1 else { return }
            endNotified = true
            let revision = boundaryRevision
            let expected = parent.position
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayLink != nil, self.boundaryRevision == revision else { return }
                guard self.parent.position == expected, let scrollView = self.scrollView,
                      scrollView.contentOffset.y >= max(0, scrollView.contentSize.height - self.parent.size.height) - 1 else {
                    self.endNotified = false
                    return
                }
                self.parent.onReachEnd()
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            dragStartY = scrollView.contentOffset.y; draggedForward = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isLayingOut else { return }
            appendIfNeeded()
            if scrollView.contentOffset.y < max(0, scrollView.contentSize.height - parent.size.height) - 1 { endNotified = false }
            // 每半秒记一次读到哪里，不必每一帧都存。
            let now = CACurrentMediaTime()
            if now - lastReportTime > 0.5 {
                lastReportTime = now
                reportPosition()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            reportPosition()
            if draggedForward { notifyEndIfNeeded() }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            draggedForward = scrollView.contentOffset.y > dragStartY + 1 || scrollView.panGestureRecognizer.velocity(in: scrollView).y < 0
            if !decelerate {
                reportPosition()
                if draggedForward { notifyEndIfNeeded() }
            }
        }

        /// 正文区顶端那一行属于哪一章、章内第几个字。
        private func reportPosition() {
            guard !isLayingOut, let scrollView else { return }
            let y = scrollView.contentOffset.y + parent.insets.top
            guard let section = sections.last(where: { $0.view.frame.minY <= y + 1 }) ?? sections.first else { return }
            let point = CGPoint(x: 0, y: max(0, y - section.view.frame.minY))
            // 取这一行的第一个字。
            let manager = section.view.layoutManager
            let glyph = manager.glyphIndex(for: point, in: section.view.textContainer)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let first = manager.glyphIndex(for: CGPoint(x: 0, y: line.midY), in: section.view.textContainer)
            let offset = section.view.textStorage.length == 0 ? 0 : manager.characterIndexForGlyph(at: first)
            let position = ReadingPosition(chapter: section.chapter, offset: offset)
            parent.onChapterLength(section.chapter, section.view.textStorage.length)
            guard position != reported else { return }
            reported = position
            parent.position = position
        }

        @objc func handleTap() {
            parent.onTap()
        }
    }
}

/// CADisplayLink 会强引用目标，用这个中间人避免循环引用。
private final class WeakTarget: NSObject {
    weak var coordinator: ScrollReader.Coordinator?

    init(_ coordinator: ScrollReader.Coordinator) {
        self.coordinator = coordinator
    }

    @objc func tick(_ link: CADisplayLink) {
        coordinator?.tick(link)
    }
}
