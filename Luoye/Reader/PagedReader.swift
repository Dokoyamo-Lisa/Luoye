import SwiftUI
import UIKit

/// 左右滑动翻页的正文区。点左侧三分之一翻上一页，右侧翻下一页，中间呼出菜单。
struct PagedReader: UIViewControllerRepresentable {
    let content: BookContent
    let style: ReaderStyle
    /// 整个阅读区的大小（含安全区）
    let size: CGSize
    /// 正文离四边的距离
    let insets: UIEdgeInsets
    @Binding var position: ReadingPosition
    var onTapCenter: () -> Void
    /// 点到了注释标号，带出注释全文
    var onNote: (String) -> Void = { _ in }
    /// 当前页在章内的字符范围（判断书签是否落在这一页、加书签记在哪里）
    var onPageRange: (Range<Int>) -> Void = { _ in }
    var onChapterLength: (Int, Int) -> Void = { _, _ in }
    /// 页脚左边是否显示章名（自动阅读时那里放控制胶囊，章名由外面接着画）
    var showsFooterTitle = true
    /// 每加 1 就往后翻一页（自动翻页用）
    var forwardTurns = 0
    /// 到末页后继续向前翻时调用，在线章节可交给外层接续。
    var onReachEnd: () -> Void = {}
    /// The owner lets a removed reader release its swipe without cancelling a replacement reader's swipe.
    var onInteractionChanged: (UUID, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        controller.view.addGestureRecognizer(tap)
        let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleForwardSwipe))
        swipe.direction = .left; swipe.cancelsTouchesInView = false; swipe.delegate = context.coordinator
        controller.view.addGestureRecognizer(swipe)
        context.coordinator.pageViewController = controller
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh()
    }

    static func dismantleUIViewController(_ controller: UIPageViewController, coordinator: Coordinator) {
        coordinator.deactivate()
        controller.dataSource = nil; controller.delegate = nil
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PagedReader
        weak var pageViewController: UIPageViewController?

        private var layouts: [Int: ChapterLayout] = [:]
        private var laidOutStyle: ReaderStyle?
        private var laidOutSize: CGSize?
        private var laidOutInsets: UIEdgeInsets?
        private let pageControllers = NSHashTable<PageController>.weakObjects()
        private var reportID = UUID()
        private var laidOutFooterTitle = true
        /// 当前屏幕上显示的位置
        private var shown: ReadingPosition?

        /// 已经处理过的自动翻页次数
        private var isTransitioning = false
        private var transitionPosition: ReadingPosition?
        private let interactionID = UUID()
        private var isActive = true
        private var handledTurns: Int

        init(parent: PagedReader) {
            self.parent = parent
            self.handledTurns = parent.forwardTurns
        }

        /// 样式、尺寸变了就重新分页；外面改了位置（如从目录跳转）就跳过去。
        func refresh() {
            guard isActive else { return }
            if isTransitioning {
                // Automatic commands belong to the page being read when they expired.
                handledTurns = parent.forwardTurns
                return
            }
            guard !parent.content.chapters.isEmpty,
                  parent.size.width > parent.insets.left + parent.insets.right,
                  parent.size.height > parent.insets.top + parent.insets.bottom else { return }
            if parent.style != laidOutStyle || parent.size != laidOutSize || parent.insets != laidOutInsets {
                layouts = [:]
                laidOutStyle = parent.style
                laidOutSize = parent.size
                laidOutInsets = parent.insets
                show(parent.position)
            } else if parent.position != shown {
                show(parent.position)
            }
            if parent.showsFooterTitle != laidOutFooterTitle {
                laidOutFooterTitle = parent.showsFooterTitle
                for page in pageControllers.allObjects where parent.content.chapters.indices.contains(page.chapter) {
                    page.setFooterTitle(parent.showsFooterTitle ? parent.content.chapters[page.chapter].title : "")
                }
            }
            if parent.forwardTurns != handledTurns {
                handledTurns = parent.forwardTurns
                if !turn(step: 1) { notifyEnd() }
            }
        }

        private var pageSize: CGSize {
            CGSize(
                width: parent.size.width - parent.insets.left - parent.insets.right,
                height: parent.size.height - parent.insets.top - parent.insets.bottom
            )
        }

        private func layout(for chapter: Int) -> ChapterLayout {
            if let cached = layouts[chapter] { return cached }
            let layout = ChapterLayout(text: parent.style.attributedText(for: parent.content.chapters[chapter], images: parent.content.image), pageSize: pageSize)
            layouts[chapter] = layout
            return layout
        }

        private func page(chapter: Int, page: Int) -> PageController {
            let controller = PageController(
                chapter: chapter,
                page: page,
                layout: layout(for: chapter),
                title: parent.showsFooterTitle ? parent.content.chapters[chapter].title : "",
                style: parent.style,
                insets: parent.insets
            )
            pageControllers.add(controller)
            return controller
        }

        private func show(_ position: ReadingPosition) {
            let chapter = min(max(position.chapter, 0), parent.content.chapters.count - 1)
            let index = layout(for: chapter).page(containing: position.offset)
            let next = page(chapter: chapter, page: index)
            guard let controller = pageViewController else { return }
            if shown == nil || UIAccessibility.isReduceMotionEnabled {
                controller.setViewControllers([next], direction: .forward, animated: false)
            } else {
                // 目录跳转、换字号等：旧页淡出、新页淡入，不生硬地跳。
                UIView.transition(with: controller.view, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
                    controller.setViewControllers([next], direction: .forward, animated: false)
                }
            }
            // 重新排版、跳转时只翻到含这个位置的那一页，不改写阅读位置：
            // 否则每次排版都把位置挪到页首，几次下来就会往前漂。
            didShow(chapter: chapter, page: index, anchor: ReadingPosition(chapter: chapter, offset: position.offset))
        }

        /// 某一页显示出来了。`anchor` 为空表示是读者自己翻到的，阅读位置更新为这一页的页首。
        private func didShow(chapter: Int, page: Int, anchor: ReadingPosition? = nil, afterReport: (() -> Void)? = nil) {
            let range = layout(for: chapter).characterRange(ofPage: page)
            let position = anchor ?? ReadingPosition(chapter: chapter, offset: range.location)
            shown = position
            let pageRange = range.location ..< NSMaxRange(range)
            let length = layout(for: chapter).storage.length
            let expected = parent.position
            let report = UUID(); reportID = report
            DispatchQueue.main.async { [weak self] in
                defer { afterReport?() }
                guard let self, self.isActive, self.reportID == report, self.parent.position == expected else { return }
                self.parent.onChapterLength(chapter, length)
                self.parent.onPageRange(pageRange)
                if expected != position { self.parent.position = position }
            }
            // 只留前后相邻的章节，长书也不会越占越多内存。
            layouts = layouts.filter { abs($0.key - chapter) <= 1 }
        }

        private func neighbor(of current: PageController, step: Int) -> PageController? {
            if step < 0 {
                if current.page > 0 { return page(chapter: current.chapter, page: current.page - 1) }
                guard current.chapter > 0 else { return nil }
                let previous = current.chapter - 1
                return page(chapter: previous, page: layout(for: previous).pageCount - 1)
            } else {
                if current.page + 1 < current.layout.pageCount { return page(chapter: current.chapter, page: current.page + 1) }
                guard current.chapter + 1 < parent.content.chapters.count else { return nil }
                return page(chapter: current.chapter + 1, page: 0)
            }
        }

        func pageViewController(_ controller: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            (viewController as? PageController).flatMap { neighbor(of: $0, step: -1) }
        }

        func pageViewController(_ controller: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            (viewController as? PageController).flatMap { neighbor(of: $0, step: 1) }
        }

        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            guard isActive else { return }
            transitionPosition = parent.position
            isTransitioning = true
            handledTurns = parent.forwardTurns
            parent.onInteractionChanged(interactionID, true)
        }

        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard isActive else { return }
            let wasInteractive = transitionPosition != nil
            let expected = transitionPosition ?? parent.position
            transitionPosition = nil
            isTransitioning = false
            handledTurns = parent.forwardTurns
            let callback = parent.onInteractionChanged, owner = interactionID
            let finishInteraction: (() -> Void)? = wasInteractive ? { callback(owner, false) } : nil
            // A chapter/bookmark selection made during the swipe takes precedence over its old destination.
            if completed, parent.position == expected, let current = controller.viewControllers?.first as? PageController {
                // Releasing the pause can redraw SwiftUI. Commit the new binding first,
                // or that redraw can restore the old page before its deferred report runs.
                didShow(chapter: current.chapter, page: current.page, afterReport: finishInteraction)
            } else { finishInteraction?() }
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            if let page = pageViewController?.viewControllers?.first as? PageController,
               let note = page.note(at: gesture.location(in: page.view)) {
                parent.onNote(note)
                return
            }
            let x = gesture.location(in: view).x / view.bounds.width
            if x < 0.3 {
                turn(step: -1)
            } else if x > 0.7 {
                if !turn(step: 1) { notifyEnd() }
            } else {
                parent.onTapCenter()
            }
        }

        @objc func handleForwardSwipe() {
            guard isActive, !isTransitioning,
                  let current = pageViewController?.viewControllers?.first as? PageController,
                  neighbor(of: current, step: 1) == nil else { return }
            notifyEnd()
        }

        func deactivate() {
            guard isActive else { return }
            isActive = false
            if transitionPosition != nil {
                transitionPosition = nil
                let callback = parent.onInteractionChanged, owner = interactionID
                // Dismantling may happen inside a SwiftUI update.
                DispatchQueue.main.async { callback(owner, false) }
            }
        }

        private func notifyEnd() {
            let report = reportID
            let expected = parent.position
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.reportID == report,
                      self.parent.position == expected else { return }
                self.parent.onReachEnd()
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer is UISwipeGestureRecognizer else { return true }
            guard isActive, !isTransitioning,
                  let current = pageViewController?.viewControllers?.first as? PageController else { return false }
            // Let UIPageViewController exclusively own ordinary page swipes.
            return neighbor(of: current, step: 1) == nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UISwipeGestureRecognizer
        }

        /// 翻一页；已经到头时返回 false。
        @discardableResult
        private func turn(step: Int) -> Bool {
            guard isActive, !isTransitioning else { return true }
            guard let controller = pageViewController,
                  let current = controller.viewControllers?.first as? PageController,
                  let next = neighbor(of: current, step: step)
            else { return false }
            let expected = parent.position
            isTransitioning = true
            controller.setViewControllers([next], direction: step > 0 ? .forward : .reverse, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] done in
                guard let self, self.isActive else { return }
                self.isTransitioning = false
                if done && self.parent.position == expected { self.didShow(chapter: next.chapter, page: next.page) }
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
            return true
        }
    }
}

/// 一页：正文，底部左边小字章名、右边页码。
final class PageController: UIViewController {
    let chapter: Int
    let page: Int
    let layout: ChapterLayout
    private var chapterTitle: String
    private let style: ReaderStyle
    private let insets: UIEdgeInsets

    private let chapterLabel = UILabel()
    private let pageLabel = UILabel()
    private lazy var textView = PageTextView(layout: layout, page: page)

    init(chapter: Int, page: Int, layout: ChapterLayout, title: String, style: ReaderStyle, insets: UIEdgeInsets) {
        self.chapter = chapter
        self.page = page
        self.layout = layout
        self.chapterTitle = title
        self.style = style
        self.insets = insets
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = style.background
        let small = UIFont(name: "NotoSerifSC-Regular", size: 11) ?? .systemFont(ofSize: 11)
        for label in [chapterLabel, pageLabel] {
            label.font = small
            label.textColor = style.secondary
            view.addSubview(label)
        }
        chapterLabel.text = chapterTitle
        chapterLabel.lineBreakMode = .byTruncatingTail
        pageLabel.text = "\(page + 1) / \(layout.pageCount)"
        pageLabel.textAlignment = .right
        view.addSubview(textView)
    }

    func setFooterTitle(_ title: String) {
        chapterTitle = title
        if isViewLoaded { chapterLabel.text = title }
    }

    /// 这个点是否落在注释标号上（四周放宽一点，好点中）。
    func note(at point: CGPoint) -> String? {
        textView.note(at: view.convert(point, to: textView))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let width = bounds.width - insets.left - insets.right
        textView.frame = CGRect(x: insets.left, y: insets.top, width: width, height: bounds.height - insets.top - insets.bottom)
        // 页脚固定贴在屏幕底部（Home 条上方），不随正文行数上下浮动。
        let footerY = bounds.height - max(view.safeAreaInsets.bottom, 20) - 22
        chapterLabel.frame = CGRect(x: insets.left, y: footerY, width: width * 0.7, height: 16)
        pageLabel.frame = CGRect(x: insets.left + width * 0.7, y: footerY, width: width * 0.3, height: 16)
    }
}
