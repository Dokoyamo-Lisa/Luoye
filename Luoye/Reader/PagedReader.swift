import SwiftUI
import UIKit

/// 左右翻页的正文区。点左侧三成翻上一页，右侧翻下一页，中间呼出菜单。
///
/// 不用 UIPageViewController：它在翻页动画进行中会吞掉新的点击，手指和代码同时翻页时还会错乱。
/// 这里把所有页摆在一条横向的「页带」上，用一个弹簧驱动页带的位置：
/// - 点击只改变弹簧的目标，连点几下就连翻几页，动画不断档；
/// - 手指按住随时接管页带（哪怕正在翻页途中），松手按速度决定翻过去还是弹回；
/// - 阅读位置只在页带停稳时上报一次，外面（目录、换字号）改了位置就直接跳过去。
struct PagedReader: UIViewRepresentable {
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
    /// 菜单开着时，点正文任何地方都只是收起菜单，不翻页
    var menuShown = false
    /// 每加 1 就往后翻一页（自动翻页用）
    var forwardTurns = 0
    /// 到末页后继续向后翻时调用，在线章节可交给外层接续。
    var onReachEnd: () -> Void = {}
    /// 手指拖动页面的开始与结束（自动翻页在拖动时暂停，松手后重新计时）
    var onInteractionChanged: (UUID, Bool) -> Void = { _, _ in }
    /// 一屏几栏：iPad 横屏是 2，像摊开的书一样左右两页，翻页时右页绕书脊翻到左边。
    var columns = 1
    /// 两栏时左右两页正文之间的距离（书脊两侧的留白）
    var columnGap: CGFloat = 0

    func makeUIView(context: Context) -> PageStripView {
        let view = PageStripView()
        view.update(self)
        return view
    }

    func updateUIView(_ view: PageStripView, context: Context) {
        view.update(self)
    }

    static func dismantleUIView(_ view: PageStripView, coordinator: ()) {
        view.deactivate()
    }
}

/// 页带：第 i 页摆在横坐标 (i - x) × 宽度 处，x 是页带当前滚到的位置（以页为单位）。
/// 第 0 页是「锚点页」；页带滚过半页以上就把锚点挪过去，坐标始终保持在 0 附近。
final class PageStripView: UIView {
    struct PageRef: Hashable {
        let chapter: Int
        let page: Int
    }

    private(set) var parent: PagedReader?

    // 排版
    private var layouts: [Int: ChapterLayout] = [:]
    private var laidOutStyle: ReaderStyle?
    private var laidOutSize: CGSize?
    private var laidOutInsets: UIEdgeInsets?
    private var laidOutFooterTitle = true
    private var laidOutChapterCount = 0
    private var laidOutColumns = 1

    // 页带
    private(set) var anchor: PageRef?
    /// 最近一次上报（或从外面收到）的阅读位置。重新排版时翻到含它的那一页，不改写它。
    private var shown: ReadingPosition?
    /// 页带位置、速度（页/秒）和弹簧目标（整数页）
    private(set) var x: CGFloat = 0
    private var velocity: CGFloat = 0
    private(set) var target: CGFloat = 0
    private var neighbors: [Int: PageRef?] = [:]
    private var pageViews: [Int: PageView] = [:]
    /// 两栏时，页带上第 i 屏的左右两页（不整屏平移，而是右页绕书脊翻过去）
    private var spreads: [Int: Spread] = [:]
    private struct Spread {
        let ref: PageRef
        let left: HalfPageView
        let right: HalfPageView
        var views: [HalfPageView] { [left, right] }
    }
    private var displayLink: CADisplayLink?
    /// 眼前这一页（页带停稳时）
    var currentPage: PageView? { pageViews[0] }
    var isMoving: Bool { displayLink != nil }
    private var lastTick: CFTimeInterval?
    private var jumpSnapshot: UIView?

    // 手势
    private let pan = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    /// 这次触摸按下的位置。点击在抬手时才触发，用它分辨「真的点了一下」和「划得太短、没被认成拖动的一下」。
    private var touchDown: CGPoint?
    private var dragStart: CGFloat = 0
    private(set) var isDragging = false
    /// 一次拖动从按下到页带停稳算一次交互；外面据此暂停自动翻页
    private var interacting = false
    private let interactionID = UUID()
    /// 翻到书头书尾时轻轻一震，和页面那一下回弹对上
    private let edgeFeedback = UIImpactFeedbackGenerator(style: .soft)
    private var handledTurns: Int?
    private var isActive = true

    /// 弹簧：0.34 秒走完，临界阻尼（不回弹）。
    private static let response: CGFloat = 0.34
    private static let stiffness = pow(2 * .pi / response, 2)
    private static let damping = 4 * .pi / response
    /// 连点时最多比当前位置领先几页，免得一口气冲出去太远
    private static let maxLead: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        tap.addTarget(self, action: #selector(handleTap(_:)))
        // 手指一动就是拖动，没动才算点击；点击不必等待，抬手即触发。
        tap.require(toFail: pan)
        tap.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var width: CGFloat { max(bounds.width, 1) }

    // MARK: 外面的变化

    func update(_ new: PagedReader) {
        parent = new
        if handledTurns == nil { handledTurns = new.forwardTurns }
        guard isActive, !new.content.chapters.isEmpty,
              new.size.width > new.insets.left + new.insets.right,
              new.size.height > new.insets.top + new.insets.bottom else { return }

        if new.style != laidOutStyle || new.size != laidOutSize || new.insets != laidOutInsets
            || new.content.chapters.count != laidOutChapterCount || max(new.columns, 1) != laidOutColumns {
            let firstLayout = laidOutStyle == nil
            layouts = [:]
            laidOutStyle = new.style
            laidOutSize = new.size
            laidOutInsets = new.insets
            laidOutChapterCount = new.content.chapters.count
            laidOutColumns = max(new.columns, 1)
            laidOutFooterTitle = new.showsFooterTitle
            // 换字号、转屏：停在含原位置的那一页，阅读位置本身不动，免得反复排版后往前漂。
            let keep = (shown == nil || new.position != shown) ? new.position : shown!
            jump(to: keep, animated: !firstLayout)
        } else if new.position != shown {
            // 目录、书签跳转：正在进行的翻页、拖动一律作废。
            jump(to: new.position, animated: true)
        }

        if new.showsFooterTitle != laidOutFooterTitle {
            laidOutFooterTitle = new.showsFooterTitle
            for (_, view) in pageViews { view.setFooterTitle(footerTitle(for: view.ref.chapter)) }
            for (_, spread) in spreads { spread.left.setFooterTitle(footerTitle(for: spread.ref.chapter)) }
        }

        if new.forwardTurns != handledTurns {
            handledTurns = new.forwardTurns
            // 自动翻页的到点指令：手指正按着页面时作废，松手后外面会重新计时。
            if !isDragging { step(1) }
        }
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        stopSpring()
        jumpSnapshot?.removeFromSuperview(); jumpSnapshot = nil
        endInteraction(deferred: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPages()
    }

    // MARK: 排版与页的查找

    private var pageSize: CGSize {
        guard let parent else { return .zero }
        let gaps = parent.columnGap * CGFloat(laidOutColumns - 1)
        return CGSize(width: (parent.size.width - parent.insets.left - parent.insets.right - gaps) / CGFloat(laidOutColumns),
                      height: parent.size.height - parent.insets.top - parent.insets.bottom)
    }

    // 页带上的「一屏」：单栏时就是一页；两栏时是摊开的左右两页，每章从左页起。
    private func screenCount(_ layout: ChapterLayout) -> Int {
        (layout.pageCount + laidOutColumns - 1) / laidOutColumns
    }

    private func screen(containing offset: Int, in layout: ChapterLayout) -> Int {
        layout.page(containing: offset) / laidOutColumns
    }

    private func characterRange(ofScreen screen: Int, in layout: ChapterLayout) -> NSRange {
        let first = screen * laidOutColumns
        let last = min(first + laidOutColumns - 1, layout.pageCount - 1)
        return NSUnionRange(layout.characterRange(ofPage: first), layout.characterRange(ofPage: last))
    }

    func layout(for chapter: Int) -> ChapterLayout {
        if let cached = layouts[chapter] { return cached }
        let parent = parent!
        let layout = ChapterLayout(text: parent.style.attributedText(for: parent.content.chapters[chapter], images: parent.content.image),
                                   pageSize: pageSize)
        layouts[chapter] = layout
        return layout
    }

    private func neighbor(of ref: PageRef, step: Int) -> PageRef? {
        guard let count = parent?.content.chapters.count else { return nil }
        if step < 0 {
            if ref.page > 0 { return PageRef(chapter: ref.chapter, page: ref.page - 1) }
            guard ref.chapter > 0 else { return nil }
            return PageRef(chapter: ref.chapter - 1, page: screenCount(layout(for: ref.chapter - 1)) - 1)
        } else {
            if ref.page + 1 < screenCount(layout(for: ref.chapter)) { return PageRef(chapter: ref.chapter, page: ref.page + 1) }
            guard ref.chapter + 1 < count else { return nil }
            return PageRef(chapter: ref.chapter + 1, page: 0)
        }
    }

    /// 页带上第 i 页（相对锚点）；超出全书两端为 nil。
    func ref(at index: Int) -> PageRef? {
        if index == 0 { return anchor }
        if let cached = neighbors[index] { return cached }
        let inner = index > 0 ? index - 1 : index + 1
        let result = ref(at: inner).flatMap { neighbor(of: $0, step: index > 0 ? 1 : -1) }
        neighbors[index] = result
        return result
    }

    /// 从 0 往某个方向连续存在的最远一页。
    private func reachable(toward index: Int) -> Int {
        var reached = 0
        let direction = index > 0 ? 1 : -1
        while reached != index, ref(at: reached + direction) != nil { reached += direction }
        return reached
    }

    private func footerTitle(for chapter: Int) -> String {
        guard let parent, laidOutFooterTitle, parent.content.chapters.indices.contains(chapter) else { return "" }
        return ChapterTitle.parts(parent.content.chapters[chapter].title).name
    }

    // MARK: 摆放页面

    private func layoutPages() {
        guard let parent, anchor != nil, bounds.width > 0 else { return }
        if laidOutColumns > 1 { layoutSpreads(); return }
        // 屏幕上露出的页，再各多备一页：快翻时下一页早已画好。
        let low = Int(floor(x)) - 1, high = Int(ceil(x)) + 1
        var wanted: [Int: PageRef] = [:]
        for index in low ... high { if let ref = ref(at: index) { wanted[index] = ref } }

        for (index, view) in pageViews where wanted[index] != view.ref {
            view.removeFromSuperview()
            pageViews[index] = nil
        }
        for (index, ref) in wanted {
            let view = pageViews[index] ?? {
                let view = PageView(ref: ref, layout: layout(for: ref.chapter), title: footerTitle(for: ref.chapter),
                                    style: parent.style, insets: parent.insets)
                insertSubview(view, at: 0)
                pageViews[index] = view
                return view
            }()
            // 取整到像素，滑动中文字也不会发虚。
            let scale = window?.screen.scale ?? 3
            let originX = ((CGFloat(index) - x) * bounds.width * scale).rounded() / scale
            view.frame = CGRect(x: originX, y: 0, width: bounds.width, height: bounds.height)
            // 预备好的前后页不在屏幕上时藏起来：打开书的放大转场、转屏时都不会从旁边露出来。
            view.isHidden = abs(CGFloat(index) - x) >= 0.999
            // 只有正在移动的页才投一道浅影，分出前后两页的边界。
            view.layer.shadowOpacity = abs(originX) > 0.5 && abs(originX) < bounds.width - 0.5 ? 0.08 : 0
        }
        if let snapshot = jumpSnapshot { bringSubviewToFront(snapshot) }
    }

    /// 两栏：x 在 i 与 i+1 之间时，第 i 屏的右页正绕书脊翻起，翻过一半后露出的是第 i+1 屏的左页（纸的背面）。
    /// 底下垫着第 i 屏的左页和第 i+1 屏的右页。整个画面只由 x 决定，拖动、弹簧、连点都不用另写。
    private func layoutSpreads() {
        guard let parent else { return }
        let base = Int(floor(x))
        var fraction = x - CGFloat(base)
        // 书头书尾往外拖：没有下一屏（或上一屏），纸只掀起一点点又落回去。
        if ref(at: base + 1) == nil { fraction = min(fraction, 0.12) }
        if ref(at: base) == nil { fraction = max(fraction, 0.88) }

        var wanted: [Int: PageRef] = [:]
        for index in base - 1 ... base + 2 { if let ref = ref(at: index) { wanted[index] = ref } }
        for (index, spread) in spreads where wanted[index] != spread.ref {
            spread.views.forEach { $0.removeFromSuperview() }
            spreads[index] = nil
        }
        let half = CGSize(width: bounds.width / 2, height: bounds.height)
        for (index, ref) in wanted where spreads[index] == nil {
            let layout = layout(for: ref.chapter)
            let first = ref.page * laidOutColumns
            let make = { (page: Int, side: HalfPageView.Side) in
                HalfPageView(side: side, layout: layout, page: page < layout.pageCount ? page : nil,
                             title: side == .left ? self.footerTitle(for: ref.chapter) : nil,
                             style: parent.style, insets: parent.insets, gap: parent.columnGap)
            }
            let spread = Spread(ref: ref, left: make(first, .left), right: make(first + 1, .right))
            spread.views.forEach { addSubview($0) }
            spreads[index] = spread
        }

        let angle = fraction * .pi
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 2200
        for (index, spread) in spreads {
            for view in spread.views {
                view.layer.anchorPoint = CGPoint(x: view.side == .left ? 1 : 0, y: 0.5)
                view.bounds = CGRect(origin: .zero, size: half)
                view.center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
                view.layer.transform = CATransform3DIdentity
                view.shade = 0
                view.isHidden = true
                view.layer.zPosition = 0
            }
            if index == base {
                // 当前这一屏：左页垫底不动；右页是正在翻起的那张纸的正面，过了竖直就看不见了。
                spread.left.isHidden = false
                spread.right.isHidden = angle >= .pi / 2
                spread.right.layer.transform = CATransform3DRotate(perspective, -angle, 0, 1, 0)
                spread.right.shade = sin(angle) * 0.22
                spread.right.layer.zPosition = 2
            } else if index == base + 1, fraction > 0 {
                // 下一屏：右页垫底慢慢露出来；左页是那张纸的背面，竖起来之后才翻落到左边。
                spread.right.isHidden = false
                spread.right.shade = (1 - fraction) * 0.12
                spread.left.isHidden = angle < .pi / 2
                spread.left.layer.transform = CATransform3DRotate(perspective, .pi - angle, 0, 1, 0)
                spread.left.shade = sin(angle) * 0.18
                spread.left.layer.zPosition = 3
            }
        }
        // 底页在下，翻动的纸在上。
        for view in subviews.compactMap({ $0 as? HalfPageView }).sorted(by: { $0.layer.zPosition < $1.layer.zPosition }) {
            bringSubviewToFront(view)
        }
        if let snapshot = jumpSnapshot { bringSubviewToFront(snapshot) }
    }

    /// 页带挪过半页以上，就把锚点换到最近的那一页，坐标回到 0 附近。
    private func recenter() {
        let shift = Int(x.rounded())
        guard shift != 0, let oldAnchor = anchor, let newAnchor = ref(at: shift) else { return }
        anchor = newAnchor
        x -= CGFloat(shift); target -= CGFloat(shift); dragStart -= CGFloat(shift)
        var moved: [Int: PageView] = [:]
        for (index, view) in pageViews { moved[index - shift] = view }
        pageViews = moved
        var movedSpreads: [Int: Spread] = [:]
        for (index, spread) in spreads { movedSpreads[index - shift] = spread }
        spreads = movedSpreads
        var refs: [Int: PageRef?] = [:]
        for (index, ref) in neighbors where index != shift { refs[index - shift] = ref }
        // 旧锚点成了相对位置 -shift 的那一页
        refs[-shift] = .some(oldAnchor)
        neighbors = refs
        trimLayouts()
    }

    /// 只留锚点前后一章的排版，长书也不会越占越多内存。
    private func trimLayouts() {
        guard let anchor else { return }
        let keep = Set(pageViews.values.map(\.ref.chapter) + spreads.values.map(\.ref.chapter)).union([anchor.chapter - 1, anchor.chapter, anchor.chapter + 1])
        layouts = layouts.filter { keep.contains($0.key) }
    }

    // MARK: 跳转（目录、书签、重新排版）

    private func jump(to position: ReadingPosition, animated: Bool) {
        guard let parent else { return }
        let chapter = min(max(position.chapter, 0), parent.content.chapters.count - 1)
        let page = screen(containing: position.offset, in: layout(for: chapter))

        if isDragging { pan.isEnabled = false; pan.isEnabled = true; isDragging = false }
        stopSpring()
        endInteraction(deferred: true)

        jumpSnapshot?.removeFromSuperview(); jumpSnapshot = nil
        let snapshot = animated && anchor != nil && !UIAccessibility.isReduceMotionEnabled
            ? snapshotView(afterScreenUpdates: false) : nil

        pageViews.values.forEach { $0.removeFromSuperview() }
        pageViews = [:]
        spreads.values.forEach { $0.views.forEach { $0.removeFromSuperview() } }
        spreads = [:]
        neighbors = [:]
        anchor = PageRef(chapter: chapter, page: page)
        x = 0; target = 0; velocity = 0
        layoutPages()

        if let snapshot {
            // 旧页淡出，新页已经在下面摆好。
            snapshot.frame = bounds
            snapshot.isUserInteractionEnabled = false
            addSubview(snapshot)
            jumpSnapshot = snapshot
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                snapshot.alpha = 0
            } completion: { [weak self, weak snapshot] _ in
                snapshot?.removeFromSuperview()
                if self?.jumpSnapshot === snapshot { self?.jumpSnapshot = nil }
            }
        }
        // 跳转只翻到含这个位置的那一页，不改写阅读位置。
        shown = ReadingPosition(chapter: chapter, offset: position.offset)
        report(fromUpdate: true)
        trimLayouts()
    }

    // MARK: 翻页

    /// 往前或往后翻一页（点击、自动翻页、读屏手势）。已经到头时返回 false。
    @discardableResult
    func step(_ direction: Int) -> Bool {
        guard isActive, anchor != nil, !isDragging else { return false }
        // 以目标为准：动画途中再点，就在目标上再加一页，连点几下翻几页。
        let base = target.rounded()
        let next = base + CGFloat(direction)
        if abs(next - x) > Self.maxLead { return true }
        guard ref(at: Int(next)) != nil else {
            // 到头了：页面朝那边轻轻顶一下再弹回，告诉读者没有了。
            if direction > 0 { notifyEnd() }
            edgeFeedback.impactOccurred(intensity: 0.6)
            if !UIAccessibility.isReduceMotionEnabled { velocity += CGFloat(direction) * 0.9 }
            startSpring()
            return false
        }
        target = next
        if UIAccessibility.isReduceMotionEnabled {
            crossfadeTo(target)
        } else {
            startSpring()
        }
        return true
    }

    /// 减弱动态效果时：不滑动，原地淡入下一页。
    private func crossfadeTo(_ destination: CGFloat) {
        let snapshot = snapshotView(afterScreenUpdates: false)
        x = destination; velocity = 0
        recenter(); layoutPages()
        if let snapshot {
            snapshot.frame = bounds
            addSubview(snapshot)
            UIView.animate(withDuration: 0.15) { snapshot.alpha = 0 } completion: { _ in snapshot.removeFromSuperview() }
        }
        settle()
    }

    // MARK: 弹簧

    private func startSpring() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: WeakStripTarget(self), selector: #selector(WeakStripTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = nil
    }

    private func stopSpring() {
        displayLink?.invalidate()
        displayLink = nil
        lastTick = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard isActive else { stopSpring(); return }
        let now = link.targetTimestamp
        // 卡顿或刚开始时最多按 1/30 秒推进，不会一下子跳过去。
        let elapsed = min(max(now - (lastTick ?? link.timestamp), 0), 1.0 / 30)
        lastTick = now
        advance(by: elapsed)
    }

    /// 按弹簧推进一段时间；停稳就上报。
    func advance(by elapsed: CFTimeInterval) {
        guard !isDragging else { return }
        let substeps = max(1, Int((elapsed * 480).rounded(.up)))
        let dt = CGFloat(elapsed) / CGFloat(substeps)
        for _ in 0 ..< substeps {
            let force = -Self.stiffness * (x - target) - Self.damping * velocity
            velocity += force * dt
            x += velocity * dt
        }
        if abs(x - target) < 0.0008 && abs(velocity) < 0.02 {
            x = target; velocity = 0
            stopSpring()
            recenter()
            layoutPages()
            settle()
        } else {
            recenter()
            layoutPages()
        }
    }

    /// 页带停稳：锚点就是读者眼前这一页。
    private func settle() {
        guard let anchor else { return }
        let layout = layout(for: anchor.chapter)
        // 还停在原位置所在的那一页（比如拖了一下又弹回），位置不动。
        let stillThere = shown.map { $0.chapter == anchor.chapter && screen(containing: $0.offset, in: layout) == anchor.page } ?? false
        if !stillThere { shown = ReadingPosition(chapter: anchor.chapter, offset: characterRange(ofScreen: anchor.page, in: layout).location) }
        report(fromUpdate: false)
        endInteraction(deferred: false)
        trimLayouts()
    }

    /// 把当前页告诉外面。来自 SwiftUI 更新的（跳转、重排）推迟到下一轮，免得在更新视图时改状态。
    private func report(fromUpdate: Bool) {
        guard let parent, let anchor, let shown else { return }
        let layout = layout(for: anchor.chapter)
        let range = characterRange(ofScreen: anchor.page, in: layout)
        let pageRange = range.location ..< NSMaxRange(range)
        let length = layout.storage.length
        let send = { [weak self] in
            guard let self, self.isActive, self.shown == shown else { return }
            // 推迟的上报：期间外面又改了位置（比如又点了目录），这次作废。
            if fromUpdate, parent.position != shown { return }
            if parent.position != shown { parent.position = shown }
            parent.onChapterLength(anchor.chapter, length)
            parent.onPageRange(pageRange)
        }
        if fromUpdate { DispatchQueue.main.async(execute: send) } else { send() }
    }

    private func notifyEnd() {
        guard let parent else { return }
        let expected = shown
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.shown == expected else { return }
            parent.onReachEnd()
        }
    }

    // MARK: 手势

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pan else { return true }
        guard isActive, anchor != nil else { return false }
        // 只接横向的拖动；竖着划交给别人（比如下拉关闭）。
        let v = pan.velocity(in: self)
        return abs(v.x) > abs(v.y)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // 正在翻页也能一把按住：从页带当前的位置接着拖，不跳。
            isDragging = true
            stopSpring()
            velocity = 0
            dragStart = x
            beginInteraction()
        case .changed:
            guard isDragging else { return }
            let raw = dragStart - gesture.translation(in: self).x / width
            x = resisted(raw)
            recenter()
            layoutPages()
        case .ended, .cancelled, .failed:
            guard isDragging else { return }
            isDragging = false
            // 斜着起手、其实是往下划的一下：横向那点位移不算翻页，弹回原页。
            let moved = gesture.translation(in: self)
            let vertical = abs(moved.y) > abs(moved.x) * 2
            let speed = -gesture.velocity(in: self).x / width
            release(speed: gesture.state == .ended && !vertical ? speed : 0)
        default:
            break
        }
    }

    /// 拖过全书两端时越拖越沉，最多露出三成页面。
    private func resisted(_ raw: CGFloat) -> CGFloat {
        let index = raw > 0 ? Int(ceil(raw)) : Int(floor(raw))
        let edge = CGFloat(reachable(toward: index))
        let overshoot = raw > 0 ? raw - edge : edge - raw
        guard overshoot > 0 else { return raw }
        let eased = overshoot * 0.3 / (1 + overshoot)
        return raw > 0 ? edge + eased : edge - eased
    }

    /// 松手：快速一划就翻过去，慢慢拖过半页也翻过去，否则弹回原页。
    private func release(speed: CGFloat) {
        var destination: CGFloat
        if speed > 0.5 { destination = floor(x) + 1 }
        else if speed < -0.5 { destination = ceil(x) - 1 }
        else { destination = x.rounded() }
        // 一次拖动最多翻一页。
        let start = dragStart.rounded()
        destination = min(max(destination, start - 1), start + 1)
        let edge = CGFloat(reachable(toward: Int(destination)))
        if destination > 0, destination > edge {
            // 末页再往后拖：交给外面接续下一章（在线书）。
            if x > edge + 0.03 || speed > 0.5 { notifyEnd() }
            if x > edge + 0.03 { edgeFeedback.impactOccurred(intensity: 0.6) }
            destination = edge
        } else if destination < 0, destination < edge {
            if x < edge - 0.03 { edgeFeedback.impactOccurred(intensity: 0.6) }
            destination = edge
        }
        target = destination
        // 速度不超过每秒 8 页，免得轻轻一甩过冲。
        velocity = min(max(speed, -8), 8)
        startSpring()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let parent, isActive else { return }
        let point = gesture.location(in: self)
        let intent = Self.tapIntent(down: touchDown ?? point, up: point, width: width)
        touchDown = nil
        // 手指划了一小段：是没够上拖动门槛的轻划，不按落点算点击。
        // 往左划翻下一页、往右划翻上一页，上下划什么都不做——不会因为落在左边就往回翻。
        switch intent {
        case .flick(let direction):
            if !parent.menuShown { step(direction) }
            return
        case .ignore:
            return
        case .tap:
            break
        }
        if parent.menuShown { parent.onTapCenter(); return }
        // 停稳时才看是不是点在注释标号上；翻页途中点一下就是翻页。
        if displayLink == nil, let note = note(at: point) {
            parent.onNote(note)
            return
        }
        let fraction = point.x / width
        if fraction < 0.3 { step(-1) }
        else if fraction > 0.7 { step(1) }
        else { parent.onTapCenter() }
    }

    private func note(at point: CGPoint) -> String? {
        if let page = pageViews[0] { return page.note(at: convert(point, to: page)) }
        guard let spread = spreads[0] else { return nil }
        let half = point.x < bounds.width / 2 ? spread.left : spread.right
        return half.note(at: convert(point, to: half))
    }

    enum TapIntent: Equatable { case tap, flick(Int), ignore }

    /// 按下到抬起移动了多少：几乎没动是点击；横向为主是轻划翻页；竖向为主不处理。
    static func tapIntent(down: CGPoint, up: CGPoint, width: CGFloat) -> TapIntent {
        let dx = up.x - down.x, dy = up.y - down.y
        guard hypot(dx, dy) > 8 else { return .tap }
        guard abs(dx) > abs(dy) * 1.5 else { return .ignore }
        return .flick(dx < 0 ? 1 : -1)
    }

    private func beginInteraction() {
        guard !interacting, let parent else { return }
        interacting = true
        parent.onInteractionChanged(interactionID, true)
    }

    private func endInteraction(deferred: Bool) {
        guard interacting, let parent else { return }
        interacting = false
        let callback = parent.onInteractionChanged, owner = interactionID
        if deferred { DispatchQueue.main.async { callback(owner, false) } } else { callback(owner, false) }
    }

    // MARK: 读屏

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        switch direction {
        case .left, .next: return step(1)
        case .right, .previous: return step(-1)
        default: return false
        }
    }
}

extension PageStripView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === tap { touchDown = touch.location(in: self) }
        return true
    }
}

/// CADisplayLink 会强引用目标，用这个中间人避免循环引用。
private final class WeakStripTarget: NSObject {
    weak var strip: PageStripView?
    init(_ strip: PageStripView) { self.strip = strip }
    @objc func tick(_ link: CADisplayLink) { strip?.tick(link) }
}

/// 一页：正文，底部左边小字章名、右边页码。
final class PageView: UIView {
    let ref: PageStripView.PageRef
    private let layout: ChapterLayout
    private let insets: UIEdgeInsets
    private let chapterLabel = UILabel()
    private let pageLabel = UILabel()
    private let textView: PageTextView

    init(ref: PageStripView.PageRef, layout: ChapterLayout, title: String, style: ReaderStyle, insets: UIEdgeInsets) {
        self.ref = ref
        self.layout = layout
        self.insets = insets
        textView = PageTextView(layout: layout, page: ref.page)
        super.init(frame: .zero)
        backgroundColor = style.background
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowRadius = 8
        layer.shadowOffset = .zero
        let small = UIFont(name: "NotoSerifSC-Regular", size: 11) ?? .systemFont(ofSize: 11)
        for label in [chapterLabel, pageLabel] {
            label.font = small
            label.textColor = style.secondary
            addSubview(label)
        }
        chapterLabel.text = title
        chapterLabel.lineBreakMode = .byTruncatingTail
        pageLabel.text = "\(ref.page + 1) / \(layout.pageCount)"
        pageLabel.textAlignment = .right
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var footerTitle: String? { chapterLabel.text }

    func setFooterTitle(_ title: String) {
        chapterLabel.text = title
    }

    /// 这个点是否落在注释标号上（四周放宽一点，好点中）。
    func note(at point: CGPoint) -> String? {
        textView.note(at: convert(point, to: textView))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width - insets.left - insets.right
        textView.frame = CGRect(x: insets.left, y: insets.top, width: width, height: bounds.height - insets.top - insets.bottom)
        // 页脚固定贴在屏幕底部（Home 条上方），不随正文行数上下浮动。
        let footerY = bounds.height - max(safeAreaInsets.bottom, 20) - 22
        chapterLabel.frame = CGRect(x: insets.left, y: footerY, width: width * 0.7, height: 16)
        pageLabel.frame = CGRect(x: insets.left + width * 0.7, y: footerY, width: width * 0.3, height: 16)
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }
}

/// 两栏时的半边：一页正文。左半边页脚写章名，右半边写页码；靠书脊那侧有一道浅浅的阴影。
final class HalfPageView: UIView {
    enum Side { case left, right }
    let side: Side
    private let layout: ChapterLayout
    private let page: Int?
    private let insets: UIEdgeInsets
    private let gap: CGFloat
    private let footer = UILabel()
    private let textView: PageTextView?
    private let spine = CAGradientLayer()
    private let shadeView = UIView()
    /// 翻动时盖在纸面上的一层暗影（0…1）
    var shade: CGFloat {
        get { shadeView.alpha }
        set { shadeView.alpha = newValue }
    }

    init(side: Side, layout: ChapterLayout, page: Int?, title: String?, style: ReaderStyle, insets: UIEdgeInsets, gap: CGFloat) {
        self.side = side
        self.layout = layout
        self.page = page
        self.insets = insets
        self.gap = gap
        textView = page.map { PageTextView(layout: layout, page: $0) }
        super.init(frame: .zero)
        backgroundColor = style.background
        layer.isDoubleSided = false
        footer.font = UIFont(name: "NotoSerifSC-Regular", size: 11) ?? .systemFont(ofSize: 11)
        footer.textColor = style.secondary
        if side == .left {
            footer.text = title
            footer.lineBreakMode = .byTruncatingTail
        } else if let page {
            footer.text = "\(page + 1) / \(layout.pageCount)"
            footer.textAlignment = .right
        } else if layout.pageCount > 0 {
            // 本章最后一屏只有左页：右边留白，页码仍写在右下角。
            footer.text = "\(layout.pageCount) / \(layout.pageCount)"
            footer.textAlignment = .right
        }
        if let textView { addSubview(textView) }
        addSubview(footer)
        let dark = UIColor.black.withAlphaComponent(style.background.isDark ? 0.16 : 0.07).cgColor
        let clear = UIColor.black.withAlphaComponent(0).cgColor
        spine.colors = side == .left ? [clear, dark] : [dark, clear]
        spine.startPoint = CGPoint(x: 0, y: 0.5)
        spine.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(spine)
        shadeView.backgroundColor = .black
        shadeView.alpha = 0
        shadeView.isUserInteractionEnabled = false
        addSubview(shadeView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setFooterTitle(_ title: String) {
        if side == .left { footer.text = title }
    }

    func note(at point: CGPoint) -> String? {
        guard let textView else { return nil }
        return textView.note(at: convert(point, to: textView))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 整屏宽 W：左页正文从左边距起，右页正文从书脊右侧 gap/2 起，两栏一样宽。
        let column = bounds.width - insets.left - gap / 2
        let textX = side == .left ? insets.left : gap / 2
        textView?.frame = CGRect(x: textX, y: insets.top, width: column, height: bounds.height - insets.top - insets.bottom)
        let footerY = bounds.height - max(safeAreaInsets.bottom, 20) - 22
        footer.frame = CGRect(x: textX, y: footerY, width: column, height: 16)
        let spineWidth: CGFloat = 28
        spine.frame = CGRect(x: side == .left ? bounds.width - spineWidth : 0, y: 0, width: spineWidth, height: bounds.height)
        shadeView.frame = bounds
    }
}

private extension UIColor {
    var isDark: Bool {
        var white: CGFloat = 0
        getWhite(&white, alpha: nil)
        return white < 0.5
    }
}
